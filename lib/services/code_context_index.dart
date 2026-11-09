import 'dart:io';

/// Static, in-memory index of source symbols for a project folder.
///
/// The index is built lazily on first access and refreshed per-file when the
/// file's modification time changes. It uses only Dart's standard library and
/// targeted regular expressions, so it works without any third-party parser.
///
/// The analysis is intentionally conservative: when a fact cannot be
/// determined with certainty (e.g. indirect callers through reflection,
/// callbacks, or dependency injection), the result marks it as uncertain
/// rather than guessing.
class CodeContextIndex {
  CodeContextIndex._();

  static final CodeContextIndex _instance = CodeContextIndex._();

  factory CodeContextIndex() => _instance;

  final Map<String, _IndexedFile> _files = {};

  /// Returns the rich context for the symbol at [path] and [line].
  ///
  /// [line] is 1-indexed. Returns `null` when the file is not a supported
  /// source file or no symbol starts at that line.
  Future<SymbolContext?> getSymbolContext(String path, int line) async {
    final ext = _extension(path);
    if (ext != '.dart' && ext != '.py') return null;

    final indexed = await _indexFile(path, ext);
    final symbol = indexed.symbols.firstWhere(
      (s) => s.line == line,
      orElse: () => _Symbol.empty,
    );
    if (symbol == _Symbol.empty) return null;

    return _buildContext(indexed, symbol, ext);
  }

  /// Rebuilds the index entry for [path] unconditionally.
  Future<void> updateFile(String path) async {
    final ext = _extension(path);
    if (ext != '.dart' && ext != '.py') return;
    _files[path] = await _parseFile(path, ext);
  }

  /// Drops all cached entries. Useful when switching projects.
  void clear() => _files.clear();

  Future<_IndexedFile> _indexFile(String path, String ext) async {
    final cached = _files[path];
    if (cached != null) {
      try {
        final stat = await File(path).stat();
        if (stat.modified == cached.modified) return cached;
      } catch (_) {
        return cached;
      }
    }
    final parsed = await _parseFile(path, ext);
    _files[path] = parsed;
    return parsed;
  }

  Future<_IndexedFile> _parseFile(String path, String ext) async {
    final file = File(path);
    DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
    List<String> lines = const [];
    try {
      modified = (await file.stat()).modified;
      if (await file.length() <= 1024 * 1024) {
        lines = await file.readAsLines();
      }
    } catch (_) {
      // Unreadable file -> empty index entry.
    }

    final symbols = <_Symbol>[];
    final references = <_Reference>[];
    final imports = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;

      if (ext == '.dart') {
        _parseDartLine(raw, trimmed, i + 1, symbols, references, imports);
      } else {
        _parsePythonLine(raw, trimmed, i + 1, symbols, references, imports);
      }
    }

