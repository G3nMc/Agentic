import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'ui/screens/home_screen.dart';

class HfChatApp extends StatelessWidget {
  const HfChatApp({super.key});

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
