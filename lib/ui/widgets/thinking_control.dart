import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The Thinking ON/OFF switch plus its effort dropdown, extracted from the chat
/// header so a single widget owns the look and behaviour everywhere.
///
/// Two places render it:
///   * the chat header (`chat_view.dart`) in single-model mode, where it owns
///     the per-conversation thinking flag;
///   * every Workflow Agents MaM role card (`agent_workflow_settings.dart`),
///     where each model owns its own thinking flag while MaM is enabled.
///
/// Both get the exact same geometry: a 40x40 bordered square with the
/// psychology icon, tinted with the accent colour when ON, followed by — only
/// while ON — a 40 px high bordered dropdown listing the five effort levels.
class ThinkingControl extends StatelessWidget {
  const ThinkingControl({
    super.key,
    required this.thinking,
    required this.onThinkingChanged,
    required this.effort,
    required this.onEffortChanged,
    this.condense = false,
  });

  /// Reasoning effort levels, in increasing order of budget.
  static const List<String> effortLevels = <String>[
    'minimal',
    'low',
    'medium',
    'high',
    'max',
  ];

  /// Whether extended thinking is currently enabled.
  final bool thinking;

  /// Fired with the new ON/OFF value when the square is tapped.
  final ValueChanged<bool> onThinkingChanged;

  /// Current effort level; one of [effortLevels].
  final String effort;

  /// Fired with the newly selected effort level.
  final ValueChanged<String> onEffortChanged;

  /// Hides the "Thinking" caption label used inside the role cards. The chat
  /// header keeps the bare control so it lines up with the other 40x40 buttons.
  final bool condense;

  static String labelFor(String level) =>
      level.isEmpty ? level : level[0].toUpperCase() + level.substring(1);

  @override
  Widget build(BuildContext context) {
    final toggle = GestureDetector(
      onTap: () => onThinkingChanged(!thinking),
      child: Tooltip(
        message: thinking ? 'Thinking: ON' : 'Thinking: OFF',
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            border: Border.all(
              color: thinking ? AppTheme.accent : AppTheme.accentSecondary,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(8),
            color: thinking
                ? AppTheme.accent.withValues(alpha: 0.1)
                : Colors.transparent,
          ),
          child: Icon(
            Icons.psychology,
            size: 18,
            color: thinking ? AppTheme.accent : AppTheme.textSecondary,
          ),
        ),
      ),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        toggle,
        if (thinking) ...[
          const SizedBox(width: 6),
          _effortDropdown(),
        ],
      ],
    );

    if (condense) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Thinking',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 4),
        row,
      ],
    );
  }

  Widget _effortDropdown() {
    final current = effortLevels.contains(effort) ? effort : 'medium';
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentSecondary, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          isDense: true,
          dropdownColor: AppTheme.bgSecondary,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          icon: const Icon(
            Icons.expand_more,
            size: 14,
            color: AppTheme.textSecondary,
          ),
          items: [
            for (final level in effortLevels)
              DropdownMenuItem<String>(
                value: level,
                child: Text(labelFor(level)),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            onEffortChanged(v);
          },
        ),
      ),
    );
  }
}