    return _IndexedFile(
      path: path,
      modified: modified,
      lines: lines,
      symbols: symbols,
      references: references,
      imports: imports,
    );
  }

  void _parseDartLine(
    String raw,
    String trimmed,
    int line,
    List<_Symbol> symbols,
    List<_Reference> references,
    List<String> imports,
  ) {
    if (trimmed.startsWith('//')) return;

    final importMatch = RegExp(r'''^import\s+['"]([^'"]+)['"]''').firstMatch(trimmed);
    if (importMatch != null) {
      imports.add(importMatch.group(1)!);
      return;
    }

    final classMatch = RegExp(
      r'^(?:abstract\s+|base\s+|final\s+|sealed\s+|interface\s+|mixin\s+)?class\s+([A-Za-z_]\w*)',
    ).firstMatch(trimmed);
    if (classMatch != null) {
      symbols.add(_Symbol(
        name: classMatch.group(1)!,
        kind: 'class',
        line: line,
        signature: trimmed,
        visibility: trimmed.startsWith('_') ? 'private' : 'public',
        annotations: _annotations(raw),
      ));
      return;
    }

    final functionMatch = RegExp(
      r'^\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:static\s+|external\s+|factory\s+|const\s+|abstract\s+)?'
      r'(?:Future(?:<[^>]+>)?\s+|Stream(?:<[^>]+>)?\s+|[A-Za-z_<>,?\[\] ]+\s+)?'
      r'([A-Za-z_]\w*)\s*\(([^;]*)\)\s*(?:async\s*)?(?:\{|=>)',
    ).firstMatch(trimmed);
    if (functionMatch != null &&
        !_isStatementKeyword(functionMatch.group(1)!)) {
      final name = functionMatch.group(1)!;
      final params = functionMatch.group(2) ?? '';
      symbols.add(_Symbol(
        name: name,
        kind: 'method',
        line: line,
        signature: trimmed,
        visibility: name.startsWith('_') ? 'private' : 'public',
        annotations: _annotations(raw),
        parameters: _dartParameters(params),
        returnType: _dartReturnType(trimmed, name),
      ));
      return;
    }

    final abstractMethodMatch = RegExp(
      r'^(?:@\w+(?:\([^)]*\))?\s*)*abstract\s+'
      r'(?:Future(?:<[^>]+>)?\s+|Stream(?:<[^>]+>)?\s+|[A-Za-z_<>,?\[\] ]+\s+)?'
      r'([A-Za-z_]\w*)\s*\(([^;]*)\)\s*;',
    ).firstMatch(trimmed);
    if (abstractMethodMatch != null) {
      final name = abstractMethodMatch.group(1)!;
      final params = abstractMethodMatch.group(2) ?? '';
      symbols.add(_Symbol(
        name: name,
        kind: 'method',
        line: line,
        signature: trimmed,
        visibility: name.startsWith('_') ? 'private' : 'public',
        annotations: _annotations(raw),
        parameters: _dartParameters(params),
        returnType: _dartReturnType(trimmed, name),
      ));
      return;
    }

    // Fields live at indent 0 (top-level) or 2 (class body). Method-local
    // declarations (indent >= 4) are NOT symbols and must not pollute the
    // class member list.
    final rawIndent = raw.length - raw.trimLeft().length;
    final variableMatch = rawIndent <= 2
        ? RegExp(
            r'^(?:final|const|var|late|static)\s+'
            r'([A-Za-z_<>,?\[\] ]+?)\s+([A-Za-z_]\w*)\s*(?:=|;)',
          ).firstMatch(trimmed)
        : null;
    if (variableMatch != null) {
      final name = variableMatch.group(2)!;
      symbols.add(_Symbol(
        name: name,
        kind: 'field',
        line: line,
        signature: trimmed,
        visibility: name.startsWith('_') ? 'private' : 'public',
        type: variableMatch.group(1)!.trim(),
      ));
      return;
    }

    // Reference extraction: any identifier followed by `(` is a potential
    // call. We record it so callers/callees can be resolved across files.
    for (final m in RegExp(r'\b([A-Za-z_]\w*)\s*\(').allMatches(trimmed)) {
      references.add(_Reference(name: m.group(1)!, line: line));
    }
    // Usage extraction: identifiers that are read/written without a call
    // (e.g. `_controller.text`, `x = value`). These resolve field callers.
    for (final m in RegExp(r'\b([A-Za-z_]\w*)\b').allMatches(trimmed)) {
      final name = m.group(1)!;
      if (_isStatementKeyword(name) || _isDartTypeWord(name)) continue;
      references.add(_Reference(name: name, line: line, usage: true));
    }
  }

  void _parsePythonLine(
    String raw,
    String trimmed,
    int line,
    List<_Symbol> symbols,
    List<_Reference> references,
    List<String> imports,
  ) {
    if (trimmed.startsWith('#')) return;

    final importMatch = RegExp(r'^(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))').firstMatch(trimmed);
    if (importMatch != null) {
      imports.add(importMatch.group(1) ?? importMatch.group(2) ?? '');
      return;
    }

    final classMatch = RegExp(r'^class\s+([A-Za-z_]\w*)(?:\(([^)]*)\))?\s*:').firstMatch(trimmed);
    if (classMatch != null) {
      symbols.add(_Symbol(
        name: classMatch.group(1)!,
        kind: 'class',
        line: line,
        signature: trimmed,
        visibility: 'public',
        annotations: _annotations(raw),
        bases: classMatch.group(2)?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList() ?? const [],
      ));
      return;
    }

    final functionMatch = RegExp(
      r'^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\((.*)\)\s*(?:->\s*([^:]+))?:',
    ).firstMatch(trimmed);
    if (functionMatch != null) {
      final name = functionMatch.group(1)!;
      symbols.add(_Symbol(
        name: name,
        kind: 'method',
        line: line,
        signature: trimmed,
        visibility: name.startsWith('_') ? 'private' : 'public',
        annotations: _annotations(raw),
        parameters: _pythonParameters(functionMatch.group(2) ?? ''),
        returnType: functionMatch.group(3)?.trim(),
      ));
      return;
    }

    // Class-level fields sit at indent 0 (module) or 4 (class body).
    // Method-local assignments (indent >= 8) are NOT symbols and must not
    // pollute the class member list. The regex runs on the trimmed line, so
    // the indentation must be measured on the raw line.
    final rawIndent = raw.length - raw.trimLeft().length;
    final variableMatch = rawIndent <= 4
        ? RegExp(
            r'^([A-Za-z_]\w*)(?:\s*:\s*[^=]+)?\s*=\s*[^=]',
          ).firstMatch(trimmed)
        : null;
    if (variableMatch != null) {
      final name = variableMatch.group(1)!;
      symbols.add(_Symbol(
        name: name,
        kind: 'field',
        line: line,
        signature: trimmed,
        visibility: name.startsWith('_') ? 'private' : 'public',
        type: _pythonVariableType(trimmed, name),
      ));
      return;
    }

    for (final m in RegExp(r'\b([A-Za-z_]\w*)\s*\(').allMatches(trimmed)) {
      references.add(_Reference(name: m.group(1)!, line: line));
    }
    for (final m in RegExp(r'\b([A-Za-z_]\w*)\b').allMatches(trimmed)) {
      final name = m.group(1)!;
      if (_isPythonKeyword(name)) continue;
      references.add(_Reference(name: name, line: line, usage: true));
    }
  }

  SymbolContext _buildContext(_IndexedFile indexed, _Symbol symbol, String ext) {
    final owner = _findOwner(indexed, symbol);
    final callees = _calleesInFile(indexed, symbol);
    final callers = _callersAcrossProject(indexed, symbol);
    final relatedTests = _relatedTests(indexed.path, symbol.name, ext);
    final imports = _relevantImports(indexed, symbol);
    final members = symbol.kind == 'class'
        ? _classMembers(indexed, symbol)
        : const <String>[];
    final endLine = symbol.kind == 'class'
        ? _classEndLine(indexed, symbol)
        : _endLine(indexed, symbol);

    return SymbolContext(
      language: ext == '.dart' ? 'dart' : 'python',
      kind: symbol.kind,
      name: symbol.name,
      file: indexed.path,
      lines: '${symbol.line}-$endLine',
      signature: symbol.signature,
      parameters: symbol.parameters,
      returnType: symbol.returnType,
      type: symbol.type,
      owner: owner,
      visibility: symbol.visibility,
      annotations: symbol.annotations,
      bases: symbol.bases,
      members: members,
      callers: callers,
      callees: callees,
      imports: imports,
      relatedTests: relatedTests,
      uncertain: _hasIndirectReferences(indexed, symbol),
    );
  }

  /// Names of the methods and fields declared directly inside a class body.
  /// Deduplicated: overloads or repeated declarations appear once.
  List<String> _classMembers(_IndexedFile indexed, _Symbol symbol) {
    final end = _classEndLine(indexed, symbol);
    final names = <String>{};
    for (final s in indexed.symbols) {
      if (s.line > symbol.line && s.line <= end && s.name != symbol.name) {
        names.add(s.name);
      }
    }
    return names.toList()..sort();
  }

  String? _findOwner(_IndexedFile indexed, _Symbol symbol) {
    _Symbol? owner;
    for (final s in indexed.symbols) {
      if (s.kind == 'class' && s.line < symbol.line) {
        owner = s;
      }
    }
    return owner?.name;
  }

  int _endLine(_IndexedFile indexed, _Symbol symbol) {
    // Find the next top-level symbol after this one; the symbol spans up to
    // just before it. Falls back to the end of the file.
    for (final s in indexed.symbols) {
      if (s.line > symbol.line) return s.line - 1;
    }
    return indexed.lines.isEmpty ? symbol.line : indexed.lines.length;
  }

  /// End line of a class body, tracked by indentation (Python) or brace
  /// depth (Dart) so nested symbols do not truncate the range.
  int _classEndLine(_IndexedFile indexed, _Symbol symbol) {
    final lines = indexed.lines;
    if (lines.isEmpty) return symbol.line;
    final isPython = _extension(indexed.path) == '.py';
    if (isPython) {
      final header = lines[symbol.line - 1];
      final indent = RegExp(r'^\s*').firstMatch(header)!.group(0)!.length;
      var lastNonEmpty = symbol.line;
      for (var i = symbol.line; i < lines.length; i++) {
        final line = lines[i];
        if (line.trim().isEmpty) continue;
        lastNonEmpty = i + 1;
        final lineIndent = RegExp(r'^\s*').firstMatch(line)!.group(0)!.length;
        if (lineIndent <= indent) return i;
      }
      return lastNonEmpty;
    }
    // Dart: count braces from the class declaration onward.
    var depth = 0;
    var started = false;
    for (var i = symbol.line - 1; i < lines.length; i++) {
      final line = lines[i];
      for (var j = 0; j < line.length; j++) {
        final ch = line[j];
        if (ch == '{') {
          depth++;
          started = true;
        } else if (ch == '}') {
          depth--;
          if (started && depth == 0) return i + 1;
        }
      }
    }
    return lines.length;
  }

  List<String> _calleesInFile(_IndexedFile indexed, _Symbol symbol) {
    final end = _endLine(indexed, symbol);
    final names = <String>{};
    for (final ref in indexed.references) {
      // Callees are call references only; usage references are reads/writes.
      if (!ref.usage && ref.line > symbol.line && ref.line <= end) {
        names.add(ref.name);
      }
    }
    return names.toList()..sort();
  }

  List<CallerInfo> _callersAcrossProject(_IndexedFile indexed, _Symbol symbol) {
    final results = <CallerInfo>[];
    // Fall back to the file's own directory when no project marker is found
    // (e.g. isolated test fixtures or single-file projects).
    final root = _projectRoot(indexed.path) ?? File(indexed.path).parent.path;

    // Lazily index every source file under the project root so callers are
    // found even when the user never opened those files in the explorer.
    _indexProjectFiles(root);

    for (final entry in _files.values) {
      if (entry.path == indexed.path) continue;
      for (final ref in entry.references) {
        // Methods/functions resolve via call references; fields resolve via
        // usage references (reads/writes without parentheses).
        final matches = symbol.kind == 'field'
            ? ref.usage && ref.name == symbol.name
            : !ref.usage && ref.name == symbol.name;
        if (matches) {
          results.add(CallerInfo(
            file: entry.path,
            line: ref.line,
            snippet: _lineSnippet(entry, ref.line),
          ));
        }
      }
    }
    results.sort((a, b) => a.file.compareTo(b.file));
    return results;
  }

  /// Indexes all Dart/Python files under [root] that are not cached yet.
  /// Skips hidden/build directories and files larger than 1 MB.
  void _indexProjectFiles(String root) {
    final pending = <String>[];
    try {
      for (final entity in Directory(root).listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final ext = _extension(entity.path);
        if (ext != '.dart' && ext != '.py') continue;
        if (_files.containsKey(entity.path)) continue;
        final rel = entity.path.substring(root.length + 1);
        if (rel.split(Platform.pathSeparator).any((part) =>
            part.startsWith('.') ||
            const {'build', 'dist', 'node_modules', '__pycache__', 'coverage'}
                .contains(part))) {
          continue;
        }
        pending.add(entity.path);
      }
    } catch (_) {
      // Unreadable project tree -> keep whatever is already indexed.
    }
    for (final path in pending) {
      final ext = _extension(path);
      try {
        final file = File(path);
        if (file.lengthSync() > 1024 * 1024) continue;
        _files[path] = _parseFileSync(path, ext);
      } catch (_) {
        // Unreadable file -> skip.
      }
    }
  }

  _IndexedFile _parseFileSync(String path, String ext) {
    final file = File(path);
    DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
    List<String> lines = const [];
    try {
      modified = file.statSync().modified;
      lines = file.readAsLinesSync();
    } catch (_) {
      // Unreadable file -> empty index entry.
    }

    final symbols = <_Symbol>[];
    final references = <_Reference>[];
    final imports = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (ext == '.dart') {
        _parseDartLine(raw, trimmed, i + 1, symbols, references, imports);
      } else {
        _parsePythonLine(raw, trimmed, i + 1, symbols, references, imports);
      }
    }

    return _IndexedFile(
      path: path,
      modified: modified,
      lines: lines,
      symbols: symbols,
      references: references,
      imports: imports,
    );
  }

  List<String> _relevantImports(_IndexedFile indexed, _Symbol symbol) {
    // All imports are potentially relevant; keep them ordered and deduped.
    return indexed.imports.toSet().toList()..sort();
  }

  List<String> _relatedTests(String path, String symbolName, String ext) {
    final root = _projectRoot(path);
    if (root == null) return const [];

    final results = <String>[];
    final testDirs = ['test', 'tests'];
    for (final dirName in testDirs) {
      final dir = Directory('$root${Platform.pathSeparator}$dirName');
      if (!dir.existsSync()) continue;
      try {
        for (final f in dir.listSync(recursive: true)) {
          if (f is! File) continue;
          // Only consider test files written in the same language as the
          // symbol: a Python class must not match Dart test fixtures that
          // merely mention its name as a string literal.
          if (_extension(f.path) != ext) continue;
          final content = f.readAsStringSync();
          if (RegExp('\\b${RegExp.escape(symbolName)}\\b').hasMatch(content)) {
            results.add(f.path);
          }
        }
      } catch (_) {
        // Ignore unreadable test trees.
      }
    }
    results.sort();
    return results;
  }

  bool _hasIndirectReferences(_IndexedFile indexed, _Symbol symbol) {
    final end = _endLine(indexed, symbol);
    final body = indexed.lines
        .skip(symbol.line - 1)
        .take(end - symbol.line + 1)
        .join('\n');
    return RegExp(r'\b(?:addListener|listen|then|callback|on[A-Z]\w*|register|subscribe|notifyListeners)\b')
        .hasMatch(body);
  }

  String? _projectRoot(String path) {
    // Walk up until we find a directory containing pubspec.yaml, setup.py,
    // pyproject.toml, or .git. This approximates the project root without
    // relying on ProjectService (keeps the index testable in isolation).
    var dir = File(path).parent;
    for (var i = 0; i < 8; i++) {
      if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync() ||
          File('${dir.path}${Platform.pathSeparator}setup.py').existsSync() ||
          File('${dir.path}${Platform.pathSeparator}pyproject.toml').existsSync() ||
          Directory('${dir.path}${Platform.pathSeparator}.git').existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  String _lineSnippet(_IndexedFile file, int line) {
    if (line < 1 || line > file.lines.length) return '';
    return file.lines[line - 1].trim();
  }

  List<String> _annotations(String raw) {
    final result = <String>[];
    final trimmed = raw.trimLeft();
    if (trimmed.startsWith('@')) {
      for (final m in RegExp(r'@(\w+)').allMatches(trimmed)) {
        result.add(m.group(1)!);
      }
    }
    return result;
  }

  List<String> _dartParameters(String params) {
    if (params.trim().isEmpty) return const [];
    return params
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  bool _isStatementKeyword(String name) {
    const keywords = {
      'if', 'for', 'while', 'switch', 'catch', 'return', 'throw',
      'assert', 'await', 'yield', 'new', 'super', 'this',
    };
    return keywords.contains(name);
  }

  bool _isDartTypeWord(String name) {
    const types = {
      'int', 'double', 'String', 'bool', 'dynamic', 'void', 'var',
      'final', 'const', 'late', 'static', 'List', 'Map', 'Set',
      'Future', 'Stream', 'Object', 'num', 'Iterable', 'Function',
    };
    return types.contains(name);
  }

  bool _isPythonKeyword(String name) {
    const keywords = {
      'def', 'class', 'return', 'if', 'elif', 'else', 'for', 'while',
      'import', 'from', 'as', 'with', 'try', 'except', 'finally', 'raise',
      'lambda', 'pass', 'break', 'continue', 'in', 'not', 'and', 'or',
      'is', 'None', 'True', 'False', 'self', 'async', 'await', 'yield',
      'global', 'nonlocal', 'del', 'assert', 'print',
    };
    return keywords.contains(name);
  }

  String? _pythonVariableType(String signature, String name) {
    // Heuristic: infer the type from the assigned literal or constructor.
    final match = RegExp(r'=\s*([^#]+)').firstMatch(signature);
    if (match == null) return null;
    final value = match.group(1)!.trim();
    if (RegExp(r'^\d+$').hasMatch(value)) return 'int';
    if (RegExp(r'^\d+\.\d+$').hasMatch(value)) return 'float';
    if (RegExp(r'''^["']''').hasMatch(value)) return 'str';
    if (value == 'True' || value == 'False') return 'bool';
    if (value.startsWith('[')) return 'list';
    if (value.startsWith('{')) return 'dict';
    if (value.startsWith('(')) return 'tuple';
    if (RegExp(r'^[A-Z]\w*\(').hasMatch(value)) {
      return value.substring(0, value.indexOf('('));
    }
    return null;
  }

  String? _dartReturnType(String signature, String name) {
    final before = signature.substring(0, signature.indexOf(name)).trim();
    if (before.isEmpty) return null;
    // Strip modifiers.
    final cleaned = before
        .replaceAll(RegExp(r'^(static|external|factory|const|abstract)\s+'), '')
        .trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  List<String> _pythonParameters(String params) {
    if (params.trim().isEmpty) return const [];
    return params
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  static String _extension(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }
}

/// Rich, structured context for a single source symbol.
class SymbolContext {
  final String language;
  final String kind;
  final String name;
  final String file;
  final String lines;
  final String signature;
  final List<String> parameters;
  final String? returnType;
  final String? type;
  final String? owner;
  final String visibility;
  final List<String> annotations;
  final List<String> bases;
  final List<String> members;
  final List<CallerInfo> callers;
  final List<String> callees;
  final List<String> imports;
  final List<String> relatedTests;

  /// True when the symbol body contains patterns that suggest indirect
  /// references (callbacks, listeners, DI) that static analysis may miss.
  final bool uncertain;

  const SymbolContext({
    required this.language,
    required this.kind,
    required this.name,
    required this.file,
    required this.lines,
    required this.signature,
    required this.parameters,
    required this.returnType,
    required this.type,
    required this.owner,
    required this.visibility,
    required this.annotations,
    required this.bases,
    required this.members,
    required this.callers,
    required this.callees,
    required this.imports,
    required this.relatedTests,
    required this.uncertain,
  });

  /// Renders the context as a compact `=== SYMBOL START === ... === SYMBOL END ===` block wrapped
  /// in a fenced code block so Markdown renderers show it as a code portion
  /// instead of treating the raw `<symbol>` tag as hidden HTML. Every field
  /// ends with a comma so the block stays parseable even when a signature
  /// contains `{`.
  String toPromptBlock(String projectRoot) {
    final relative = _relativePath(projectRoot, file);
    final buf = StringBuffer();
    buf.writeln('```');
    buf.writeln('=== SYMBOL START ===');
    buf.writeln('  language: $language,');
    buf.writeln('  kind: $kind,');
    buf.writeln('  name: $name,');
    buf.writeln('  file: $relative,');
    buf.writeln('  lines: $lines,');
    buf.writeln('  signature: ${signature.replaceAll('{', '').replaceAll('}', '')},');
    buf.writeln('  parameters: [${parameters.join(', ')}],');
    if (returnType != null && returnType!.isNotEmpty) {
      buf.writeln('  return_type: $returnType,');
    }
    if (type != null && type!.isNotEmpty) {
      buf.writeln('  type: $type,');
    }
    if (owner != null) buf.writeln('  owner: $owner,');
    buf.writeln('  visibility: $visibility,');
    if (annotations.isNotEmpty) {
      buf.writeln('  annotations: [${annotations.join(', ')}],');
    }
    if (bases.isNotEmpty) {
      buf.writeln('  bases: [${bases.join(', ')}],');
    }
    if (members.isNotEmpty) {
      buf.writeln('  members: [${members.join(', ')}],');
    }
    if (callers.isNotEmpty) {
      buf.writeln('  callers: [');
      for (final c in callers) {
        buf.writeln('    ${_relativePath(projectRoot, c.file)}:${c.line},');
      }
      buf.writeln('  ],');
    }
    if (callees.isNotEmpty) {
      buf.writeln('  callees: [');
      for (final c in callees) {
        buf.writeln('    $c(),');
      }
      buf.writeln('  ],');
    }
    if (imports.isNotEmpty) {
      buf.writeln('  imports: [');
      for (final i in imports) {
        buf.writeln('    $i,');
      }
      buf.writeln('  ],');
    }
    if (relatedTests.isNotEmpty) {
      buf.writeln('  related_tests: [');
      for (final t in relatedTests) {
        buf.writeln('    ${_relativePath(projectRoot, t)},');
      }
      buf.writeln('  ],');
    }
    if (uncertain) {
      buf.writeln('  note: indirect references may exist (callbacks/listeners/DI),');
    }
    buf.writeln('=== SYMBOL END ===');
    buf.writeln('```');
    return buf.toString();
  }

  static String _relativePath(String root, String path) {
    final r = root.replaceAll('\\', '/').replaceAll(RegExp(r'/$'), '');
    final p = path.replaceAll('\\', '/');
    return p.startsWith('$r/') ? p.substring(r.length + 1) : p;
  }
}

class CallerInfo {
  final String file;
  final int line;
  final String snippet;

  const CallerInfo({required this.file, required this.line, required this.snippet});
}

class _IndexedFile {
  final String path;
  final DateTime modified;
  final List<String> lines;
  final List<_Symbol> symbols;
  final List<_Reference> references;
  final List<String> imports;

  const _IndexedFile({
    required this.path,
    required this.modified,
    required this.lines,
    required this.symbols,
    required this.references,
    required this.imports,
  });
}

class _Symbol {
  final String name;
  final String kind;
  final int line;
  final String signature;
  final String visibility;
  final List<String> annotations;
  final List<String> bases;
  final List<String> parameters;
  final String? returnType;
  final String? type;

  const _Symbol({
    required this.name,
    required this.kind,
    required this.line,
    required this.signature,
    required this.visibility,
    this.annotations = const [],
    this.bases = const [],
    this.parameters = const [],
    this.returnType,
    this.type,
  });

  static const _Symbol empty = _Symbol(
    name: '',
    kind: '',
    line: -1,
    signature: '',
    visibility: '',
  );
}

class _Reference {
  final String name;
  final int line;

  /// True when the reference is a plain identifier read/write (field usage)
  /// rather than a call `name(`.
  final bool usage;

  const _Reference({required this.name, required this.line, this.usage = false});
}