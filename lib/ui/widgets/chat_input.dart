import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_theme.dart';
import '../../services/project_service.dart';

class ChatInput extends StatefulWidget {
  final bool enabled;
  final bool sending;
  final Future<void> Function(String text) onSend;
  const ChatInput({super.key, required this.enabled, required this.sending, required this.onSend});
  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _projectService = ProjectService();
  String _currentProjectFolder = 'Select folder...';

  @override
  void initState() {
    super.initState();
    _loadProjectInfo();
  }

  void _loadProjectInfo() {
    final path = _projectService.currentPath;
    final folderName = path.split(Platform.pathSeparator).last;
    if (folderName.isNotEmpty) {
      setState(() => _currentProjectFolder = folderName);
    }
  }

  Future<void> _pickProjectFolder() async {
    final newPath = await _projectService.pickProjectFolder();
    if (newPath.isNotEmpty && mounted) {
      setState(() => _currentProjectFolder = newPath.split(Platform.pathSeparator).last);
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
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(children: [
              _ProjectFolderButton(
                folderName: _currentProjectFolder,
                onTap: _pickProjectFolder,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44, maxHeight: 200),
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
              const SizedBox(width: 6),
              _SendButton(
                enabled: widget.enabled && !widget.sending,
                sending: widget.sending,
                onTap: _handleSend,
              ),
            ]),
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
          border: Border.all(color: AppTheme.border),
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
  const _SendButton({required this.enabled, required this.sending, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
    color: enabled ? AppTheme.accent : AppTheme.border,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        child: sending
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
            : Icon(Icons.arrow_upward, size: 16, color: enabled ? Colors.white : AppTheme.textMuted),
      ),
    ),
  );
}
