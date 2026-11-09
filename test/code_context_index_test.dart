import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agentic/services/code_context_index.dart';

void main() {
  late Directory tempDir;
  late CodeContextIndex index;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('code_context_index_test');
    index = CodeContextIndex();
    index.clear();
  });

  tearDown(() {
    index.clear();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('extracts Dart method context with owner, params, and return type', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}country_repository.dart');
    file.writeAsStringSync('''
import 'package:agentic/country.dart';

class CountryRepository {
  Future<void> init() async {
    await loadCountries();
  }

  Future<void> loadCountries() async {}
}
''');

    final context = await index.getSymbolContext(file.path, 4);

    expect(context, isNotNull);
    expect(context!.language, 'dart');
    expect(context.kind, 'method');
    expect(context.name, 'init');
    expect(context.owner, 'CountryRepository');
    expect(context.returnType, 'Future<void>');
    expect(context.parameters, isEmpty);
    expect(context.callees, contains('loadCountries'));
    expect(context.imports, contains('package:agentic/country.dart'));
  });

  test('extracts Python method context with parameters and return type', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.py');
    file.writeAsStringSync('''
class Repo:
    def init(self, path: str) -> bool:
        return True
''');

    final context = await index.getSymbolContext(file.path, 2);

    expect(context, isNotNull);
    expect(context!.language, 'python');
    expect(context.kind, 'method');
    expect(context.name, 'init');
    expect(context.owner, 'Repo');
    expect(context.returnType, 'bool');
    expect(context.parameters, contains('self'));
    expect(context.parameters, contains('path: str'));
  });

  test('returns null for unsupported files', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}notes.txt');
    file.writeAsStringSync('hello');

    final context = await index.getSymbolContext(file.path, 3);

    expect(context, isNull);
  });

  test('returns null when no symbol starts at the requested line', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.dart');
    file.writeAsStringSync('''
class Repo {
  void run() {}
}
''');

    final context = await index.getSymbolContext(file.path, 3);

    expect(context, isNull);
  });

  test('renders a compact prompt block with relative paths', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}lib${Platform.pathSeparator}repo.dart');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
class Repo {
  Future<void> init() async {}
}
''');

    final context = await index.getSymbolContext(file.path, 2);
    final block = context!.toPromptBlock(tempDir.path);

    // The block is a fenced code block (see `toPromptBlock`'s docstring: the
    // fence stops Markdown renderers from swallowing the raw tag as HTML). The
    // separating newline is supplied by the caller
    // (`_acceptExplorerReference`), not by the block itself, so the block
    // starts at the fence and ends with a closing fence plus newline.
    // Code unit 96 is a backtick. The block must open and close with a
    // Markdown fence so renderers show the raw tag as code instead of
    // swallowing it as hidden HTML.
    expect(block.codeUnitAt(0), 96);
    expect(block, contains('=== SYMBOL START ==='));
    expect(block, contains('=== SYMBOL END ==='));
    final trimmed = block.trimRight();
    expect(trimmed.codeUnitAt(trimmed.length - 1), 96);
    expect(block, contains('name: init'));
    expect(block, contains('file: lib/repo.dart'));
    expect(block, contains('owner: Repo'));
  });

  test('detects indirect references and marks context uncertain', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.dart');
    file.writeAsStringSync('''
class Repo {
  void init() {
    someStream.listen((_) {});
  }
}
''');

    final context = await index.getSymbolContext(file.path, 2);

    expect(context, isNotNull);
    expect(context!.uncertain, isTrue);
  });

  test('extracts Dart field context with type and usage callers', () async {
    final repo = File('${tempDir.path}${Platform.pathSeparator}repo.dart');
    repo.writeAsStringSync('''
class Repo {
  final String _name = 'x';
}
''');
    final service = File('${tempDir.path}${Platform.pathSeparator}service.dart');
    service.writeAsStringSync('''
class Service {
  void run(Repo repo) {
    print(repo._name);
  }
}
''');

    final context = await index.getSymbolContext(repo.path, 2);

    expect(context, isNotNull);
    expect(context!.kind, 'field');
    expect(context.name, '_name');
    expect(context.type, 'String');
    expect(context.visibility, 'private');
    expect(context.owner, 'Repo');
    expect(context.callers, isNotEmpty);
    expect(context.callers.first.file, service.path);
    expect(context.callers.first.line, 3);
  });

  test('extracts Python field context with inferred type', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.py');
    file.writeAsStringSync('''
