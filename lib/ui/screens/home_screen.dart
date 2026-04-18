import 'package:flutter/material.dart';
import 'package:hf_chat_flutter/statemanagement/method_listener.dart';

import '../../core/theme/app_theme.dart';
import '../../statemanagement/method_data.dart';
import '../../statemanagement/state_manager.dart';
import '../widgets/chat_view.dart';
import '../widgets/sidebar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends StateManager<HomeScreen> {
  // Currently-open conversation. Null = empty state (no chat open).
  String? _activeConversationId;

  // Sidebar width on desktop.
  static const double _sidebarWidth = 280;

  @override
  void initState() {
    super.initState();
    // Refresh sidebar data when screen is shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSidebar();
    });
  }

  Future<void> _refreshSidebar() async {
    await MethodListener<Sidebar>().callMethod("refreshConversations");
  }

  @override
  void onMethodListener(MethodData methodData) {
    switch (methodData.methodName) {
      case "openConversation":
        final id = methodData.methodParams?["conversationId"] as String?;
        _activeConversationId = id;
        break;
      case "closeActiveConversation":
        _activeConversationId = null;
        _refreshSidebar();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < 720;

    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      drawer: isCompact
          ? Drawer(
              backgroundColor: AppTheme.bgSidebar,
              child: Sidebar(activeConversationId: _activeConversationId),
            )
          : null,
      appBar: isCompact
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
      body: Row(
        children: [
          if (!isCompact)
            SizedBox(
              width: _sidebarWidth,
              child: Container(
                decoration: const BoxDecoration(
                  color: AppTheme.bgSidebar,
                  border: Border(
                    right: BorderSide(color: AppTheme.border),
                  ),
                ),
                child: Sidebar(activeConversationId: _activeConversationId),
              ),
            ),
          Expanded(
            child: ChatView(
              key: ValueKey(_activeConversationId ?? "empty"),
              conversationId: _activeConversationId,
            ),
          ),
        ],
      ),
    );
  }
}
