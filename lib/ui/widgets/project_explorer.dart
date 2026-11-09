import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/dev_filters_repository.dart';
import '../../services/project_service.dart';

/// Payload used for internal drag-and-drop from the explorer into the chat.
class ExplorerReference {
  final String kind;
  final String path;
  final String name;
  final int? line;
  final String? signature;

  const ExplorerReference({
    required this.kind,
    required this.path,
    required this.name,
    this.line,
    this.signature,
  });

  static const languages = {
    'dart': 'dart',
    'py': 'python',
    'java': 'java',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'js': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'cs': 'csharp',
    'fs': 'fsharp',
    'vb': 'vbnet',
    'go': 'go',
    'rs': 'rust',
    'php': 'php',
    'rb': 'ruby',
    'swift': 'swift',
    'c': 'c',
    'h': 'c',
    'cc': 'cpp',
    'cpp': 'cpp',
    'cxx': 'cpp',
    'hpp': 'cpp',
    'html': 'html',
    'css': 'css',
    'scss': 'scss',
    'sql': 'sql',
    'xml': 'xml',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'sh': 'shell',
    'bash': 'shell',
    'ps1': 'powershell',
    'md': 'markdown',
  };

  String toPromptReference(String projectRoot) {
    final relative = _relativePath(projectRoot, path);
    if (kind == 'symbol') {
      final location = line == null ? relative : '$relative:$line';
      final fileName = path.split(RegExp(r'[/\\]')).last;
      final dot = fileName.lastIndexOf('.');
      final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();

      final language = languages[ext] ?? 'unknown';
      final buf = StringBuffer();
      buf.writeln('```');
      buf.writeln('=== SYMBOL START ===');
      buf.writeln('  language: $language,');
      buf.writeln('  kind: symbol,');
      buf.writeln('  name: $name,');
      buf.writeln('  file: $relative,');
      buf.writeln('  lines: $location,');
      buf.writeln('  signature: ${signature ?? name},');
      buf.writeln('=== SYMBOL END ===');
      buf.writeln('```');
      return buf.toString();
    }
    return '@$kind $relative';
  }


  static String _relativePath(String root, String path) {
    final r = root.replaceAll('\\', '/').replaceAll(RegExp(r'/$'), '');
    final p = path.replaceAll('\\', '/');
    return p.startsWith('$r/') ? p.substring(r.length + 1) : p;
  }
}

class _ExplorerEntry {
  final String name;
  final String path;
  final bool directory;
  final int? line;
  final String? signature;

  const _ExplorerEntry({
    required this.name,
    required this.path,
    required this.directory,
    this.line,
    this.signature,
  });

  ExplorerReference get reference => ExplorerReference(
        kind: line != null ? 'symbol' : directory ? 'directory' : 'file',
        path: path,
        name: name,
        line: line,
        signature: signature,
      );
}

/// Opens [path] with the OS default application for its file type.
///
/// Uses the platform's native "open with default handler" command so no extra
/// package is required. Fire-and-forget: only failures are surfaced (via a
/// snackbar) because a successfully launched editor is its own feedback.
Future<void> _openWithDefaultApp(BuildContext context, String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else {
      await Process.start('xdg-open', [path]);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open "$path": $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }
}

/// Project explorer for local Flutter/Dart and Python projects.
/// Filesystem access and source scanning run in the Flutter desktop process.
class ProjectExplorer extends StatefulWidget {
  const ProjectExplorer({super.key});

  @override
  State<ProjectExplorer> createState() => _ProjectExplorerState();
}

class _ProjectExplorerState extends State<ProjectExplorer> {
  final ProjectService _projects = ProjectService();
  final TextEditingController _searchController = TextEditingController();
  String? _root;
  bool _collapsed = false;
  bool _searching = false;
  List<_ExplorerEntry> _searchResults = const [];
  int _searchGeneration = 0;
  int _treeVersion = 0;
  List<String> _includeDirs = const [];

  static const Set<String> _ignoredDirectories = {
    '.git', '.dart_tool', '.idea', '.vscode', 'build', 'dist', 'node_modules',
    '__pycache__', '.venv', 'venv', '.pytest_cache', '.mypy_cache', '.gradle',
    'Pods', '.next', 'coverage',
  };

