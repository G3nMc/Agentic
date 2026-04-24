import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Developer Dark Theme Palette
  static const Color bgPrimary = Color(0xFF121212);
  static const Color bgSecondary = Color(0xFF1E1E1E);
  static const Color bgSidebar = Color(0xFF181818);
  static const Color border = Color(0xFF333333);
  static const Color textPrimary = Color(0xFFE1E1E1);
  static const Color textSecondary = Color(0xFFB0B0B0);
  static const Color textMuted = Color(0xFF757575);
  static const Color accent = Color(0xFFB95A50);
  static const Color accentMarrone = Color(0xFFD25A50);
  static const Color accentDarkMarrone = Color(0xFF783C32);
  static const Color accentHover = Color(0xFFD7B7FD);
  static const Color userBubble = Color(0xFF2C2C2C);
  static const Color aiBubble = Color(0xFF1E1E1E);
  static const Color codeBg = Color(0xFF000000);
  static const Color codeText = Color(0xFFD4D4D4);
  static const Color danger = Color(0xFFCF6679);

  static ThemeData darkTheme() {
    const baseFont = "SystemFont";

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgPrimary,
      fontFamily: baseFont,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: Colors.black,
        secondary: textSecondary,
        onSecondary: Colors.black,
        surface: bgPrimary,
        onSurface: textPrimary,
        error: danger,
        onError: Colors.white,
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: textPrimary, fontSize: 15, height: 1.5),
        bodyMedium: TextStyle(color: textPrimary, fontSize: 14, height: 1.5),
        bodySmall: TextStyle(color: textSecondary, fontSize: 13, height: 1.4),
        titleLarge: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
        labelLarge: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      dividerColor: border,
      iconTheme: const IconThemeData(color: textSecondary, size: 20),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSecondary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
        hintStyle: const TextStyle(color: textMuted, fontSize: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.black,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgSecondary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: bgSecondary,
        contentTextStyle: TextStyle(color: textPrimary, fontSize: 14),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
