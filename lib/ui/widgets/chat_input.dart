import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../services/project_service.dart';

class ChatInput extends StatefulWidget {
  final bool enabled;
  final bool sending;
  final Future<void> Function(String text) onSend;

  /// Called when the user taps the stop button during generation.
  final VoidCallback? onStop;

  const ChatInput({
    super.key,
    required this.enabled,
    required this.sending,
    required this.onSend,
    this.onStop,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _projectService = ProjectService();
  String _currentProjectFolder = 'Select folder...';
  List<String> _branches = [];
  String _selectedBranch = '';

  @override
  void initState() {
    super.initState();
    _loadProjectInfo();
    _loadGitBranches();
  }

  void _loadProjectInfo() {
    final path = _projectService.currentPath;
    final folderName = path.split(Platform.pathSeparator).last;
    if (folderName.isNotEmpty) {
      setState(() => _currentProjectFolder = folderName);
    }
  }

  Future<void> _loadGitBranches() async {
    try {
      final repoPath = _projectService.currentPath;
      // Run git command to list branches
      final result = await Process.run('git', ['-C', repoPath, 'branch', '--format=%(refname:short)']);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final branches = output.split('\n').where((b) => b.trim().isNotEmpty).toList();
        setState(() {
          _branches = branches;
          // Set selected branch to current HEAD if not already set
          if (_selectedBranch.isEmpty && branches.isNotEmpty) {
            // Determine current branch
            final headResult = Process.runSync('git', ['-C', repoPath, 'rev-parse', '--abbrev-ref', 'HEAD']);
            if (headResult.exitCode == 0) {
              _selectedBranch = (headResult.stdout as String).trim();
            } else {
              _selectedBranch = branches.first;
            }
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Git error: ${result.stderr}')),
          );
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

  Future<void> _pickProjectFolder() async {
    final newPath = await _projectService.pickProjectFolder();
    if (newPath.isNotEmpty && mounted) {
      setState(() => _currentProjectFolder = newPath.split(Platform.pathSeparator).last);
      // Reload branches for the new project folder
      await _loadGitBranches();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final text = _controller.text;
    if (text.trim().isEmpty || !widget.enabled) return;
    _controller.clear();
    await widget.onSend(text);
    _focusNode.requestFocus();
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
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
      color: AppTheme.bgPrimary,
      child: Center(
        child: SizedBox(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                              contentPadding: EdgeInsets.symmetric(vertical: 10),
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
                // const SizedBox(height: 8),
                Row(
                  children: [
                    _ProjectFolderButton(
                      folderName: _currentProjectFolder,
                      onTap: _pickProjectFolder,
                    ),
                    const SizedBox(width: 8),
                    if (_branches.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Git: ', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          const SizedBox(width: 5),
                          DropdownButton<String>(
                            value: _selectedBranch.isNotEmpty ? _selectedBranch : null,
                            hint: const Text('Branch'),
                            underline: const SizedBox(),
                            items: [
                              ..._branches.map((b) => DropdownMenuItem<String>(value: b, child: Text(b))),
                              const DropdownMenuItem<String>(
                                value: 'CREATE_NEW',
                                child: Text('Create...', style: TextStyle(color: AppTheme.accent)),
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
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectFolderButton extends StatelessWidget {
  final String folderName;
  final VoidCallback onTap;

  const _ProjectFolderButton({required this.folderName, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Click to select project folder',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.accent),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.folder, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 4),
              Text(folderName, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary, fontWeight: FontWeight.w500)),
              const SizedBox(width: 2),
              const Icon(Icons.keyboard_arrow_down, size: 14, color: AppTheme.textSecondary),
            ]),
          ),
        ),
      );
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
          color: const Color(0xFFE53935),
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
      color: enabled ? AppTheme.accent : AppTheme.border,
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
            color: enabled ? Colors.white : AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}
