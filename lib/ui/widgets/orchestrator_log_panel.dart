import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../services/orchestrator_manager.dart';

/// A collapsible live-log strip that shows orchestrator stderr output.
///
/// Mounts only when an orchestrator backend is active. Subscribes to
/// [OrchestratorManager.logStream] so it updates in real time as the
/// subprocess emits progress lines.
class OrchestratorLogPanel extends StatefulWidget {
  const OrchestratorLogPanel({super.key});

  @override
  State<OrchestratorLogPanel> createState() => _OrchestratorLogPanelState();
}

class _OrchestratorLogPanelState extends State<OrchestratorLogPanel> {
  static const int _maxVisible = 200;
  static const double _collapsedHeight = 80.0;
  static const double _expandedHeight = 220.0;

  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _sub;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Seed from the buffer already in memory (lines emitted before we mounted).
    _lines.addAll(OrchestratorManager.instance.logLines);

    _sub = OrchestratorManager.instance.logStream.listen((line) {
      if (!mounted) return;
      setState(() {
        _lines.add(line);
        if (_lines.length > _maxVisible) _lines.removeAt(0);
      });
      // Auto-scroll to bottom on new line.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Don't render if the orchestrator isn't running and we have no lines yet.
    final hasContent = _lines.isNotEmpty || OrchestratorManager.instance.isRunning;
    if (!hasContent) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2A2A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header bar ──────────────────────────────────────────────────
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  // Status dot
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: OrchestratorManager.instance.isRunning ? Colors.greenAccent : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    OrchestratorManager.instance.isRunning ? 'Orchestrator log' : 'Orchestrator log (stopped)',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFCDD6F4),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  // Copy-all button
                  if (_lines.isNotEmpty)
                    Tooltip(
                      message: 'Copy all log lines',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: _copyAll,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Icon(
                            Icons.copy_all_outlined,
                            size: 14,
                            color: Color(0xFF6C7086),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  // Clear button
                  if (_lines.isNotEmpty)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => setState(() => _lines.clear()),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text(
                          'Clear',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF6C7086),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                    size: 14,
                    color: const Color(0xFF6C7086),
                  ),
                ],
              ),
            ),
          ),

          // ── Log lines ───────────────────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            height: _expanded ? _expandedHeight : _collapsedHeight,
            child: _lines.isEmpty
                ? const Center(
                    child: Text(
                      'Waiting for orchestrator output…',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6C7086),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                      itemCount: _lines.length,
                      itemBuilder: (_, i) {
                        final line = _lines[i];
                        return Text(
                          line,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: _lineColor(line),
                            height: 1.4,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    if (_lines.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_lines.length} log lines to clipboard'),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  /// Colour-code lines by content so users can quickly spot what matters.
  Color _lineColor(String line) {
    final l = line.toLowerCase();
    if (l.contains('error') || l.contains('failed') || l.contains('traceback')) {
      return const Color(0xFFF38BA8); // red
    }
    if (l.contains('warning') || l.contains('warn')) {
      return const Color(0xFFFAB387); // orange
    }
    if (l.contains('tool_call') || l.contains('<tool>') || l.contains('native tool')) {
      return const Color(0xFFA6E3A1); // green — tool activity
    }
    if (l.contains('ready') || l.contains('active') || l.contains('started')) {
      return const Color(0xFF89DCEB); // teal
    }
    if (l.contains('[orch]')) {
      return const Color(0xFFCDD6F4); // bright white for tagged lines
    }
    return const Color(0xFF6C7086); // muted for everything else
  }
}
