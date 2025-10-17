import 'package:flutter/material.dart';

class AppTheme {
  // Light mode colors
  static const Color lightPrimary = Color(0xFF7C3AED); // Purple
  static const Color lightAccent = Color(0xFF0EA5E9); // Sky blue
  static const Color lightInk = Color(0xFF1E293B); // Dark blue-gray
  static const Color lightGray700 = Color(0xFF64748B); // Gray
  static const Color lightGray500 = Color(0xFF94A3B8); // Light gray
  static const Color lightGray300 = Color(0xFFCBD5E1); // Lighter gray
  static const Color lightGray200 = Color(0xFFE2E8F0); // Even lighter gray
  static const Color lightGray100 = Color(0xFFF1F5F9); // Lightest gray
  static const Color lightWhite = Color(0xFFFFFFFF); // White
  static const Color lightBackground = Color(0xFFF8FAFC); // Off-white background

  // Dark mode colors
  static const Color darkPrimary = Color(0xFFA78BFA); // Light purple
  static const Color darkAccent = Color(0xFF38BDF8); // Light blue
  static const Color darkInk = Color(0xFFF1F5F9); // Light gray
  static const Color darkGray700 = Color(0xFFCBD5E1); // Light gray
  static const Color darkGray500 = Color(0xFF64748B); // Medium gray
  static const Color darkGray300 = Color(0xFF475569); // Dark gray
  static const Color darkGray200 = Color(0xFF334155); // Darker gray
  static const Color darkGray100 = Color(0xFF1E293B); // Dark blue-gray
  static const Color darkWhite = Color(0xFF0F172A); // Dark blue
  static const Color darkBackground = Color(0xFF0F172A); // Dark background

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
      scaffoldBackgroundColor: const Color(0xFF0B1120), // Dark background like legacy app
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

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: darkPrimary,
        secondary: darkAccent,
        surface: darkWhite,
        onPrimary: darkWhite,
        onSecondary: darkWhite,
        onSurface: darkInk,
      ),
      scaffoldBackgroundColor: darkBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkInk,
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: darkPrimary,
          foregroundColor: darkWhite,
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
          borderSide: const BorderSide(color: darkPrimary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      iconTheme: const IconThemeData(
        color: darkInk,
        size: 24,
      ),
    );
  }
}
