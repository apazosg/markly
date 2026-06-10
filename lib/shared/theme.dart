import 'package:flutter/material.dart';

class AppTheme {
  static final dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFE53935),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );
}
