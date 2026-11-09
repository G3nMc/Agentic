import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'services/orchestrator_manager.dart';
import 'ui/screens/home_screen.dart';

class ChatApp extends StatefulWidget {
  const ChatApp({super.key});

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // Nothing else tears the subprocess down on quit: without this hook the
    // Python orchestrator is orphaned and the last turn's chat log is never
    // flushed.
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        // Multi-session: every live chat owns a subprocess, so shutting down
        // has to close all of them and let each flush its log file.
        await OrchestratorManager.instance.disposeAll();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "AI Chat",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      home: const HomeScreen(),
    );
  }
}