  @override
  void initState() {
    super.initState();
    _root = _projects.activeProjectKey;
    _projects.currentPathNotifier.addListener(_onProjectChanged);
    _projects.init().then((_) {
      if (mounted) setState(() => _root = _projects.activeProjectKey);
      _loadIncludeDirs();
    });
    _searchController.addListener(_onSearchChanged);
  }

  void _onProjectChanged() {
    if (!mounted) return;
    setState(() {
      _root = _projects.activeProjectKey;
      _searchResults = const [];
    });
    _loadIncludeDirs();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    final generation = ++_searchGeneration;
    if (query.length < 2 || _root == null) {
      if (mounted) setState(() { _searchResults = const []; _searching = false; });
      return;
    }
    setState(() => _searching = true);
    _search(query, _root!).then((results) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() { _searchResults = results; _searching = false; });
    });
  }

  Future<List<_ExplorerEntry>> _search(String query, String root) async {
    final results = <_ExplorerEntry>[];
    final lower = query.toLowerCase();
    var visited = 0;
    Future<void> walk(Directory directory) async {
      if (results.length >= 100 || visited >= 12000) return;
      List<FileSystemEntity> entities;
      try { entities = await directory.list(followLinks: false).toList(); } catch (_) { return; }
      entities.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      for (final entity in entities) {
        if (results.length >= 100 || visited >= 12000) return;
        visited++;
        final name = entity.path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
        if (entity is Directory) {
          if (!_ignoredDirectories.contains(name)) {
            if (name.toLowerCase().contains(lower)) {
              results.add(_ExplorerEntry(name: name, path: entity.path, directory: true));
            }
            await walk(entity);
          }
        } else if (entity is File) {
          final ext = _extension(name);
          if (name.toLowerCase().contains(lower)) {
            results.add(_ExplorerEntry(name: name, path: entity.path, directory: false));
          }
          if ((ext == '.dart' || ext == '.py') && results.length < 100) {
            for (final symbol in await _readSymbols(entity.path, ext)) {
              if (symbol.name.toLowerCase().contains(lower) || (symbol.signature ?? '').toLowerCase().contains(lower)) {
                results.add(symbol);
                if (results.length >= 100) break;
              }
            }
          }
        }
      }
    }
    await walk(Directory(root));
    return results;
  }

  Future<void> _loadIncludeDirs() async {
    final root = _root;
    if (root == null) {
      _includeDirs = const [];
      return;
    }
    final list = await DevFiltersRepository.instance.getList(
      root,
      DevFiltersRepository.kIncludeDirs,
    );
    if (mounted) _includeDirs = list;
  }

  /// True when [path] is an included directory itself or lies anywhere
  /// beneath an included directory. This is what makes an included folder —
  /// and its entire sub-tree — always visible, even if it is a dot-directory
  /// or otherwise on the ignore list.
  bool _isIncluded(String path) {
    if (_includeDirs.isEmpty) return false;
    final sep = Platform.pathSeparator;
    final normPath = _normalisePath(path);
    for (final inc in _includeDirs) {
      if (_isAbsolutePath(inc)) {
        final normInc = _normalisePath(inc);
        if (normPath == normInc || normPath.startsWith('$normInc$sep')) {
          return true;
        }
      } else {
        // Bare name: matches any directory with that name at any depth.
        for (final component in path.split(sep)) {
          if (_namesEqual(component, inc)) return true;
        }
      }
    }
    return false;
  }

  static bool _isAbsolutePath(String s) =>
      s.contains('/') || s.contains('\\');

  static String _normalisePath(String p) {
    var s = p.trim();
    try {
      s = Directory(s).absolute.path;
    } catch (_) {}
    if (Platform.isWindows) s = s.toLowerCase();
    while (s.length > 1 && s.endsWith(Platform.pathSeparator)) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static bool _namesEqual(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

  Future<List<_ExplorerEntry>> _children(String path) async {
    final entity = FileSystemEntity.typeSync(path, followLinks: false);
    if (entity == FileSystemEntityType.directory) {
      List<FileSystemEntity> entities;
      try { entities = await Directory(path).list(followLinks: false).toList(); } catch (_) { return []; }
      entities.removeWhere((e) {
        final name = e.path.split(Platform.pathSeparator).last;
        final included = _isIncluded(e.path);
        // Hidden dot-entries are dropped unless explicitly included (or one of
        // the always-visible exceptions).
        if (name.startsWith('.') && !included && name != '.github' && name != '.agentic') {
          return true;
        }
        // Ignored directories are dropped unless explicitly included.
        if (e is Directory && _ignoredDirectories.contains(name) && !included) {
          return true;
        }
        return false;
      });
      entities.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        return ad != bd ? ad.compareTo(bd) : a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      return entities.map((e) => _ExplorerEntry(
        name: e.path.split(Platform.pathSeparator).last,
        path: e.path,
        directory: e is Directory,
      )).toList();
    }
    if (entity == FileSystemEntityType.file) {
      final ext = _extension(path);
      if (ext == '.dart' || ext == '.py') return _readSymbols(path, ext);
    }
    return [];
  }

  Future<List<_ExplorerEntry>> _readSymbols(String path, String ext) async {
    try {
      final file = File(path);
      if (await file.length() > 1024 * 1024) return const [];
      final lines = await file.readAsLines();
      final entries = <_ExplorerEntry>[];
      final classPattern = ext == '.py'
          ? RegExp(r'^\s*class\s+([A-Za-z_]\w*)(?:\s*\((.*?)\))?\s*:')
          : RegExp(r'^\s*(?:abstract\s+|base\s+|final\s+|sealed\s+|interface\s+)?class\s+([A-Za-z_]\w*)');
      final functionPattern = ext == '.py'
          ? RegExp(r'^(\s*)(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\((.*)\)\s*(?:->\s*([^:]+))?:')
          : RegExp(r'^\s*(?:static\s+|external\s+|factory\s+|const\s+|abstract\s+|Future(?:<[^>]+>)?\s+|[A-Za-z_<>,?\[\] ]+\s+)([A-Za-z_]\w*)\s*\(([^;]*)\)\s*(?:async\s*)?(?:\{|=>|;)');
      final variablePattern = ext == '.py'
          ? RegExp(r'^\s{0,8}([A-Za-z_]\w*)\s*=\s*[^=]')
          : RegExp(r'^\s{2,}(?:final|const|var|late|static|int|double|String|bool|dynamic|List<[^>]+>|Map<[^>]+>|[A-Z]\w*(?:<[^>]+>)?)\s+([A-Za-z_]\w*)\s*(?:=|;)');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//') || line.trimLeft().startsWith('#') || line.trim().isEmpty) continue;
        final classMatch = classPattern.firstMatch(line);
        if (classMatch != null) {
          entries.add(_ExplorerEntry(name: classMatch.group(1)!, path: path, directory: false, line: i + 1, signature: line.trim()));
          continue;
        }
        final functionMatch = functionPattern.firstMatch(line);
        if (functionMatch != null) {
          final name = ext == '.py' ? functionMatch.group(2)! : functionMatch.group(1)!;
          entries.add(_ExplorerEntry(name: name, path: path, directory: false, line: i + 1, signature: line.trim()));
          continue;
        }
        final variableMatch = variablePattern.firstMatch(line);
        if (variableMatch != null) {
          entries.add(_ExplorerEntry(name: variableMatch.group(1)!, path: path, directory: false, line: i + 1, signature: line.trim()));
        }
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  static String _extension(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  Future<void> _chooseProject() async {
    final picked = await _projects.pickProjectFolder();
    if (picked == null) return;
    await _projects.setProjectFolder(picked);
    if (mounted) setState(() => _root = _projects.activeProjectKey);
    _loadIncludeDirs();
  }

  @override
  Widget build(BuildContext context) {
    final root = _root;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary.withAlpha(100),
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _collapsed = !_collapsed),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: Row(children: [
              Icon(_collapsed ? Icons.chevron_right : Icons.folder_open_outlined, size: 16, color: AppTheme.accent),
              const SizedBox(width: 6),
              const Expanded(child: Text('Project Explorer', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              if (root != null) Tooltip(message: root, child: const Icon(Icons.circle, size: 6, color: AppTheme.success)),
              IconButton(
                tooltip: 'Refresh project tree',
                onPressed: () { _loadIncludeDirs(); setState(() => _treeVersion++); },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 25, height: 25),
                icon: const Icon(Icons.refresh, size: 15),
              ),
              IconButton(
                tooltip: 'Select project folder',
                onPressed: _chooseProject,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 25, height: 25),
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              ),
            ]),
          ),
        ),
        if (!_collapsed) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(7, 0, 7, 5),
            child: SizedBox(
              height: 29,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 11.5),
                decoration: InputDecoration(
                  hintText: 'Search files, classes, methods…',
                  prefixIcon: const Icon(Icons.search, size: 15),
                  prefixIconConstraints: const BoxConstraints(minWidth: 27),
                  suffixIcon: _searchController.text.isEmpty ? null : IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 25, height: 25),
                    icon: const Icon(Icons.close, size: 13),
                    onPressed: _searchController.clear,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 7),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: AppTheme.border)),
                ),
              ),
            ),
          ),
          Expanded(
            child: root == null
                ? Center(child: TextButton.icon(onPressed: _chooseProject, icon: const Icon(Icons.folder_open, size: 15), label: const Text('Select project', style: TextStyle(fontSize: 11))))
                : _searchController.text.trim().length >= 2
                    ? _searching
                        ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                        : _searchResults.isEmpty
                            ? const Center(child: Text('No matches', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)))
                            : ListView.builder(
                                itemCount: _searchResults.length,
                                itemBuilder: (context, index) => _ExplorerEntryTile(
                                  entry: _searchResults[index], root: root, depth: 0,
                                  childrenLoader: _children,
                                ),
                              )
                    : ListView(
                        key: ValueKey('project-tree-$root-$_treeVersion'),
                        padding: EdgeInsets.zero,
                        children: [
                          _ExplorerDirectoryNode(
                            path: root,
                            name: root.split(Platform.pathSeparator).last,
                            root: root,
                            depth: 0,
                            childrenLoader: _children,
                          ),
                        ],
                      ),
          ),
        ],
      ]),
    );
  }

  @override
  void dispose() {
    _projects.currentPathNotifier.removeListener(_onProjectChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }
}

