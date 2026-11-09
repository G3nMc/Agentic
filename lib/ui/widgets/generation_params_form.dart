import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'token_count_picker.dart';

/// Compact, multi-section helper text used under each generation knob.
/// Split into "What it does / Normal range / Best for / Example" so users can
/// scan instead of reading a wall of grey text. Shown with tiny muted
/// typography so it doesn't dominate the form.
class GenerationHelperBlock extends StatelessWidget {
  const GenerationHelperBlock({
    super.key,
    required this.what,
    required this.normalRange,
    required this.bestFor,
    this.example,
  });

  final String what;
  final String normalRange;
  final List<String> bestFor;
  final String? example;

  static const TextStyle _label = TextStyle(
    color: AppTheme.textMuted,
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle _body = TextStyle(
    color: AppTheme.textMuted,
    fontSize: 11.5,
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(what, style: _body),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Normal: ', style: _label),
              Expanded(child: Text(normalRange, style: _body)),
            ],
          ),
          const SizedBox(height: 2),
          const Text('Best for:', style: _label),
          for (final line in bestFor)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 1),
              child: Text('\u2022 $line', style: _body),
            ),
          if (example != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Example: ', style: _label),
                Expanded(
                  child: Text(
                    example!,
                    style: _body.copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The generation-parameter block shared by Model Settings (Ollama) and every
/// Workflow Agents MaM role card, so both expose the *same* controls with the
/// *same* geometry:
///
///   1. Temperature row — fixed 110 px label, `Expanded` slider over
///      0.0–1.5 with 30 divisions, 40 px right-aligned value.
///   2. A [GenerationHelperBlock] explaining the knob.
///   3. Max output tokens (left) and Context window (right) in one row, each
///      a [TokenCountPicker].
///
/// When [contextEnabled] is false the context picker stays visible but
/// read-only with an explanatory helper, so a value the backend cannot honour
/// is shown honestly instead of being hidden or silently dropped.
class GenerationParamsForm extends StatelessWidget {
  const GenerationParamsForm({
    super.key,
    required this.temperature,
    required this.onTemperatureChanged,
    required this.maxTokensController,
    required this.onMaxTokensChanged,
    required this.contextWindowController,
    required this.onContextWindowChanged,
    this.contextEnabled = true,
    this.providerLabel,
    this.compactHelper = false,
  });

  /// Current temperature. Clamped to 0.0–1.5 for display; the slider geometry
  /// matches Model Settings exactly.
  final double temperature;

  /// Fired continuously while the slider is dragged.
  final ValueChanged<double> onTemperatureChanged;

  final TextEditingController maxTokensController;
  final ValueChanged<String> onMaxTokensChanged;

  final TextEditingController contextWindowController;
  final ValueChanged<String> onContextWindowChanged;

  /// False for providers that manage the context window themselves
  /// (Gemini, Groq, GitHub Models, Hugging Face).
  final bool contextEnabled;

  /// Provider name used in the helper copy that explains why the context
  /// window is ignored.
  final String? providerLabel;

  /// Drops the long prose under the token pickers — used inside the compact
  /// per-role cards where the panel's info banner already explains the knobs.
  final bool compactHelper;

  static const double labelWidth = 110;
  static const double valueWidth = 40;

  @override
  Widget build(BuildContext context) {
    final clamped = temperature.clamp(0.0, 1.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- Temperature --------------------------------------------------
        Row(
          children: [
            const SizedBox(
              width: labelWidth,
              child: Text('Temperature', style: TextStyle(fontSize: 12.5)),
            ),
            Expanded(
              child: Slider(
                value: clamped,
                min: 0.0,
                max: 1.5,
                divisions: 30,
                label: temperature.toStringAsFixed(2),
                onChanged: onTemperatureChanged,
              ),
            ),
            SizedBox(
              width: valueWidth,
              child: Text(
                temperature.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
        if (!compactHelper)
          const GenerationHelperBlock(
            what: 'Controls how random the model is when picking the next word. '
                '0 = always the most likely token (deterministic); higher = '
                'more varied, more creative, more likely to go off-script.',
            normalRange: '0.0 \u2013 1.5 (provider default varies, this app '
                'default 0.2)',
            bestFor: [
              '0.0\u20130.2 \u2014 coding, tool calls, JSON output, anything '
                  'where structure matters. Recommended for the orchestrator.',
              '0.3\u20130.5 \u2014 balanced Q&A, explanations.',
              '0.6\u20130.9 \u2014 brainstorming, writing, chit-chat.',
              '> 1.0 \u2014 rarely useful; output gets incoherent fast.',
            ],
            example: 'Small models follow tool protocols much more reliably '
                'at 0.2 than at 0.7.',
          ),
        const SizedBox(height: 14),

        // ---- Max output tokens | Context window ---------------------------
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TokenCountPicker(
                controller: maxTokensController,
                presets: TokenCountPicker.maxTokensPresets,
                outlined: true,
                isDense: true,
                labelText: 'Max output tokens',
                helperText: 'Reply cap \u2014 must fit inside the context '
                    'window.',
                onChanged: onMaxTokensChanged,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TokenCountPicker(
                controller: contextWindowController,
                presets: TokenCountPicker.numCtxPresets,
                outlined: true,
                isDense: true,
                enabled: contextEnabled,
                labelText: 'Context window',
                hintText: 'e.g. 4096',
                helperText: contextEnabled
                    ? 'Total budget \u2014 keep \u2265 4\u00d7 Max tokens.'
                    : 'Ignored by ${providerLabel ?? 'this provider'} '
                        '(managed by the provider).',
                onChanged: onContextWindowChanged,
              ),
            ),
          ],
        ),
        if (!compactHelper) ...[
          const SizedBox(height: 6),
          const GenerationHelperBlock(
            what: 'Max output tokens caps the REPLY length only \u2014 the model '
                'is forced to stop after this many tokens. Cloud providers bill '
                'per token actually emitted, so raising this does NOT '
                'pre-charge you; it just allows longer answers.',
            normalRange: '256 \u2013 8192 (default 2048). ~1 token \u2248 0.75 '
                'English words or ~3 characters of code.',
            bestFor: [
              '256\u2013512 \u2014 short replies, tool calls, quick '
                  'classification.',
              '1024\u20132048 \u2014 typical coding answers, a single file '
                  'edit, explanations.',
              '4096\u20138192 \u2014 long essays, whole-file rewrites.',
              '16384+ \u2014 only useful with frontier cloud models.',
            ],
            example: 'The context window is the TOTAL budget: system prompt + '
                'tool definitions + history + your message + the reply. Keep '
                'it at least 4\u00d7 the reply cap.',
          ),
        ],
      ],
    );
  }
}