class Repo:
    count = 0
''');

    final context = await index.getSymbolContext(file.path, 2);

    expect(context, isNotNull);
    expect(context!.kind, 'field');
    expect(context.name, 'count');
    expect(context.type, 'int');
    expect(context.owner, 'Repo');
  });

  test('renders field type in prompt block', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.dart');
    file.writeAsStringSync('''
class Repo {
  final int count = 0;
}
''');

    final context = await index.getSymbolContext(file.path, 2);
    final block = context!.toPromptBlock(tempDir.path);

    expect(block, contains('kind: field'));
    expect(block, contains('type: int'));
  });

  test('extracts Python class context with members and full line range', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}backend.py');
    file.writeAsStringSync('''
class OllamaBackend(ModelBackend):
    DEFAULT_NUM_CTX = 32768

    def __init__(self, model_id: str):
        self.model_id = model_id

    def chat(self, conversation) -> str:
        return "ok"
''');

    final context = await index.getSymbolContext(file.path, 1);

    expect(context, isNotNull);
    expect(context!.kind, 'class');
    expect(context.name, 'OllamaBackend');
    expect(context.bases, contains('ModelBackend'));
    expect(context.members, contains('__init__'));
    expect(context.members, contains('chat'));
    expect(context.members, contains('DEFAULT_NUM_CTX'));
    expect(context.lines, '1-8');
  });

  test('extracts Dart class context with members and full line range', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.dart');
    file.writeAsStringSync('''
class Repo extends BaseRepo {
  final int count = 0;

  Future<void> init() async {
    await load();
  }

  void load() {}
}
''');

    final context = await index.getSymbolContext(file.path, 1);

    expect(context, isNotNull);
    expect(context!.kind, 'class');
    expect(context.name, 'Repo');
    expect(context.members, contains('count'));
    expect(context.members, contains('init'));
    expect(context.members, contains('load'));
    expect(context.lines, '1-9');
  });

  test('renders class members in prompt block', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}repo.dart');
    file.writeAsStringSync('''
class Repo {
  void run() {}
}
''');

    final context = await index.getSymbolContext(file.path, 1);
    final block = context!.toPromptBlock(tempDir.path);

    expect(block, contains('kind: class'));
    expect(block, contains('members: [run]'));
  });

  test('excludes method-local variables from Python class members', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}backend.py');
    file.writeAsStringSync('''
class OllamaBackend(ModelBackend):
    DEFAULT_NUM_CTX = 32768

    def chat(self, conversation) -> str:
        cleaned = conversation.strip()
        finish_reason = "stop"
        return cleaned
''');

    final context = await index.getSymbolContext(file.path, 1);

    expect(context, isNotNull);
    expect(context!.members, contains('DEFAULT_NUM_CTX'));
    expect(context.members, contains('chat'));
    expect(context.members, isNot(contains('cleaned')));
    expect(context.members, isNot(contains('finish_reason')));
  });

  test('related tests match only same-language test files', () async {
    File('${tempDir.path}${Platform.pathSeparator}pyproject.toml')
        .writeAsStringSync('');
    final src = File('${tempDir.path}${Platform.pathSeparator}backend.py');
    src.writeAsStringSync('''
class OllamaBackend:
    pass
''');
    final dartTest = File(
        '${tempDir.path}${Platform.pathSeparator}test${Platform.pathSeparator}fixture_test.dart');
    dartTest.parent.createSync(recursive: true);
    dartTest.writeAsStringSync('''
// Mentions OllamaBackend as a string literal only.
void main() { print('OllamaBackend'); }
''');
    final pyTest = File(
        '${tempDir.path}${Platform.pathSeparator}test${Platform.pathSeparator}test_backend.py');
    pyTest.writeAsStringSync('''
from backend import OllamaBackend

def test_backend():
    assert OllamaBackend
''');

    final context = await index.getSymbolContext(src.path, 1);

    expect(context, isNotNull);
    expect(context!.relatedTests, contains(pyTest.path));
    expect(context.relatedTests, isNot(contains(dartTest.path)));
  });
}