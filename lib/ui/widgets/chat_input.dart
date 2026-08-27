import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:simple_spell_checker/simple_spell_checker.dart';
import 'package:simple_spell_checker_en_lan/simple_spell_checker_en_lan.dart';
import 'package:simple_spell_checker_it_lan/simple_spell_checker_it_lan.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/notification_helper.dart';
import '../../services/orchestrator_manager.dart';
import '../../services/project_service.dart';
import '../screens/settings_screen.dart';

class ChatInput extends StatefulWidget {
  final bool enabled;
  final bool sending;
  final Future<void> Function(String text) onSend;

  /// Called when the user taps the stop button during generation.
  final VoidCallback? onStop;

  /// Whether the orchestrator-log toggle button should be shown.
  /// True only for orchestrator-backed backends.
  final bool showLogToggle;

  /// Current visibility state of the orchestrator log panel — drives
  /// the icon (eye/eye-off) and tooltip text on the toggle button.
  final bool logVisible;

  /// Called when the user taps the log toggle button.
  final VoidCallback? onToggleLog;

  /// Called when the project folder is changed.
  final VoidCallback? onProjectFolderChanged;

  /// Callback to trigger download of the current chat as JSON.
  final VoidCallback? onDownload;

  /// Callback to copy the current chat as JSON to clipboard.
  final VoidCallback? onCopyToClipboard;

  /// Callback to trigger download of the current chat as Markdown.
  final VoidCallback? onDownloadAsMarkdown;

  /// Callback to copy the current chat as Markdown to clipboard.
  final VoidCallback? onCopyToClipboardAsMarkdown;

  /// Callback to create a new chat from JSON context (excluding conversation node).
  final Future<void> Function(String jsonContent)? onNewChatFromJson;

  /// Called when the user taps the auto-generate-agent-context (magic wand)
  /// button. The parent is expected to start a fresh conversation and send
  /// the analysis prompt with zero prior history.
  final VoidCallback? onAutoGenerateAgentContext;

  /// Optional externally-owned controller. When provided, the parent can drive
  /// the input text (e.g. to load a message body for editing). When null, the
  /// widget creates and owns its own controller.
  final TextEditingController? controller;