class _ExplorerDirectoryNode extends StatefulWidget {
  final String path;
  final String name;
  final String root;
  final int depth;
  final Future<List<_ExplorerEntry>> Function(String) childrenLoader;

  const _ExplorerDirectoryNode({required this.path, required this.name, required this.root, required this.depth, required this.childrenLoader});

  @override
  State<_ExplorerDirectoryNode> createState() => _ExplorerDirectoryNodeState();
}

class _ExplorerDirectoryNodeState extends State<_ExplorerDirectoryNode> {
  bool _expanded = false;
  bool _loading = false;
  List<_ExplorerEntry> _children = const [];

  Future<void> _toggle() async {
    if (!_expanded && _children.isEmpty) {
      setState(() => _loading = true);
      final children = await widget.childrenLoader(widget.path);
      if (!mounted) return;
      setState(() { _children = children; _loading = false; _expanded = true; });
    } else {
      setState(() => _expanded = !_expanded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _ExplorerEntry(name: widget.name, path: widget.path, directory: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _ExplorerRow(entry: entry, root: widget.root, depth: widget.depth, expanded: _expanded, loading: _loading, onTap: _toggle),
      if (_expanded)
        for (final child in _children)
          child.directory
              ? _ExplorerDirectoryNode(path: child.path, name: child.name, root: widget.root, depth: widget.depth + 1, childrenLoader: widget.childrenLoader)
              : _ExplorerEntryTile(entry: child, root: widget.root, depth: widget.depth + 1, childrenLoader: widget.childrenLoader),
    ]);
  }
}

class _ExplorerEntryTile extends StatefulWidget {
  final _ExplorerEntry entry;
  final String root;
  final int depth;
  final Future<List<_ExplorerEntry>> Function(String) childrenLoader;

