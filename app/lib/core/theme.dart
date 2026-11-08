import 'package:flutter/material.dart';

class C {
  static const bg = Color(0xFF0A1A16);
  static const surface = Color(0xFF10231E);
  static const sheet = Color(0xFF173029);
  static const line = Color(0xFF263A34);
  static const text = Color(0xFFF1F5F3);
  static const dim = Color(0xFFA9B8B2);
  static const faint = Color(0xFF6F837C);
  static const green = Color(0xFF7BEA87);
  static const over = Color(0xFF8BEA97);
  static const under = Color(0xFFC4B2F8);
  static const danger = Color(0xFFF08A8A);
  static const ink = Color(0xFF16233F);
  static const inkDim = Color(0xFF5C6B80);
  static const chrome = Color(0xFFEFF2F5);
  static const disabled = Color(0xFF2E3F45);
}

const kCondensed = 'BarlowCondensed';

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(primary: C.green, surface: C.surface, onPrimary: C.bg, secondary: C.under),
    dividerColor: C.line,
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
    inputDecorationTheme: const InputDecorationTheme(
      border: UnderlineInputBorder(borderSide: BorderSide(color: C.line)),
      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: C.line)),
      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: C.green)),
      labelStyle: TextStyle(color: C.dim),
      hintStyle: TextStyle(color: C.faint),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1E3A2E),
      contentTextStyle: TextStyle(color: C.text, fontWeight: FontWeight.w600, fontFamily: 'Inter'),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(side: BorderSide(color: Color(0xFF3B5A4C))),
    ),
  );
}

class T {
  static const h1 = TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: C.text, height: 1.15);
  static const h2 = TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: C.text);
  static const h3 = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.text);
  static const body = TextStyle(fontSize: 15, color: C.text, height: 1.4);
  static const dim = TextStyle(fontSize: 14, color: C.dim, height: 1.4);
  static const small = TextStyle(fontSize: 12, color: C.dim, height: 1.35);
  static const label = TextStyle(fontSize: 12, color: C.dim, fontWeight: FontWeight.w600, letterSpacing: 1.2);
  static const big = TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: C.text, height: 1);
}