  const ChatInput({
    super.key,
    required this.enabled,
    required this.sending,
    required this.onSend,
    this.onStop,
    this.showLogToggle = false,
    this.logVisible = false,
    this.onToggleLog,
    this.onProjectFolderChanged,
    this.onDownload,
    this.onCopyToClipboard,
    this.onDownloadAsMarkdown,
    this.onCopyToClipboardAsMarkdown,
    this.onNewChatFromJson,
    this.onAutoGenerateAgentContext,
    this.controller,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  late final SpellCheckController _controller =
      widget.controller is SpellCheckController
          ? widget.controller as SpellCheckController
          : SpellCheckController();
  final _focusNode = FocusNode();
  final _projectService = ProjectService();
  String _currentProjectFolder = 'Select folder...';
  List<String> _projectFolders = const [];
  List<String> _branches = [];
  String _selectedBranch = '';

  /// Spell-check language currently selected in the input toolbar.
  /// Defaults to English (en_US) as requested.
  String _spellCheckLanguage = 'en';

  /// Spell checker instance for the currently selected language.
  SimpleSpellChecker? _spellChecker;

  /// Files the user attached for the next send. Each entry holds its display
  /// name, absolute path, and decoded text content. They are cleared
  /// immediately after the send completes (success or failure).
  final List<_Attachment> _attachments = [];

  /// Per-file size cap when reading attachments. Larger files would blow
  /// past the model's context window and the request would 400 anyway.
  static const int _kMaxAttachmentBytes = 200 * 1024; // 200 KB

  /// Whether the model-friendly template is currently active in the input.
  bool _templateActive = false;

  /// Pre-written Markdown template designed for model-friendly, context-compliant
  /// prompts. Uses clear section headers, bullet-point placeholders, and structured
  /// guidance so the model receives maximum context with minimal ambiguity.
  static const String _kModelTemplate = '''# Context
- What is the current state? Describe the existing behavior, files involved, or relevant background.
- Include error messages, logs, or screenshots if applicable.

# Goal
- What needs to be achieved? Be specific and measurable.
- Prioritize: must-have vs nice-to-have.

# Constraints
- Technology stack / framework versions to respect.
- Files or modules that must NOT be modified.
- Performance, compatibility, or security requirements.

# Implementation Details
- Step-by-step approach or algorithm to follow.
- Edge cases and error-handling expectations.
- Naming conventions or patterns to align with.

# Rules
- Always read files before editing them.
- Make the smallest safe edit that solves the problem.
- Run validation (flutter analyze / python check) after every code change.
- Never modify unrelated files.
- Prefer targeted patches over full file rewrites.

# Output Format
- Describe the expected response structure (e.g., JSON schema, Markdown sections, code blocks).
- Specify language for code fences (e.g., ```dart, ```python).
- State whether explanations, diffs, or full files are expected.''';

  /// Toggles the model-friendly template in the input field.
  /// If the template is not active, inserts it and sets the cursor at the end.
  /// If the template is already active, clears the input (toggle off).
  void _toggleTemplate() {
    if (!widget.enabled || widget.sending) return;
    if (_templateActive) {
      // Toggle off — clear the input
      _controller.clear();
      setState(() => _templateActive = false);
    } else {
      // Insert the template
      _controller.text = _kModelTemplate;
      setState(() => _templateActive = true);
      // Move cursor to end so the user can start editing
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      _focusNode.requestFocus();
    }
  }

  /// True while the user is actively dragging files over the input. Drives
  /// a tinted border so they get visual feedback that the drop will land here.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _initSpellChecker();
    _loadProjectInfo();
    _loadGitBranches();
  }

  /// Registers the bundled English and Italian dictionaries and creates the
  /// spell checker for the default language (English).
  void _initSpellChecker() {
    SimpleSpellCheckerEnRegister.registerLan(preferEnglish: 'en');
    SimpleSpellCheckerItRegister.registerLan();
    _spellChecker = SimpleSpellChecker(
      language: _spellCheckLanguage,
      whiteList: const <String>[],
      caseSensitive: false,
    );
    _controller.spellChecker = _spellChecker;
  }

  /// Switches the spell-check dictionary when the user picks a language.
  void _setSpellCheckLanguage(String language) {
    if (language == _spellCheckLanguage) return;
    setState(() {
      _spellCheckLanguage = language;
      _spellChecker?.setNewLanguageToState(language);
    });
  }

  void _loadProjectInfo() {
    final folders = _projectService.projectFolders;
    if (!_projectService.hasExplicitFolder) {
      setState(() {
        _currentProjectFolder = 'Select folder...';
        _projectFolders = folders;
      });
      return;
    }
    final path = _projectService.currentPath;
    final folderName = path.split(Platform.pathSeparator).last;
    if (folderName.isNotEmpty) {
      setState(() {
        _currentProjectFolder = folderName;
        _projectFolders = folders;
      });
    }
  }

  Future<void> _loadGitBranches() async {
    try {
      final repoPath = _projectService.currentPath;
      // Run git command to list branches
      final result = await Process.run('git', ['-C', repoPath, 'branch', '--format=%(refname:short)']);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final branches = output
            .split('\n')
            .where((b) => b.trim().isNotEmpty)
            .toSet()
            .toList(); // deduplicate
        setState(() {
          _branches = branches;
          // Determine current branch
          String currentBranch = '';
          try {
            final headResult = Process.runSync('git', ['-C', repoPath, 'rev-parse', '--abbrev-ref', 'HEAD']);
            if (headResult.exitCode == 0) {
              currentBranch = (headResult.stdout as String).trim();
            }
          } catch (_) {}
          // If we have a previously selected branch that still exists, keep it;
          // otherwise fall back to current HEAD, then first branch, then empty.
          if (_selectedBranch.isNotEmpty && branches.contains(_selectedBranch)) {
            // keep
          } else if (currentBranch.isNotEmpty && branches.contains(currentBranch)) {
            _selectedBranch = currentBranch;
          } else if (branches.isNotEmpty) {
            _selectedBranch = branches.first;
          } else {
            _selectedBranch = '';
          }
        });
      }
    } catch (e) {
      // ignore errors (e.g., not a git repo)
    }
  }