  const _ExplorerEntryTile({required this.entry, required this.root, required this.depth, required this.childrenLoader});

  @override
  State<_ExplorerEntryTile> createState() => _ExplorerEntryTileState();
}

class _ExplorerEntryTileState extends State<_ExplorerEntryTile> {
  bool _expanded = false;
  bool _loading = false;
  List<_ExplorerEntry> _symbols = const [];

  bool get _isSource => const {'.dart', '.py'}.contains(_ProjectExplorerState._extension(widget.entry.path));

  Future<void> _toggleSymbols() async {
    if (!_isSource) return;
    if (!_expanded && _symbols.isEmpty) {
      setState(() => _loading = true);
      final result = await widget.childrenLoader(widget.entry.path);
      if (!mounted) return;
      setState(() { _symbols = result; _loading = false; _expanded = true; });
    } else {
      setState(() => _expanded = !_expanded);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _ExplorerRow(
        entry: widget.entry,
        root: widget.root,
        depth: widget.depth,
        expanded: _expanded,
        loading: _loading,
        onTap: _isSource ? _toggleSymbols : null,
        onDoubleTap: widget.entry.directory
            ? null
            : () => _openWithDefaultApp(context, widget.entry.path),
      ),
      if (_expanded)
        for (final symbol in _symbols)
          _ExplorerRow(entry: symbol, root: widget.root, depth: widget.depth + 1, expanded: false, loading: false, onTap: null),
    ]);
  }
}

