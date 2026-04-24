import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../services/llm_service.dart';
import '../../services/openrouter_service.dart';

/// Compact pill that shows OpenRouter credit/usage for the current API key.
///
/// Hidden on non-OpenRouter backends. Tap to refresh.
class OpenRouterUsageBadge extends StatefulWidget {
  const OpenRouterUsageBadge({super.key});

  @override
  State<OpenRouterUsageBadge> createState() => _OpenRouterUsageBadgeState();
}

class _OpenRouterUsageBadgeState extends State<OpenRouterUsageBadge> {
  static const Duration _refreshInterval = Duration(minutes: 2);

  OpenRouterKeyInfo? _info;
  bool _loading = false;
  bool _active = false;
  String? _error;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poller = Timer.periodic(_refreshInterval, (_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    final active = backend == LlmBackend.openRouter || backend == LlmBackend.openRouterOrchestrator;
    if (!active) {
      if (mounted && (_active || _info != null)) {
        setState(() {
          _active = false;
          _info = null;
          _error = null;
        });
      }
      return;
    }

    final apiKey = await BackendSettingsRepository.instance.getOpenRouterApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _active = true;
        _info = null;
        _error = 'No API key';
      });
      return;
    }

    if (!silent && mounted) setState(() => _loading = true);
    final info = await OpenRouterService.instance.fetchKeyInfo(apiKey);
    if (!mounted) return;
    setState(() {
      _active = true;
      _loading = false;
      _info = info;
      _error = info == null ? 'Failed to load' : null;
    });
  }

  String _fmtUsd(double v) {
    if (v >= 100) return '\$${v.toStringAsFixed(0)}';
    if (v >= 10) return '\$${v.toStringAsFixed(1)}';
    return '\$${v.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();

    final String label;
    final Color color;
    final String tooltip;

    if (_loading && _info == null) {
      label = 'Loading…';
      color = AppTheme.textSecondary;
      tooltip = 'Fetching OpenRouter credits';
    } else if (_error != null) {
      label = _error!;
      color = AppTheme.danger;
      tooltip = 'OpenRouter: $_error — tap to retry';
    } else if (_info == null) {
      label = '—';
      color = AppTheme.textSecondary;
      tooltip = 'Tap to refresh';
    } else {
      final info = _info!;
      if (info.limit != null) {
        final remaining = info.limitRemaining ?? 0;
        label = '${_fmtUsd(remaining)} / ${_fmtUsd(info.limit!)}';
        final ratio = info.limit! > 0 ? remaining / info.limit! : 0;
        color = ratio <= 0.1 ? AppTheme.danger : (ratio <= 0.25 ? Colors.orange : AppTheme.accentMarrone);
        tooltip = 'OpenRouter credits remaining\n'
            'Used total: ${_fmtUsd(info.usage)}\n'
            'Today: ${_fmtUsd(info.usageDaily)} · '
            'Week: ${_fmtUsd(info.usageWeekly)} · '
            'Month: ${_fmtUsd(info.usageMonthly)}'
            '${info.isFreeTier ? '\nFree tier' : ''}';
      } else {
        label = 'Used ${_fmtUsd(info.usage)}';
        color = AppTheme.textSecondary;
        tooltip = 'OpenRouter usage (no credit cap)\n'
            'Today: ${_fmtUsd(info.usageDaily)} · '
            'Week: ${_fmtUsd(info.usageWeekly)} · '
            'Month: ${_fmtUsd(info.usageMonthly)}'
            '${info.isFreeTier ? '\nFree tier' : ''}';
      }
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _loading ? null : () => _refresh(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_balance_wallet_outlined, size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_loading) ...[
                const SizedBox(width: 5),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
