import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../services/orchestrator_manager.dart';

/// Live panel that shows the model's chain-of-thought text emitted by the
/// Python orchestrator as structured ``thinking`` envelopes on stdout.
///
/// Mirrors the visual language of [OrchestratorLogPanel] so the two panels
/// can sit side by side in the same bottom container. Subscribes to
/// [OrchestratorManager.thinkingStream] and keeps a rolling buffer of the
/// most recent reasoning chunks.
class ModelThinkingPanel extends StatefulWidget {
  /// Optional fixed height for the panel. If null, uses internal collapsed/expanded heights.
  final double? height;

  /// Conversation whose session chain-of-thought is shown. Passing it scopes
  /// the panel to that chat's subprocess, so chat B never renders chat A's
  /// reasoning.
  final String? conversationId;

  const ModelThinkingPanel({super.key, this.height, this.conversationId});

  @override
  State<ModelThinkingPanel> createState() => _ModelThinkingPanelState();
}

class _ModelThinkingPanelState extends State<ModelThinkingPanel> {
  static const int _maxVisible = 2000;
  static const double _collapsedHeight = 80.0;
  static const double _expandedHeight = 220.0;

  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  final ScrollController _hScroll = ScrollController();
  StreamSubscription<String>? _sub;
  StreamSubscription<OrchestratorSession>? _sessionSub;
  bool _expanded = false;
  bool _autoScroll = true;

  OrchestratorSession? get _session =>
      OrchestratorManager.instance.peek(widget.conversationId);

  @override
  void initState() {
    super.initState();
    _bind();
    // Sessions are created lazily: promote this panel to a live subscription as
    // soon as the chat's session appears.
    _sessionSub = OrchestratorManager.instance.sessionAdded.listen((session) {
      if (session.conversationId == widget.conversationId) _bind();
    });
  }

  @override
  void didUpdateWidget(ModelThinkingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      setState(_lines.clear);
      _bind();
    }
  }

  /// (Re)subscribe to the thinking stream of the current chat's session.
  void _bind() {
    _sub?.cancel();
    _sub = null;
    final session = _session;
    final last = session?.lastThinking?.trim();
    if (last != null && last.isNotEmpty) _lines.add(last);
    _sub = (session?.thinkingStream ?? const Stream<String>.empty())
        .listen((text) {
      if (!mounted) return;
      final trimmed = text.trim();
      // Ignore empty / whitespace-only events: they are stream noise between
      // reasoning chunks, not a turn-end signal.
      if (trimmed.isEmpty || trimmed == ':') return;
      setState(() {
        _lines.add(trimmed);
        if (_lines.length > _maxVisible) _lines.removeAt(0);
      });
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
            _scroll.animateTo(
              _scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sessionSub?.cancel();
    _scroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contentHeight = widget.height ?? (_expanded ? _expandedHeight : _collapsedHeight);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgCodeOrchOutput,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (_session?.isRunning ?? false)
                          ? Colors.greenAccent
                          : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    (_session?.isRunning ?? false)
                        ? 'Model thinking'
                        : 'Model thinking (stopped)',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFCDD6F4),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  if (_lines.isNotEmpty)
                    Tooltip(
                      message: 'Copy all thinking lines',
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
                  if (!_autoScroll)
                    Tooltip(
                      message: 'Resume auto-scroll',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: _enableAutoScroll,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Icon(
                            Icons.arrow_downward,
                            size: 14,
                            color: Color(0xFF6C7086),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  if (widget.height == null) ...[
                    Icon(
                      _expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                      size: 14,
                      color: const Color(0xFF6C7086),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: AnimatedContainer(
              duration: widget.height != null
                  ? const Duration(milliseconds: 50)
                  : const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              height: widget.height == null ? contentHeight : null,
              child: _lines.isEmpty
                ? const Center(
                    child: Text(
                      'Waiting for model thinking...',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6E6E7D),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollStartNotification &&
                          notification.dragDetails != null) {
                        setState(() => _autoScroll = false);
                      } else if (notification is UserScrollNotification) {
                        setState(() => _autoScroll = false);
                      }
                      return false;
                    },
                    child: SelectionArea(
                      child: Scrollbar(
                        controller: _scroll,
                        thumbVisibility: true,
                        child: Scrollbar(
                          controller: _hScroll,
                          thumbVisibility: true,
                          notificationPredicate: (notification) => notification.depth == 0,
                          child: SingleChildScrollView(
                            controller: _hScroll,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: _contentWidth(),
                              child: ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                                itemCount: _lines.length,
                                itemBuilder: (_, i) {
                                  return Text(
                                    _lines[i],
                                    softWrap: false,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Color(0xFF929AFF),
                                      height: 1.4,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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
        content: Text('Copied ${_lines.length} thinking lines to clipboard'),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  void _enableAutoScroll() {
    setState(() => _autoScroll = true);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  double _contentWidth() {
    if (_lines.isEmpty) return 0;
    final longest = _lines
        .map((line) => line.length)
        .reduce((a, b) => a > b ? a : b);
    return longest * 6.6 + 20;
  }
}