  Future<void> _createBranch() async {
    final TextEditingController branchController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Branch'),
        content: TextField(
          controller: branchController,
          decoration: const InputDecoration(hintText: 'Enter branch name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = branchController.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context);
                await _executeGitCommand(['checkout', '-b', name]);
                await _loadGitBranches();
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeGitCommand(List<String> args) async {
    try {
      final repoPath = _projectService.currentPath;
      final result = await Process.run('git', ['-C', repoPath, ...args]);
      if (result.exitCode != 0) {
        if (mounted) {
          NotificationHelper.showError(context, 'Git error: ${result.stderr}');
        }
      }
    } catch (e) {
      // ignore errors
    }
  }

  Future<void> _checkoutBranch(String branch) async {
    await _executeGitCommand(['checkout', branch]);
    setState(() => _selectedBranch = branch);
  }

  Future<void> _switchToProject(String path) async {
    if (!mounted) return;
    final switched = await _projectService.selectProjectFolder(path);
    if (!switched || !mounted) return;

    setState(() => _currentProjectFolder = path.split(Platform.pathSeparator).last);

    // Stop orchestrator to ensure it restarts with the new base path
    await OrchestratorManager.instance.stop();

    // Notify parent to restart orchestrator if needed
    widget.onProjectFolderChanged?.call();

    // Reload branches for the new project folder
    await _loadGitBranches();
  }

  void _openSettingsForProjects() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SettingsScreen(initialSection: 0),
      ),
    );
  }

  /// Delegates to the parent via [onAutoGenerateAgentContext] so the parent
  /// can create a fresh conversation and send the analysis prompt with zero
  /// prior history.
  void _autoGenerateAgentContext() {
    if (!widget.enabled || widget.sending) return;
    widget.onAutoGenerateAgentContext?.call();
  }

