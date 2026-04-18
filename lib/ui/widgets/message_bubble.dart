import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/theme/app_theme.dart';
import '../../data/models/message.dart';
import 'code_block.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  bool get _isUser => message.role == MessageRole.user;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isUser ? AppTheme.userBubble : AppTheme.aiBubble,
            border: Border.all(
              color: _isUser ? Colors.transparent : AppTheme.border,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildRoleLabel(),
              const SizedBox(height: 4),
              _buildContent(context),
              const SizedBox(height: 4),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoleLabel() {
    return Text(
      _isUser ? "You" : "Assistant",
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: AppTheme.textMuted,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_isUser) {
      return SelectableText(
        message.content,
        style: const TextStyle(
          fontSize: 14.5,
          color: AppTheme.textPrimary,
          height: 1.5,
        ),
      );
    }
    return MarkdownBody(
      data: message.content,
      selectable: true,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubWeb,
      styleSheet: _markdownStyle(context),
      builders: {"code": CodeBlockBuilder()},
    );
  }

  Widget _buildActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionIcon(
              tooltip: "Copy message",
              icon: Icons.copy,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: message.content));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Copied to clipboard"),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  MarkdownStyleSheet _markdownStyle(BuildContext context) {
    final base = Theme.of(context).textTheme;
    return MarkdownStyleSheet(
      p: base.bodyMedium?.copyWith(
        fontSize: 14.5,
        color: AppTheme.textPrimary,
        height: 1.55,
      ),
      h1: base.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
      h2: base.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
      h3: base.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      listBullet: base.bodyMedium?.copyWith(color: AppTheme.textPrimary),
      code: const TextStyle(
        fontFamily: "monospace",
        backgroundColor: Color(0xFFEFECE5),
        color: AppTheme.textPrimary,
        fontSize: 13.5,
      ),
      codeblockDecoration: BoxDecoration(
        color: AppTheme.codeBg,
        borderRadius: BorderRadius.circular(8),
      ),
      blockquote: TextStyle(color: AppTheme.textSecondary),
      blockquoteDecoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        border: const Border(
          left: BorderSide(color: AppTheme.border, width: 3),
        ),
      ),
      a: const TextStyle(color: AppTheme.accent, decoration: TextDecoration.underline),
    );
  }
}

class _ActionIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered ? AppTheme.accent : AppTheme.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
