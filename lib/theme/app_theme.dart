import 'package:flutter/material.dart';

class AppTheme {

  static const Color lightPrimary = Color(0xFF7C3AED);
  static const Color lightAccent = Color(0xFF0EA5E9);
  static const Color lightInk = Color(0xFF1E293B);
  static const Color lightGray700 = Color(0xFF64748B);
  static const Color lightGray500 = Color(0xFF94A3B8);
  static const Color lightGray300 = Color(0xFFCBD5E1);
  static const Color lightGray200 = Color(0xFFE2E8F0);
  static const Color lightGray100 = Color(0xFFF1F5F9);
  static const Color lightWhite = Color(0xFFFFFFFF);
  static const Color lightBackground = Color(0xFFF8FAFC);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: lightPrimary,
        secondary: lightAccent,
        surface: lightWhite,
        onPrimary: lightWhite,
        onSecondary: lightWhite,
        onSurface: lightInk,
      ),
      scaffoldBackgroundColor: const Color(0xFF0B1120),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0B1120),
        foregroundColor: lightWhite,
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: lightPrimary,
          foregroundColor: lightWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF1F2937),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        elevation: 0,
        margin: EdgeInsets.all(8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF080C1B),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF374151)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF374151)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: lightPrimary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      iconTheme: const IconThemeData(
        color: lightWhite,
        size: 24,
      ),
    );
  }
}
