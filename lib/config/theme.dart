import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// LEGACY — kept as a compat shim so unmigrated screens keep compiling.
/// New code should consume `UgamColors.of(context)` from
/// `package:occubusbooking/design/ugam.dart` instead. The constants
/// below now resolve to the new Ugam dark-first palette so that
/// screens still reading them inherit the image-5 aesthetic without
/// having to be touched.
class AppTheme {
  // ── Brand (now bright blue for dark mode) ────────────────────
  static const Color brand = Color(0xFF3B82F6);         // Ugam dark accent
  static const Color brandHover = Color(0xFF2563EB);
  static const Color brandLight = Color(0x293B82F6);    // accentFill (16% alpha)
  static const Color brandLightSolid = Color(0xFF1E3A8A);
  static const Color brandDark = Color(0xFF000000);     // pure black surface
  static const Color brandAccent = Color(0xFFFB923C);   // warm accent

  // ── Status Colors (Ugam-aligned) ───────────────────────────
  static const Color success = Color(0xFF34D399);
  static const Color successLight = Color(0x2934D399);
  static const Color warning = Color(0xFFFB923C);
  static const Color warningLight = Color(0x2EFB923C);
  static const Color danger = Color(0xFFF87171);
  static const Color dangerLight = Color(0x29F87171);
  static const Color info = Color(0xFF3B82F6);
  static const Color infoLight = Color(0x293B82F6);

  // ── Surface (light tokens kept identical so a light-toggle still works,
  //          dark tokens upgraded to the new pure-black palette) ────
  static const Color bgLight = Color(0xFFFBFAF6);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color borderLight = Color(0xFFE8E5DE);
  static const Color borderDefault = Color(0xFFD7D3C9);
  static const Color hoverLight = Color(0xFFF2F1EC);

  static const Color bgDark = Color(0xFF000000);
  static const Color surfaceDark = Color(0xFF141414);
  static const Color cardDark = Color(0xFF141414);
  static const Color borderDark = Color(0xFF222222);

  // ── Text Colors ───────────────────────────────────────────────
  // The legacy `text*` constants below are LIGHT-MODE tokens. They're kept
  // for backwards-compat with existing screens, but new code (or any screen
  // being dark-mode-fixed) should prefer the context-aware accessors in
  // [AppColors] further down — those flip correctly with the theme.
  static const Color textPrimary = Color(0xFF111111);
  static const Color textSecondary = Color(0xFF5A5A57);
  static const Color textMuted = Color(0xFF9A9A95);
  static const Color textInverse = Color(0xFFFFFFFF);

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
  //
  // All shadow lists are `static const` instead of getters so they're
  // single, shared instances — every card with a shadow used to
  // allocate a fresh `List<BoxShadow>` on every paint. Bigger picture:
  // the blur radii have been pulled WAY in. `cardShadow` was previously
  // a two-layer 3px + 24px blur, which on low-end Adreno GPUs adds
  // ~3-8ms of paint per card per frame; with many cards in a list
  // that's most of a dropped frame. The new single-layer 6px blur
  // reads ~identical at arm's length but is ~5× cheaper to rasterise.
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x14000000),
      offset: Offset(0, 2),
      blurRadius: 6,
    ),
  ];

  static const List<BoxShadow> subtleShadow = [
    BoxShadow(
      color: Color(0x0C000000),
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  static const List<BoxShadow> brandShadow = [
    BoxShadow(
      color: Color(0x331746A2),
      offset: Offset(0, 3),
      blurRadius: 8,
    ),
  ];

  static const List<BoxShadow> navShadow = [
    BoxShadow(
      color: Color(0x14000000),
      offset: Offset(0, -1),
      blurRadius: 4,
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
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      // Bundled Inter family — see pubspec.yaml `fonts:` section.
      // Material's default textTheme provides the structure; we just
      // swap the fontFamily and re-style the slots we use. No
      // GoogleFonts.interTextTheme() call so first paint isn't gated
      // on a fonts.gstatic.com download.
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 42, fontWeight: FontWeight.w600,
          color: textPrimary, letterSpacing: -1.5, height: 1.05,
        ),
        displayMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 34, fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 28, fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 22, fontWeight: FontWeight.w700,
          color: textPrimary, letterSpacing: -0.5,
        ),
        headlineSmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 18, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 17, fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        titleMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 15, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleSmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13, fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 16, fontWeight: FontWeight.w400,
          color: textPrimary,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14, fontWeight: FontWeight.w400,
          color: textSecondary,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12, fontWeight: FontWeight.w400,
          color: textMuted,
        ),
        labelLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 16, fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        labelMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13, fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
        labelSmall: TextStyle(
          fontFamily: 'Inter',
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
          textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: brand,
          side: const BorderSide(color: brand, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brand,
          textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 14),
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
        hintStyle: const TextStyle(fontFamily: 'Inter', color: textMuted, fontSize: 15),
        labelStyle: const TextStyle(fontFamily: 'Inter', color: textMuted, fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.5),
        errorStyle: const TextStyle(fontFamily: 'Inter', color: danger, fontSize: 12),
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
        labelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w500),
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
        selectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w500),
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
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: IconThemeData(color: Color(0xFFF1F5F9)),
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          color: Color(0xFFF1F5F9),
          fontSize: 20, fontWeight: FontWeight.w700,
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 42, fontWeight: FontWeight.w600,
          color: Colors.white, letterSpacing: -1.5, height: 1.05,
        ),
        displayMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        headlineLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        headlineSmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white,
        ),
        titleLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 16, fontWeight: FontWeight.w400, color: Color(0xFFF1F5F9),
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFFCBD5E1),
        ),
        bodySmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12, fontWeight: FontWeight.w400, color: Color(0xFF94A3B8),
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
        hintStyle: const TextStyle(fontFamily: 'Inter', color: Color(0xFF475569), fontSize: 15),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF5B8DEF),
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 16),
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
        selectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// Pre-allocated TextStyle constants for the most common typography
