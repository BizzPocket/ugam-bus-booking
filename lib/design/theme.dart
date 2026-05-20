import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'text_styles.dart';
import 'tokens.dart';

/// Material `ThemeData` builders for the Ugam UI system — Phase 0.
///
/// Dark is primary; light is a complete mirror, not a fallback. Both
/// themes derive from the same token set so changing a single value in
/// `tokens.dart` flows through every component.
///
/// Per-screen widgets should NOT reach into `Theme.of(context).cardTheme`
/// etc. for visual values — they should consume the tokens directly via
/// `UgamColors.of(context)`. The Material theme exists to style the
/// platform widgets we still depend on (TextField, AppBar, Switch,
/// SnackBar) so they don't fall back to Material defaults.
class UgamTheme {
  const UgamTheme._();

  static ThemeData dark() => _build(UgamColors.dark, Brightness.dark);
  static ThemeData light() => _build(UgamColors.light, Brightness.light);

  static ThemeData _build(UgamColorSet c, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.accent,
        onPrimary: c.onAccent,
        secondary: c.good,
        onSecondary: c.onAccent,
        tertiary: c.warm,
        onTertiary: c.onAccent,
        error: c.danger,
        onError: c.onAccent,
        surface: c.card,
        onSurface: c.ink,
        surfaceContainerHighest: c.cardElev,
        outline: c.border,
      ),
      scaffoldBackgroundColor: c.bg,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        centerTitle: false,
        iconTheme: IconThemeData(color: c.ink),
        titleTextStyle: UgamText.titleM.copyWith(color: c.ink),
      ),
      textTheme: TextTheme(
        displayLarge: UgamText.display.copyWith(color: c.ink),
        displayMedium: UgamText.titleXl.copyWith(color: c.ink),
        headlineLarge: UgamText.titleXl.copyWith(color: c.ink),
        headlineMedium: UgamText.titleL.copyWith(color: c.ink),
        headlineSmall: UgamText.titleM.copyWith(color: c.ink),
        titleLarge: UgamText.titleM.copyWith(color: c.ink),
        titleMedium: UgamText.titleS.copyWith(color: c.ink),
        titleSmall: UgamText.bodyStrong.copyWith(color: c.ink2),
        bodyLarge: UgamText.body.copyWith(color: c.ink),
        bodyMedium: UgamText.body.copyWith(color: c.ink2),
        bodySmall: UgamText.caption.copyWith(color: c.ink3),
        labelLarge: UgamText.bodyStrong.copyWith(color: c.onAccent),
        labelMedium: UgamText.caption.copyWith(color: c.ink2),
        labelSmall: UgamText.micro.copyWith(color: c.ink3),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.onAccent,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding:
              const EdgeInsets.symmetric(horizontal: UgamSpacing.xxl, vertical: UgamSpacing.lg),
          shape: const StadiumBorder(),
          textStyle: UgamText.titleS.copyWith(color: c.onAccent),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.accent,
          side: BorderSide(color: c.accent, width: 1.5),
          padding:
              const EdgeInsets.symmetric(horizontal: UgamSpacing.xl, vertical: UgamSpacing.md + 2),
          shape: const StadiumBorder(),
          textStyle: UgamText.bodyStrong.copyWith(color: c.accent),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: UgamText.bodyStrong.copyWith(color: c.accent),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.cardElev,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.gutter,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          borderSide: BorderSide(color: c.danger, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          borderSide: BorderSide(color: c.danger, width: 2),
        ),
        hintStyle: UgamText.body.copyWith(color: c.ink3),
        labelStyle: UgamText.micro.copyWith(color: c.ink2),
        errorStyle: UgamText.caption.copyWith(color: c.danger),
      ),
      cardTheme: CardThemeData(
        color: c.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.cardElev,
        selectedColor: c.accentFill,
        labelStyle: UgamText.caption.copyWith(color: c.ink),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.sm,
        ),
        shape: const StadiumBorder(),
        side: BorderSide(color: c.border),
      ),
      dividerTheme: DividerThemeData(
        color: c.border,
        thickness: 1,
        space: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        elevation: 0,
        shape: const CircleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.onAccent : c.ink3),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.accent : c.cardElev),
        trackOutlineColor:
            WidgetStateProperty.resolveWith((_) => Colors.transparent),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.card,
        contentTextStyle: UgamText.body.copyWith(color: c.ink),
        actionTextColor: c.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.cardElev,
      ),
      iconTheme: IconThemeData(color: c.ink),
    );
  }
}