  Future<void> _handleNewChatFromJsonFile() async {
    if (!widget.enabled || widget.sending) return;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.path == null) return;
      final jsonContent = await File(file.path!).readAsString();
      await widget.onNewChatFromJson!(jsonContent);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load JSON file: $e')),
      );
    }
  }

  @override
  void dispose() {
    // Only dispose the controller if we own it.
    if (widget.controller == null) {
      _controller.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _pickAttachments() async {
    if (!widget.enabled || widget.sending) return;
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: false, // we read manually so we control encoding & size
      );
      if (result == null || result.files.isEmpty) return;
      final entries = <({String name, String? path})>[
        for (final f in result.files) (name: f.name, path: f.path),
      ];
      await _addFilesFromEntries(entries);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File pick failed: $e')),
      );
    }
  }

  /// Called by `desktop_drop` when the user drops one or more OS files
  /// onto the input. Routes them through the same loader as the picker.
  Future<void> _onFilesDropped(List<XFile> files) async {
    if (!widget.enabled || widget.sending || files.isEmpty) return;
    final entries = <({String name, String? path})>[
      for (final f in files) (name: f.name, path: f.path),
    ];
    await _addFilesFromEntries(entries);
  }

  /// Shared loader used by both the file picker and the drop target. Reads
  /// each entry off disk (with size cap + UTF-8 decode + dedup), then
  /// pushes the results into `_attachments`. Errors are batched into a
  /// single snackbar so the user sees them all at once.
  Future<void> _addFilesFromEntries(List<({String name, String? path})> entries) async {
    final messenger = ScaffoldMessenger.of(context);
    final added = <_Attachment>[];
    final skipped = <String>[];

    for (final f in entries) {
      final p = f.path;
      if (p == null) {
        skipped.add('${f.name} (no path)');
        continue;
      }
      // Reject directories — desktop_drop happily reports them but we only
      // support text files. Folder ingestion would need recursion + filtering.
      if (FileSystemEntity.isDirectorySync(p)) {
        skipped.add('${f.name} (folder)');
        continue;
      }
      // Skip duplicates by absolute path.
      if (_attachments.any((a) => a.path == p) || added.any((a) => a.path == p)) {
        continue;
      }
      try {
        final file = File(p);
        final size = await file.length();
        String content;
        bool truncated = false;
        if (size > _kMaxAttachmentBytes) {
          // Read only the prefix and mark the file as truncated so the
          // model knows it didn't see the full file.
          final raw = await file.openRead(0, _kMaxAttachmentBytes).fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          content = utf8.decode(raw, allowMalformed: true);
          truncated = true;
        } else {
          try {
            content = await file.readAsString();
          } on FormatException {
            // Binary or non-UTF-8 file.
            skipped.add('${f.name} (not text)');
            continue;
          }
        }
        added.add(_Attachment(
          name: f.name,
          path: p,
          content: content,
          byteSize: size,
          truncated: truncated,
        ));
      } catch (e) {
        skipped.add('${f.name} ($e)');
      }
    }

    if (added.isNotEmpty) {
      setState(() => _attachments.addAll(added));
    }
    if (skipped.isNotEmpty && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Skipped: ${skipped.join(', ')}'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _removeAttachment(_Attachment a) {
    setState(() => _attachments.removeWhere((x) => x.path == a.path));
  }

  Future<void> _showAttachmentPreview(_Attachment a) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.description_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                a.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            if (a.truncated)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Tooltip(
                  message: 'Truncated to first 200 KB',
                  child: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 760,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${a.path}  ·  ${_formatBytes(a.byteSize)}'
                '${a.truncated ? '  ·  truncated' : ''}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        a.content,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy all'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: a.content));
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('Copied to clipboard'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// Build the final message sent to the model: the user's typed prompt,
  /// followed by each attached file rendered as a fenced block. Format:
  ///
  ///   < user text >
  ///
  ///   --- File: lib/foo.dart ---
  ///   ```dart
  ///   <content>
  ///   ```
  ///
  ///   --- File: README.md ---
  ///   ```md
  ///   <content>
  ///   ```
  ///
  /// Same regardless of backend or tool support — the orchestrator just
  /// sees a longer user message.
  String _composeMessage(String userText) {
    if (_attachments.isEmpty) return userText;
    final buf = StringBuffer(userText.trimRight());
    if (userText.trim().isNotEmpty) buf.write('\n\n');
    for (final a in _attachments) {
      final fence = _fenceLangFor(a.name);
      buf.write('--- File: ${a.name} ---');
      if (a.truncated) buf.write(' (truncated to first 200 KB)');
      buf.write('\n```$fence\n');
      buf.write(a.content);
      if (!a.content.endsWith('\n')) buf.write('\n');
      buf.write('```\n\n');
    }
    return buf.toString().trimRight();
  }

  static String _fenceLangFor(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return '';
    final ext = filename.substring(dot + 1).toLowerCase();
    const map = {
      'dart': 'dart',
      'py': 'python',
      'js': 'javascript',
      'ts': 'typescript',
      'tsx': 'tsx',
      'jsx': 'jsx',
      'json': 'json',
      'yaml': 'yaml',
      'yml': 'yaml',
      'md': 'markdown',
      'sh': 'bash',
      'bash': 'bash',
      'java': 'java',
      'kt': 'kotlin',
      'swift': 'swift',
      'go': 'go',
      'rs': 'rust',
      'cpp': 'cpp',
      'cc': 'cpp',
      'c': 'c',
      'h': 'c',
      'hpp': 'cpp',
      'cs': 'csharp',
      'rb': 'ruby',
      'php': 'php',
      'html': 'html',
      'css': 'css',
      'sql': 'sql',
      'xml': 'xml',
      'toml': 'toml',
      'ini': 'ini',
    };
    return map[ext] ?? '';
  }

  Future<void> _handleSend() async {
    final text = _controller.text;
    // Allow send when there's text OR when there's at least one attachment
    // (e.g. "here's the file, take a look").
    if (!widget.enabled) return;
    if (text.trim().isEmpty && _attachments.isEmpty) return;

    final composed = _composeMessage(text);
    _controller.clear();
    _templateActive = false;
    final attachmentsSnapshot = List<_Attachment>.from(_attachments);
    setState(() => _attachments.clear());

    try {
      await widget.onSend(composed);
    } catch (_) {
      // Restore attachments on failure so the user doesn't lose them.
      if (mounted) setState(() => _attachments.addAll(attachmentsSnapshot));
      rethrow;
    }
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
      _handleSend();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      color: AppTheme.bgPrimary,
      child: Center(
        child: SizedBox(
          child: DropTarget(
            enable: widget.enabled && !widget.sending,
            onDragEntered: (_) {
              if (mounted) setState(() => _dragging = true);
            },
            onDragExited: (_) {
              if (mounted) setState(() => _dragging = false);
            },
            onDragDone: (details) async {
              if (mounted) setState(() => _dragging = false);
              await _onFilesDropped(details.files);
            },
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _dragging ? AppTheme.accent : AppTheme.border,
                  width: _dragging ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(12),
                color: _dragging ? AppTheme.accent.withAlpha(12) : null,
              ),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_dragging)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 2, 4, 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.file_download_outlined, size: 16, color: AppTheme.accent),
                          SizedBox(width: 6),
                          Text(
                            'Drop files to attach',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_attachments.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: _attachments
                            .map((a) => _AttachmentChip(
                                  attachment: a,
                                  onTap: () => _showAttachmentPreview(a),
                                  onRemove: () => _removeAttachment(a),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _NewChatFromJsonButton(
                        enabled: widget.enabled && !widget.sending,
                        onTap: _handleNewChatFromJsonFile,
                      ),
                      const SizedBox(width: 10),
                      _DownloadButton(
                        enabled: widget.enabled && !widget.sending,
                        onDownload: widget.onDownload,
                        onCopyToClipboard: widget.onCopyToClipboard,
                        onDownloadAsMarkdown: widget.onDownloadAsMarkdown,
                        onCopyToClipboardAsMarkdown: widget.onCopyToClipboardAsMarkdown,
                      ),
                      const SizedBox(width: 10),
                      _AttachButton(
                        enabled: widget.enabled && !widget.sending,
                        onTap: _pickAttachments,
                      ),
                      const SizedBox(width: 10),
                      _TemplateButton(
                        enabled: widget.enabled && !widget.sending,
                        active: _templateActive,
                        onTap: _toggleTemplate,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 50, maxHeight: 400),
                          child: Focus(
                            onKeyEvent: _onKey,
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              enabled: widget.enabled,
                              autofocus: true,
                              minLines: 1,
                              maxLines: 8,
                              style: const TextStyle(
                                fontSize: 14.5,
                                color: AppTheme.textPrimary,
                                height: 1.4,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'Message...',
                                hintStyle: TextStyle(color: AppTheme.textMuted),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _SendButton(
                        enabled: widget.enabled && !widget.sending,
                        sending: widget.sending,
                        onTap: _handleSend,
                        onStop: widget.onStop,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ProjectFolderButton(
                            folderName: _currentProjectFolder,
                            projectFolders: _projectFolders,
                            onSelectProject: _switchToProject,
                            onOpenSettings: _openSettingsForProjects,
                          ),
                          const SizedBox(width: 6),
                          _AutoAgentContextButton(
                            enabled: widget.enabled && !widget.sending && _projectService.hasExplicitFolder,
                            onTap: widget.onAutoGenerateAgentContext != null ? _autoGenerateAgentContext : null,
                          ),
                          const SizedBox(width: 8),
                          if (widget.showLogToggle) ...[
                            _LogToggleButton(
                              visible: widget.logVisible,
                              onTap: widget.onToggleLog,
                            ),
                          ],
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_branches.isNotEmpty)
                            Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                constraints: const BoxConstraints(maxHeight: 28),
                                alignment: Alignment.centerRight,
                                decoration: BoxDecoration(color: AppTheme.bgSecondary, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.accentSecondary, width: 0.5)),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Git: ', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    const SizedBox(width: 5),
                                    DropdownButton<String>(
                                      value: _selectedBranch.isNotEmpty ? _selectedBranch : null,
                                      hint: const Align(alignment: Alignment.centerRight, child: Text('Branch', style: TextStyle(fontSize: 12))),
                                      underline: const SizedBox(),
                                      items: [
                                        ..._branches.map((b) => DropdownMenuItem<String>(
                                            value: b, child: Align(alignment: Alignment.centerRight, child: Text(b, style: const TextStyle(fontWeight: FontWeight.normal, fontSize: 12))))),
                                        const DropdownMenuItem<String>(
                                          value: 'CREATE_NEW',
                                          child: Align(alignment: Alignment.centerRight, child: Text('Create...', style: TextStyle(color: AppTheme.accent, fontSize: 12))),
                                        ),
                                      ],
                                      onChanged: (val) async {
                                        if (val == 'CREATE_NEW') {
                                          await _createBranch();
                                        } else if (val != null) {
                                          await _checkoutBranch(val);
                                        }
                                      },
                                    ),
                                  ],
                                )),
                          if (_branches.isNotEmpty) const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            constraints: const BoxConstraints(maxHeight: 28),
                            alignment: Alignment.centerRight,
                            decoration: BoxDecoration(
                              color: AppTheme.bgSecondary,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppTheme.accentSecondary, width: 0.5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Spell: ', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                const SizedBox(width: 5),
                                DropdownButton<String>(
                                  value: _spellCheckLanguage,
                                  underline: const SizedBox(),
                                  items: const [
                                    DropdownMenuItem<String>(
                                      value: 'en',
                                      child: Align(alignment: Alignment.centerRight, child: Text('English', style: TextStyle(fontWeight: FontWeight.normal, fontSize: 12))),
                                    ),
                                    DropdownMenuItem<String>(
                                      value: 'it',
                                      child: Align(alignment: Alignment.centerRight, child: Text('Italiano', style: TextStyle(fontWeight: FontWeight.normal, fontSize: 12))),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) _setSpellCheckLanguage(val);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TextEditingController that highlights misspelled words in the chat input.
/// The spell checker is owned by [_ChatInputState] and swapped when the user
/// changes language; the controller reads the current instance on every
/// rebuild so the highlight always reflects the active dictionary.
class SpellCheckController extends TextEditingController {
  SimpleSpellChecker? spellChecker;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final checker = spellChecker;
    if (checker == null || text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final spans = checker.check(
      text,
      wrongStyle: const TextStyle(
        color: AppTheme.danger,
        decoration: TextDecoration.underline,
        decorationColor: AppTheme.danger,
        decorationStyle: TextDecorationStyle.wavy,
      ),
      commonStyle: style ?? const TextStyle(),
    );

    if (spans == null || spans.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    return TextSpan(style: style, children: spans);
  }
}

/// Plain-data record for an attached file held in [_ChatInputState].
class _Attachment {
  final String name;
  final String path;
  final String content;
  final int byteSize;
  final bool truncated;

  const _Attachment({
    required this.name,
    required this.path,
    required this.content,
    required this.byteSize,
    required this.truncated,
  });
}

/// Paperclip icon at the left of the message input.
class _AttachButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _AttachButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Attach files (text)',
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.border, width: 0.5),
            ),
            child: Icon(
              Icons.attach_file,
              size: 18,
              color: enabled ? AppTheme.textSecondary : AppTheme.textMuted,
            ),
          ),
        ),
      );
}

/// Chip rendered for each attached file. Tap → preview dialog. The little
/// "x" removes the attachment from the pending send.
class _AttachmentChip extends StatelessWidget {
  final _Attachment attachment;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _AttachmentChip({
    required this.attachment,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${attachment.path}\nClick to preview',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.description_outlined, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  attachment.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _ChatInputState._formatBytes(attachment.byteSize),
                style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
              ),
              if (attachment.truncated) ...[
                const SizedBox(width: 4),
                const Tooltip(
                  message: 'Truncated to first 200 KB',
                  child: Icon(Icons.warning_amber_rounded, size: 12, color: Colors.orange),
                ),
              ],
              const SizedBox(width: 4),
              InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 12, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogToggleButton extends StatelessWidget {
  final bool visible;
  final VoidCallback? onTap;

  const _LogToggleButton({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: visible ? 'Hide orchestrator log' : 'Show orchestrator log',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.accentSecondary, width: 0.5),
            ),
            child: Icon(
              visible ? Icons.terminal : Icons.terminal_outlined,
              size: 16,
              color: visible ? AppTheme.accentTernary : AppTheme.textSecondary,
            ),
          ),
        ),
      );
}