/// patterns. Inlining `GoogleFonts.inter(fontSize: 13, ...)` on every
/// build builds a fresh TextStyle on every paint — across the app
/// that's 300+ TextStyle allocations per frame on busy screens. These
/// `final` styles are built once at first reference and reused; pass
/// them to `Text(..., style: AppText.cardTitle)` and override only the
/// color when needed: `style: AppText.cardTitle.copyWith(color: …)`.
///
/// Naming reads weight-then-purpose so common patterns are easy to
/// spot at the call site. When in doubt prefer the closest match and
/// only add a new style when ≥3 screens need it.
class AppText {
  AppText._();

  /// The bundled Inter family — registered in pubspec.yaml as
  /// `assets/fonts/Inter-Variable.ttf`. Resolves synchronously from
  /// the app bundle, no `fonts.gstatic.com` round-trip.
  static const _family = 'Inter';

  // ── Section / label headers (small caps look)
  static const labelCaps = TextStyle(
    fontFamily: _family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
  );

  // ── Page titles
  static const pageTitle = TextStyle(
    fontFamily: _family,
    fontSize: 26,
    fontWeight: FontWeight.w700,
  );
  static const sectionTitle = TextStyle(
    fontFamily: _family,
    fontSize: 18,
    fontWeight: FontWeight.w700,
  );

  // ── Card content
  static const cardTitle = TextStyle(
    fontFamily: _family,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );
  static const cardTitleSm = TextStyle(
    fontFamily: _family,
    fontSize: 15,
    fontWeight: FontWeight.w700,
  );
  static const cardMeta = TextStyle(
    fontFamily: _family,
    fontSize: 11,
  );
  static const cardLabel = TextStyle(
    fontFamily: _family,
    fontSize: 10,
    fontWeight: FontWeight.w500,
  );

  // ── Stats / numeric values
  static const statValue = TextStyle(
    fontFamily: _family,
    fontSize: 16,
    fontWeight: FontWeight.w800,
    height: 1.1,
  );
  static const statValueLg = TextStyle(
    fontFamily: _family,
    fontSize: 26,
    fontWeight: FontWeight.w700,
  );

  // ── Inline buttons / chips
  static const buttonInline = TextStyle(
    fontFamily: _family,
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );
  static const chipText = TextStyle(
    fontFamily: _family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );
  static const chipTextActive = TextStyle(
    fontFamily: _family,
    fontSize: 13,
    fontWeight: FontWeight.w700,
  );

  // ── Badges (status pills, type marks)
  static const badge = TextStyle(
    fontFamily: _family,
    fontSize: 10,
    fontWeight: FontWeight.w700,
  );
  static const badgeSm = TextStyle(
    fontFamily: _family,
    fontSize: 9,
    fontWeight: FontWeight.w700,
  );

  // ── Body
  static const bodyMd = TextStyle(
    fontFamily: _family,
    fontSize: 13,
  );
  static const bodySm = TextStyle(
    fontFamily: _family,
    fontSize: 12,
  );

  // ── "See all" / link-style
  static const link = TextStyle(
    fontFamily: _family,
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
}

/// Theme-aware color accessors.
///
/// Old code uses the static-const `AppTheme.bgLight`, `AppTheme.textPrimary`
/// etc., which only carry the light-mode value. New code (and any screen
/// being dark-mode-fixed) should prefer these context-aware getters so the
/// value flips automatically with the active theme.
///
/// Usage:
/// ```dart
/// Container(color: AppColors.bg(context))
/// Text('...', style: TextStyle(color: AppColors.text(context)))
/// ```
class AppColors {
  AppColors._();

  /// Page background — `Scaffold.backgroundColor`. Light grey on light
  /// mode, deep slate on dark mode.
  static Color bg(BuildContext c) => Theme.of(c).scaffoldBackgroundColor;

  /// Card / surface background — white on light, raised slate on dark.
  static Color surface(BuildContext c) => Theme.of(c).colorScheme.surface;

  /// Slightly elevated surface (for nested cards, sheets).
  static Color surfaceAlt(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
          ? AppTheme.cardDark
          : AppTheme.bgLight;

  /// Primary foreground text — readable against [surface].
  static Color text(BuildContext c) => Theme.of(c).colorScheme.onSurface;

  /// Secondary / muted text — captions, hints, helper copy.
  static Color textMuted(BuildContext c) =>
      Theme.of(c).colorScheme.onSurfaceVariant;

  /// Hairline / divider colour.
  static Color border(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
          ? AppTheme.borderDark
          : AppTheme.borderLight;
}
