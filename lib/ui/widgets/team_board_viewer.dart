import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/theme/app_theme.dart';
import '../../services/orchestrator_manager.dart';

/// Read-only viewer for a Team Mode session's `team_board.md`.
///
/// Path convention (must stay in sync with `bin/agent/team/paths.py`):
///     `<basePath>/.agent/team/<sessionId>/team_board.md`
///
/// When [sessionId] is null, the viewer falls back to the conversation
/// id of the most recent orchestrator request (held by
/// [OrchestratorManager.currentSessionKey]). If that's also null, it
/// shows the legacy `_default` folder so old data is still reachable.
///
/// The widget polls the file once a second so the user sees workers
/// progress through their plan in near real-time without us needing to
/// plumb a fancy IPC channel.
class TeamBoardViewer extends StatefulWidget {
  const TeamBoardViewer({
    super.key,
    required this.basePath,
    this.sessionId,
  });

  /// Project root — same one the orchestrator is launched against.
  final String basePath;

  /// Conversation id (UUID) for the chat whose Team Mode board we
  /// want to show. Null = pick the latest active conversation.
  final String? sessionId;

  static const Duration _pollInterval = Duration(seconds: 1);

  @override
  State<TeamBoardViewer> createState() => _TeamBoardViewerState();
}

class _TeamBoardViewerState extends State<TeamBoardViewer> {
  String? _content;
  String? _error;
  Timer? _timer;
  DateTime? _lastModified;
  late String _resolvedSessionId;

  String _resolveSessionId() {
    final fromWidget = widget.sessionId?.trim();
    if (fromWidget != null && fromWidget.isNotEmpty) return fromWidget;
    final fromManager =
        OrchestratorManager.instance.currentSessionKey?.trim();
    if (fromManager != null && fromManager.isNotEmpty) return fromManager;
    return '_default';
  }

  String get _boardPath {
    final sep = Platform.pathSeparator;
    return '${widget.basePath}$sep.agent${sep}team$sep$_resolvedSessionId${sep}team_board.md';
  }

  @override
  void initState() {
    super.initState();
    _resolvedSessionId = _resolveSessionId();
    _refresh();
    _timer = Timer.periodic(TeamBoardViewer._pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // Re-resolve every tick so the viewer follows the active
      // conversation if the user kicked off a new run while the viewer
      // was open.
      final fresh = _resolveSessionId();
      if (fresh != _resolvedSessionId) {
        _resolvedSessionId = fresh;
        _lastModified = null;
      }
      final f = File(_boardPath);
      if (!await f.exists()) {
        if (mounted && (_content != null || _error == null)) {
          setState(() {
            _content = null;
            _error = 'No team_board.md yet for this chat. '
                'Start a Team Mode session first.\n\nLooking at:\n$_boardPath';
          });
        }
        return;
      }
      final stat = await f.stat();
      if (_lastModified != null && stat.modified == _lastModified) return;
      final text = await f.readAsString();
      if (!mounted) return;
      setState(() {
        _content = text;
        _error = null;
        _lastModified = stat.modified;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _content = null;
        _error = 'Failed to read board: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgSecondary,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Team Board',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
            Text('session: $_resolvedSessionId',
                style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.normal)),
          ],
        ),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh now',
            onPressed: _refresh,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline,
                  color: AppTheme.textMuted, size: 32),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: AppTheme.textMuted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Markdown(
      data: _content!,
      selectable: true,
      padding: const EdgeInsets.all(20),
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        h1: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700),
        h2: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600),
        h3: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600),
        code: const TextStyle(
            color: AppTheme.codeText,
            fontFamily: 'monospace',
            fontSize: 12),
        codeblockDecoration: BoxDecoration(
          color: AppTheme.codeBg,
          borderRadius: BorderRadius.circular(6),
        ),
        tableHead: const TextStyle(
            color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
        tableBody: const TextStyle(
            color: AppTheme.textSecondary, fontSize: 12),
        tableBorder: TableBorder.all(color: AppTheme.border),
        blockquoteDecoration: BoxDecoration(
          color: AppTheme.bgSecondary,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}