class _ExplorerRow extends StatelessWidget {
  final _ExplorerEntry entry;
  final String root;
  final int depth;
  final bool expanded;
  final bool loading;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  const _ExplorerRow({required this.entry, required this.root, required this.depth, required this.expanded, required this.loading, required this.onTap, this.onDoubleTap});

  @override
  Widget build(BuildContext context) {
    final isSymbol = entry.line != null;
    final icon = isSymbol
        ? (entry.signature?.trimLeft().startsWith('class ') == true ? Icons.account_tree_outlined : entry.signature?.contains('(') == true ? Icons.functions : Icons.data_object)
        : entry.directory ? (expanded ? Icons.folder_open_outlined : Icons.folder_outlined) : _fileIcon(entry.name);
    final reference = entry.reference;
    return Draggable<ExplorerReference>(
      data: reference,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(color: AppTheme.bgSecondary, border: Border.all(color: AppTheme.accent), borderRadius: BorderRadius.circular(5)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14), const SizedBox(width: 5), Text(entry.name, style: const TextStyle(fontSize: 12))]),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: _row(icon, isSymbol)),
      child: _row(icon, isSymbol),
    );
  }

  Widget _row(IconData icon, bool isSymbol) {
    return InkWell(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Padding(
        padding: EdgeInsets.only(left: 5 + depth * 11.0, right: 4, top: 3, bottom: 3),
        child: Row(children: [
          SizedBox(width: 13, child: loading ? const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1)) : onTap == null ? null : Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 13, color: AppTheme.textMuted)),
          const SizedBox(width: 3),
          Icon(icon, size: 14, color: isSymbol ? AppTheme.accent : entry.directory ? AppTheme.warning : AppTheme.textSecondary),
          const SizedBox(width: 5),
          Expanded(child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: isSymbol ? AppTheme.textSecondary : AppTheme.textPrimary))),
          if (entry.line != null) Text('${entry.line}', style: const TextStyle(fontSize: 9, color: AppTheme.textMuted)),
          if (onTap == null && !isSymbol && !entry.directory && const {'.dart', '.py'}.contains(_ProjectExplorerState._extension(entry.path))) const Icon(Icons.drag_indicator, size: 12, color: AppTheme.textMuted),
        ]),
      ),
    );
  }

  static IconData _fileIcon(String name) {
    if (name.endsWith('.dart')) return Icons.code;
    if (name.endsWith('.py')) return Icons.terminal;
    if (name.endsWith('.md') || name.endsWith('.txt')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }
}