class _ProjectFolderButton extends StatelessWidget {
  final String folderName;
  final List<String> projectFolders;
  final ValueChanged<String> onSelectProject;
  final VoidCallback onOpenSettings;

  const _ProjectFolderButton({
    required this.folderName,
    required this.projectFolders,
    required this.onSelectProject,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final items = <PopupMenuEntry<String>>[
      for (final p in projectFolders)
        PopupMenuItem<String>(
          height: 30,
          value: p,
          child: Row(
            children: [
              const Icon(Icons.folder, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.split(Platform.pathSeparator).last,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      const PopupMenuDivider(height: 4),
      const PopupMenuItem<String>(
        height: 30,
        value: '__add__',
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: AppTheme.accent),
            SizedBox(width: 8),
            Text('Manage projects...', style: TextStyle(fontSize: 13, color: AppTheme.accent)),
          ],
        ),
      ),
    ];

    return PopupMenuButton<String>(
      tooltip: 'Switch project folder',
      offset: const Offset(0, 32),
      onSelected: (value) {
        if (value == '__add__') {
          onOpenSettings();
        } else {
          onSelectProject(value);
        }
      },
      itemBuilder: (_) => items,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.bgSecondary,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.accentSecondary, width: 0.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.folder, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(folderName, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
          const SizedBox(width: 2),
          const Icon(Icons.keyboard_arrow_down, size: 14, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool enabled;
  final bool sending;
  final VoidCallback onTap;
  final VoidCallback? onStop;

  const _SendButton({
    required this.enabled,
    required this.sending,
    required this.onTap,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    // While generating — show a red stop button.
    if (sending) {
      return Tooltip(
        message: 'Stop generation',
        child: Material(
          color: AppTheme.danger,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onStop,
            child: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              child: const Icon(Icons.stop_outlined, size: 30, color: Colors.grey),
            ),
          ),
        ),
      );
    }
    // Normal send button.
    return Material(
      color: enabled ? AppTheme.accentSecondary : AppTheme.border,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(
            Icons.arrow_upward,
            size: 18,
            color: enabled ? Colors.brown[900] : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _DownloadButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback? onDownload;
  final VoidCallback? onCopyToClipboard;
  final VoidCallback? onDownloadAsMarkdown;
  final VoidCallback? onCopyToClipboardAsMarkdown;

  const _DownloadButton({
    required this.enabled,
    this.onDownload,
    this.onCopyToClipboard,
    this.onDownloadAsMarkdown,
    this.onCopyToClipboardAsMarkdown,
  });

  @override
  State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  void _showMenu() {
    final button = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    showMenu(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          enabled: widget.enabled,
          onTap: widget.onDownload,
          child: const Row(
            children: [
              Icon(Icons.download_outlined, size: 18),
              SizedBox(width: 12),
              Text('Download as JSON'),
            ],
          ),
        ),
        PopupMenuItem(
          enabled: widget.enabled,
          onTap: widget.onCopyToClipboard,
          child: const Row(
            children: [
              Icon(Icons.content_copy_outlined, size: 18),
              SizedBox(width: 12),
              Text('Copy to Clipboard as JSON'),
            ],
          ),
        ),
        PopupMenuItem(
          enabled: widget.enabled,
          onTap: widget.onDownloadAsMarkdown,
          child: const Row(
            children: [
              Icon(Icons.download_outlined, size: 18),
              SizedBox(width: 12),
              Text('Download as Markdown'),
            ],
          ),
        ),
        PopupMenuItem(
          enabled: widget.enabled,
          onTap: widget.onCopyToClipboardAsMarkdown,
          child: const Row(
            children: [
              Icon(Icons.content_copy_outlined, size: 18),
              SizedBox(width: 12),
              Text('Copy to Clipboard as Markdown'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Download chat as JSON',
        child: InkWell(
          onTap: widget.enabled ? _showMenu : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.border, width: 0.5),
            ),
            child: Icon(
              Icons.download_outlined,
              size: 18,
              color: widget.enabled ? AppTheme.textSecondary : AppTheme.textMuted,
            ),
          ),
        ),
      );
}

/// Toggle button that inserts/clears a model-friendly Markdown template
/// in the chat input. When active the icon is highlighted; tapping again
/// clears the input and deactivates.
class _TemplateButton extends StatelessWidget {
  final bool enabled;
  final bool active;
  final VoidCallback onTap;

  const _TemplateButton({
    required this.enabled,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: active ? 'Clear template' : 'Insert model-friendly template',
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: active ? AppTheme.accent.withAlpha(30) : AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: active ? AppTheme.accent : AppTheme.border, width: 0.5),
            ),
            child: Icon(
              Icons.description_outlined,
              size: 18,
              color: active ? AppTheme.accent : (enabled ? AppTheme.textSecondary : AppTheme.textMuted),
            ),
          ),
        ),
      );
}

/// Small icon button placed right next to the project-folder dropdown.
/// On tap it fires a one-shot prompt that asks the current agent to analyse
/// the project and write a `.context.md` file.
class _AutoAgentContextButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;

  const _AutoAgentContextButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Auto-generate .agentic/.context.md from project analysis',
        child: InkWell(
          onTap: (enabled && onTap != null) ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? AppTheme.accent.withAlpha(25) : AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: enabled ? AppTheme.accentSecondary : AppTheme.border,  width: 0.5
              ),
            ),
            child: Icon(
              Icons.auto_awesome,
              size: 14,
              color: enabled ? AppTheme.accentSecondary : AppTheme.textMuted,
            ),
          ),
        ),
      );
}

/// Button to create a new chat from JSON context (excluding conversation node).
/// Positioned to the left of the download button.
class _NewChatFromJsonButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;

  const _NewChatFromJsonButton({required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'New chat from JSON context',
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: enabled ? AppTheme.accent.withAlpha(30) : AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: enabled ? AppTheme.accentSecondary : AppTheme.border, width: 0.5),
            ),
            child: Icon(
              Icons.chat_outlined,
              size: 18,
              color: enabled ? AppTheme.accentSecondary : AppTheme.textMuted,
            ),
          ),
        ),
      );
}
