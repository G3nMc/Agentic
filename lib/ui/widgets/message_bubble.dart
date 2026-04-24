import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/theme/app_theme.dart';
import '../../data/models/message.dart';
import 'code_block.dart';

/// Matches every <think>…</think> block, including multi-line content.
final _thinkPattern = RegExp(
  r'<think>(.*?)</think>',
  dotAll: true,
  caseSensitive: false,
);

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// Called when the user taps "Resend" on a user bubble. Null = hidden.
  final VoidCallback? onResend;

  const MessageBubble({super.key, required this.message, this.onResend});

  bool get _isUser => message.role == MessageRole.user;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isUser ? AppTheme.userBubble : AppTheme.aiBubble,
            border: Border.all(
              width: 0.5,
              color: _isUser ? Colors.transparent : AppTheme.border,
            ),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(_isUser ? 16 : 4),
              topRight: Radius.circular(_isUser ? 4 : 16),
              bottomLeft: Radius.circular(_isUser ? 16 : 4),
              bottomRight: Radius.circular(_isUser ? 4 : 16),
            ),
            // boxShadow: [
            //   BoxShadow(
            //     color: AppTheme.accent,
            //     blurRadius: 10,
            //     offset: const Offset(0, 1),
            //   ),
            // ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildRoleLabel(),
              const SizedBox(height: 6),
              _buildContent(context),
              const SizedBox(height: 6),
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
        fontWeight: FontWeight.w700,
        color: AppTheme.textMuted,
        letterSpacing: 0.5,
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

    // Extract any <think>…</think> blocks so we can render them as a
    // collapsible "Reasoning" section above the main answer.
    final thinkMatches = _thinkPattern.allMatches(message.content).toList();
    if (thinkMatches.isEmpty) {
      return _buildMarkdown(message.content, context);
    }

    final thinking = thinkMatches.map((m) => m.group(1)!.trim()).where((s) => s.isNotEmpty).join('\n\n---\n\n');
    final answer = message.content.replaceAll(_thinkPattern, '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (thinking.isNotEmpty) _ReasoningBlock(content: thinking),
        if (thinking.isNotEmpty && answer.isNotEmpty) const SizedBox(height: 10),
        if (answer.isNotEmpty) _buildMarkdown(answer, context),
      ],
    );
  }

  Widget _buildMarkdown(String data, BuildContext context) {
    return MarkdownBody(
      data: data,
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
            if (_isUser && onResend != null)
              _ActionIcon(
                tooltip: "Resend message",
                icon: Icons.replay_rounded,
                onTap: onResend!,
              ),
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
        color: AppTheme.textPrimary,
        fontSize: 13.5,
      ),
      codeblockDecoration: BoxDecoration(
        color: AppTheme.codeBg,
        borderRadius: BorderRadius.circular(8),
      ),
      blockquote: const TextStyle(color: AppTheme.textSecondary),
      blockquoteDecoration: const BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border(
          left: BorderSide(color: AppTheme.border, width: 3),
        ),
      ),
      a: const TextStyle(color: AppTheme.accent, decoration: TextDecoration.underline),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Collapsible reasoning block
// ─────────────────────────────────────────────────────────────────────────────

class _ReasoningBlock extends StatefulWidget {
  final String content;
  const _ReasoningBlock({required this.content});

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header row (always visible) ──────────────────────────────────
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.psychology_outlined,
                    size: 14,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Reasoning',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _expanded ? 'hide' : 'show',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 14,
                    color: AppTheme.textMuted,
                  ),
                ],
              ),
            ),
          ),
          // ── Expanded content ─────────────────────────────────────────────
          if (_expanded) ...[
            const Divider(height: 1, color: AppTheme.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: SelectableText(
                widget.content,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.textSecondary,
                  height: 1.55,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic action icon (copy, resend, …)
// ─────────────────────────────────────────────────────────────────────────────

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
