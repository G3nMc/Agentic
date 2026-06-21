import 'package:agentic/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'code_block.dart';

/// Formats a duration in seconds into a human-readable string
/// containing hours, minutes, seconds, and milliseconds.
///
/// Example outputs:
///   - 0.0           → "0h 0m 0s 0ms"
///   - 90.5          → "0h 1m 30s 500ms"
///   - 3661.123      → "1h 1m 1s 123ms"
///   - 86400.999     → "24h 0m 0s 999ms"
String formatDuration(double seconds) {
  final int totalMs = (seconds * 1000).round();
  final int hours = totalMs ~/ 3600000;
  final int remainingAfterHours = totalMs % 3600000;
  final int minutes = remainingAfterHours ~/ 60000;
  final int remainingAfterMinutes = remainingAfterHours % 60000;
  final int secs = remainingAfterMinutes ~/ 1000;
  final int millis = remainingAfterMinutes % 1000;

  return '${hours}h ${minutes}m ${secs}s ${millis}ms';
}

class MessageBubble extends StatefulWidget {
  final String message;
  final double timeInSeconds;
  final bool isUser;
  final VoidCallback? onResend;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;

  /// When true the bubble renders as a compact, non-interactive status
  /// update (e.g. "Working on task #1...") rather than a full assistant
  /// reply. Status bubbles are visually de-emphasised and omit actions.
  final bool isStatus;

  const MessageBubble({
    super.key,
    required this.message,
    required this.timeInSeconds,
    this.isUser = false,
    this.isStatus = false,
    this.onResend,
    this.onDelete,
    this.onEdit,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _copied = false;

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.message));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final timeLabel = formatDuration(widget.timeInSeconds);

    if (widget.isStatus) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: _StatusBubble(message: widget.message),
        ),
      );
    }

    return Align(
      alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: Container(
          margin: EdgeInsets.only(bottom: 16, left: widget.isUser ? 16 : 0, right: widget.isUser ? 0 : 16),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          decoration: BoxDecoration(
            color: widget.isUser ? AppTheme.userBubble : AppTheme.aiBubble,
            border: Border.all(
              width: 0.5,
              color: widget.isUser ? AppTheme.aiBubble : AppTheme.userBubble,
            ),
            borderRadius: BorderRadius.only(
              topLeft: widget.isUser ? const Radius.circular(16) : const Radius.circular(4),
              topRight: widget.isUser ? const Radius.circular(4) : const Radius.circular(16),
              bottomLeft: widget.isUser ? const Radius.circular(16) : const Radius.circular(4),
              bottomRight: widget.isUser ? const Radius.circular(4) : const Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Role label + delete icon ─────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Text(
                    widget.isUser ? "You" : "Assistant",
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Expanded(
                    child: SizedBox(height: 6),
                  ),
                  if (widget.onDelete != null)
                    GestureDetector(
                      onTap: widget.onDelete,
                      child: const Icon(
                        Icons.delete_outline,
                        size: 14,
                        color: AppTheme.accentSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                height: 0.5,
                color: AppTheme.accentTernary,
              ),
              const SizedBox(height: 10),
              // ── Message body (markdown) ────────────────────────────
              SelectionArea(
                child: MarkdownBody(
                  data: widget.message,
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                    code: const TextStyle(
                      backgroundColor: AppTheme.bgCodeMessageBubble,
                      fontFamily: "monospace",
                      color: AppTheme.textPrimary,
                      fontSize: 13.5,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: AppTheme.codeBg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    blockquote: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                    blockquoteDecoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  builders: {
                    "code": CodeBlockBuilder(),
                  },
                ),
              ),
              const SizedBox(height: 6),
              // ── Bottom actions (time, copy, resend) ────────────────
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (widget.onEdit != null) ...[
                      GestureDetector(
                        onTap: widget.onEdit,
                        child: const Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: AppTheme.accentSecondary,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    GestureDetector(
                      onTap: _copied ? null : _copyToClipboard,
                      child: Icon(
                        _copied ? Icons.check : Icons.copy,
                        size: 14,
                        color: _copied ? AppTheme.textMuted : AppTheme.accentSecondary,
                      ),
                    ),
                    if (widget.onResend != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: widget.onResend,
                        child: const Icon(
                          Icons.refresh,
                          size: 14,
                          color: AppTheme.accentSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _StatusBubble extends StatelessWidget {
  final String message;

  const _StatusBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12, left: 0, right: 16),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.aiBubble.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.accentSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
