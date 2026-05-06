import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens extracted from busbooking.pen
/// Brand: Deep blue (#1746A2) — accent-primary
/// Warm accent: Amber (#F59E0B) — used for status badges, chips
class AppTheme {
  // ── Brand ────────────────────────────────────────────────────
  static const Color brand = Color(0xFF1746A2);         // accent-primary
  static const Color brandHover = Color(0xFF123B8A);     // accent-primary-hover
  static const Color brandLight = Color(0xFFEFF6FF);     // accent-light
  static const Color brandLightSolid = Color(0xFFDBEAFE);// accent-light-solid
  static const Color brandDark = Color(0xFF0B1120);      // surface-inverse
  static const Color brandAccent = Color(0xFFF59E0B);    // accent-warm (amber)

  // ── Status Colors ──────────────────────────────────────────
  static const Color success = Color(0xFF059669);
  static const Color successLight = Color(0xFFECFDF5);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningLight = Color(0xFFFFF7ED);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerLight = Color(0xFFFEF2F2);
  static const Color info = Color(0xFF0284C7);
  static const Color infoLight = Color(0xFFF0F9FF);

  // ── Surface ───────────────────────────────────────────────────
  static const Color bgLight = Color(0xFFF7F8FB);       // surface-primary
  static const Color surfaceLight = Color(0xFFFFFFFF);   // surface-card
  static const Color cardLight = Color(0xFFFFFFFF);      // surface-card
  static const Color borderLight = Color(0xFFE2E8F0);   // border-light
  static const Color borderDefault = Color(0xFFCBD5E1); // border-default
  static const Color hoverLight = Color(0xFFEEF1F7);    // surface-hover

  static const Color bgDark = Color(0xFF0B1120);
  static const Color surfaceDark = Color(0xFF111827);
  static const Color cardDark = Color(0xFF1E293B);
  static const Color borderDark = Color(0xFF334155);

  // ── Text Colors ───────────────────────────────────────────────
  static const Color textPrimary = Color(0xFF0B1120);    // foreground-primary
  static const Color textSecondary = Color(0xFF475569);  // foreground-secondary
  static const Color textMuted = Color(0xFF94A3B8);      // foreground-muted
  static const Color textInverse = Color(0xFFFFFFFF);    // foreground-inverse

