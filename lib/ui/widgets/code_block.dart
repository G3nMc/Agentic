import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/theme/app_theme.dart';

class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Inline code: render default.
    final isInline = element.tag == "code" && (element.attributes["class"] == null || element.attributes["class"]!.isEmpty);

    final text = element.textContent;

    if (isInline && !text.contains("\n")) {
      return RichText(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            backgroundColor: AppTheme.accentDarkMarrone,
            fontFamily: "monospace",
            color: AppTheme.textPrimary,
            fontSize: 13.5,
          ),
        ),
      );
    }

    // Fenced code block with optional language class "language-xxx".
    String language = "";
    final classAttr = element.attributes["class"];
    if (classAttr != null && classAttr.startsWith("language-")) {
      language = classAttr.substring("language-".length);
    }

    return _CodeBlockView(code: text, language: language);
  }
}

class _CodeBlockView extends StatelessWidget {
  final String code;
  final String language;

  const _CodeBlockView({required this.code, required this.language});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.codeBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 6),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? "code" : language,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                    letterSpacing: 0.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                _CopyButton(code: code),
              ],
            ),
          ),
          Container(
            height: 1,
            color: AppTheme.textMuted.withOpacity(0.15),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: HighlightView(
              code,
              language: language.isEmpty ? "plaintext" : language,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(10),
              textStyle: const TextStyle(
                fontFamily: "monospace",
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String code;

  const _CopyButton({required this.code});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _copy,
      style: TextButton.styleFrom(
        foregroundColor: AppTheme.codeText,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 28),
        textStyle: const TextStyle(fontSize: 12),
      ),
      icon: Icon(
        _copied ? Icons.check : Icons.copy_outlined,
        size: 13,
        color: AppTheme.codeText,
      ),
      label: Text(
        _copied ? "Copied" : "Copy",
        style: const TextStyle(color: AppTheme.codeText),
      ),
    );
  }
}
