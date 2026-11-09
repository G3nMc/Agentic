import 'dart:async';

import 'package:agentic/statemanagement/method_listener.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/orchestrator_manager.dart';
import '../../statemanagement/method_data.dart';
import '../../statemanagement/state_manager.dart';
import '../widgets/chat_view.dart';
import '../widgets/horizontal_resize_handle.dart';
import '../widgets/sidebar.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends StateManager<HomeScreen> {
  // Currently-open conversation. Null = empty state (no chat open).
  String? _activeConversationId;

  // Sidebar width on desktop.
  static const double _sidebarWidth = 300;

  static const String _sidebarWidthKey = 'sidebar_width';

  double _sidebarWidthValue = _sidebarWidth;

  /// Settings is hosted as a full-window surface *on top of* the chat shell
  /// rather than as a tab beside the conversation list: it takes the whole
  /// window (no sidebar, no project explorer) while [ChatView] stays mounted
  /// underneath, which is what keeps a running turn alive across in-app
  /// navigation.
  bool _showSettings = false;
  int _settingsInitialSection = 0;

  @override
  void initState() {
    super.initState();
    _restoreSidebarWidth();
    // Refresh sidebar data when screen is shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSidebar();
    });
  }

  Future<void> _restoreSidebarWidth() async {
    final saved = await SettingsRepository.instance.get(_sidebarWidthKey);
    final parsed = double.tryParse(saved ?? '');
    if (parsed != null && parsed >= 120.0) {
      if (mounted) setState(() => _sidebarWidthValue = parsed);
    }
  }

  Future<void> _saveSidebarWidth(double width) async {
    await SettingsRepository.instance.set(_sidebarWidthKey, width.toStringAsFixed(1));
  }

  Future<void> _refreshSidebar() async {
    await MethodListener<Sidebar>().callMethod("refreshConversations");
  }

  @override
  void onMethodListener(MethodData methodData) {
    switch (methodData.methodName) {
      case "openConversation":
        final id = methodData.methodParams?["conversationId"] as String?;
        final switching = id != _activeConversationId;
        _activeConversationId = id;
        // Pure navigation. Every conversation owns its own orchestrator
        // session, so opening another chat never restarts, parks or stops the
        // one that is still answering: the reply lands in the chat that
        // dispatched it even while a different chat is on screen.
        OrchestratorManager.instance.setCurrentSession(id);
        if (switching) {
          // Rebuild so the shell hands the new conversation to ChatView.
          setState(() {});
        }
        _refreshSidebar();
        break;
      case "closeActiveConversation":
        _activeConversationId = null;
        setState(() {});
        _refreshSidebar();
        break;
      case "openSettings":
        final section = methodData.methodParams?["section"] as int? ?? 0;
        setState(() {
          _settingsInitialSection = section;
          _showSettings = true;
        });
        break;
      case "closeSettings":
        _closeSettings();
        break;
    }
  }

  /// Return to the conversation. Settings only covers the chat shell, it does
  /// not replace it, so closing it never remounts [ChatView]: a turn in flight
  /// keeps running and its answer still lands in the open conversation.
  void _closeSettings() {
    if (!_showSettings) return;
    setState(() => _showSettings = false);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < 720;

    // Settings is a *surface*, not a tab beside the conversation list: it
    // takes the whole window (no sidebar, no project explorer) while the chat
    // shell below keeps [ChatView] mounted, so a running turn is never
    // interrupted by opening or closing Settings.
    final chatShell = Row(
      children: [
        if (!isCompact) ...[
          SizedBox(
            width: _sidebarWidthValue,
            child: Container(
              decoration: const BoxDecoration(
                color: AppTheme.bgPrimary,
                border: Border(
                  right: BorderSide(color: AppTheme.border),
                ),
              ),
              child: Sidebar(activeConversationId: _activeConversationId),
            ),
          ),
          HorizontalResizeHandle(
            width: _sidebarWidthValue,
            minWidth: 180.0,
            maxWidth: 600.0,
            onWidthChanged: (newWidth) {
              setState(() => _sidebarWidthValue = newWidth);
              _saveSidebarWidth(newWidth);
            },
          ),
        ],
        Expanded(
          // Stable key: switching conversations must reach
          // `ChatView.didUpdateWidget` instead of remounting the whole state,
          // otherwise scroll position, the log panel and an in-flight turn
          // would be lost on every navigation.
          child: ChatView(
            key: const ValueKey('chat-host'),
            conversationId: _activeConversationId,
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      drawer: isCompact && !_showSettings
          ? Drawer(
              backgroundColor: AppTheme.bgSidebar,
              child: Sidebar(activeConversationId: _activeConversationId),
            )
          : null,
      appBar: isCompact && !_showSettings
          ? AppBar(
              backgroundColor: AppTheme.bgPrimary,
              elevation: 0,
              title: const Text(
                "HF Chat",
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              iconTheme: const IconThemeData(color: AppTheme.textPrimary),
            )
          : null,
      body: IndexedStack(
        index: _showSettings ? 1 : 0,
        sizing: StackFit.expand,
        children: [
          chatShell,
          SettingsScreen(
            key: const ValueKey('settings-host'),
            initialSection: _settingsInitialSection,
            onClose: _closeSettings,
          ),
        ],
      ),
    );
  }
}