  // ── Gradient helpers ─────────────────────────────────────────
  static const brandGradient = LinearGradient(
    colors: [brand, brandHover],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const successGradient = LinearGradient(
    colors: [Color(0xFF10B981), Color(0xFF059669)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const darkGradient = LinearGradient(
    colors: [Color(0xFF0B1120), Color(0xFF1E293B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── Shadows ──────────────────────────────────────────────────
  static List<BoxShadow> get cardShadow => [
    const BoxShadow(
      color: Color(0x08000000),
      offset: Offset(0, 1),
      blurRadius: 3,
    ),
    const BoxShadow(
      color: Color(0x0A000000),
      offset: Offset(0, 8),
      blurRadius: 24,
    ),
  ];

  static List<BoxShadow> get subtleShadow => [
    const BoxShadow(
      color: Color(0x06000000),
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  static List<BoxShadow> get brandShadow => [
    const BoxShadow(
      color: Color(0x301746A2),
      offset: Offset(0, 4),
      blurRadius: 16,
    ),
    const BoxShadow(
      color: Color(0x181746A2),
      offset: Offset(0, 8),
      blurRadius: 32,
    ),
  ];

  static List<BoxShadow> get navShadow => [
    const BoxShadow(
      color: Color(0x0A000000),
      offset: Offset(0, -2),
      blurRadius: 8,
    ),
  ];

  // ── Light Theme ───────────────────────────────────────────────
  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: brand,
        onPrimary: Colors.white,
        secondary: success,
        onSecondary: Colors.white,
        tertiary: brandAccent,
        surface: surfaceLight,
        onSurface: textPrimary,
        surfaceContainerHighest: bgLight,
        outline: borderLight,
        error: danger,
      ),
      scaffoldBackgroundColor: bgLight,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        centerTitle: false,
        iconTheme: const IconThemeData(color: textPrimary),
        titleTextStyle: GoogleFonts.inter(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      textTheme: GoogleFonts.interTextTheme().copyWith(
        displayLarge: GoogleFonts.inter(
          fontSize: 42, fontWeight: FontWeight.w600,
          color: textPrimary, letterSpacing: -1.5, height: 1.05,
        ),
        displayMedium: GoogleFonts.inter(
          fontSize: 34, fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineLarge: GoogleFonts.inter(
          fontSize: 28, fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineMedium: GoogleFonts.inter(
          fontSize: 22, fontWeight: FontWeight.w700,
          color: textPrimary, letterSpacing: -0.5,
        ),
        headlineSmall: GoogleFonts.inter(
          fontSize: 18, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleLarge: GoogleFonts.inter(
          fontSize: 17, fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        titleMedium: GoogleFonts.inter(
          fontSize: 15, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleSmall: GoogleFonts.inter(
          fontSize: 13, fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
        bodyLarge: GoogleFonts.inter(
          fontSize: 16, fontWeight: FontWeight.w400,
          color: textPrimary,
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 14, fontWeight: FontWeight.w400,
          color: textSecondary,
        ),
        bodySmall: GoogleFonts.inter(
          fontSize: 12, fontWeight: FontWeight.w400,
          color: textMuted,
        ),
        labelLarge: GoogleFonts.inter(
          fontSize: 16, fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        labelMedium: GoogleFonts.inter(
          fontSize: 13, fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
        labelSmall: GoogleFonts.inter(
          fontSize: 11, fontWeight: FontWeight.w500,
          color: textMuted, letterSpacing: 1,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brand,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: brand,
          side: const BorderSide(color: brand, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brand,
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderDefault),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderDefault),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: brand, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: danger, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: danger, width: 2),
        ),
        hintStyle: GoogleFonts.inter(color: textMuted, fontSize: 15),
        labelStyle: GoogleFonts.inter(color: textMuted, fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.5),
        errorStyle: GoogleFonts.inter(color: danger, fontSize: 12),
      ),
      cardTheme: CardThemeData(
        color: cardLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderLight, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: bgLight,
        selectedColor: brandLightSolid,
        labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: const StadiumBorder(),
        side: const BorderSide(color: borderLight),
      ),
      dividerTheme: const DividerThemeData(
        color: borderLight,
        thickness: 1,
        space: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: brand,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: bgLight,
        selectedItemColor: brand,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }

  // ── Dark Theme ────────────────────────────────────────────────
  static ThemeData get darkTheme {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF5B8DEF),
        onPrimary: Color(0xFF0F172A),
        secondary: Color(0xFF34D399),
        onSecondary: Color(0xFF0F172A),
        tertiary: Color(0xFFFBBF24),
        surface: surfaceDark,
        onSurface: Color(0xFFF1F5F9),
        surfaceContainerHighest: bgDark,
        outline: borderDark,
        error: Color(0xFFF87171),
      ),
      scaffoldBackgroundColor: bgDark,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: const IconThemeData(color: Color(0xFFF1F5F9)),
        titleTextStyle: GoogleFonts.inter(
          color: const Color(0xFFF1F5F9),
          fontSize: 20, fontWeight: FontWeight.w700,
        ),
      ),
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: GoogleFonts.inter(
          fontSize: 42, fontWeight: FontWeight.w600,
          color: Colors.white, letterSpacing: -1.5, height: 1.05,
        ),
        displayMedium: GoogleFonts.inter(
          fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        headlineLarge: GoogleFonts.inter(
          fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        headlineMedium: GoogleFonts.inter(
          fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        headlineSmall: GoogleFonts.inter(
          fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white,
        ),
        titleLarge: GoogleFonts.inter(
          fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        bodyLarge: GoogleFonts.inter(
          fontSize: 16, fontWeight: FontWeight.w400, color: const Color(0xFFF1F5F9),
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 14, fontWeight: FontWeight.w400, color: const Color(0xFFCBD5E1),
        ),
        bodySmall: GoogleFonts.inter(
          fontSize: 12, fontWeight: FontWeight.w400, color: const Color(0xFF94A3B8),
        ),
      ),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderDark, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: const Color(0xFF5B8DEF), width: 1.5),
        ),
        hintStyle: GoogleFonts.inter(color: const Color(0xFF475569), fontSize: 15),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF5B8DEF),
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderDark,
        thickness: 1,
        space: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: const Color(0xFF5B8DEF),
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surfaceDark,
        selectedItemColor: const Color(0xFF5B8DEF),
        unselectedItemColor: const Color(0xFF64748B),
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}
