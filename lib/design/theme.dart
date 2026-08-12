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

  /// Material's own depth API is a single `elevation` double feeding a preset
  /// shadow, so a stock [Card], [FloatingActionButton] or [BottomSheet] cannot
  /// literally consume an [UgamElevationSet]'s `BoxShadow` list. What it CAN do
  /// is sit at the same LEVEL as the Ugam component beside it — which is the
  /// whole point, because a screen that mixes the two must not show them at two
  /// different heights.
  ///
  /// * [_restDp] ≈ [UgamElevationSet.rest] — a surface at rest, what
  ///   [UgamCard] paints.
  /// * [_raisedDp] ≈ [UgamElevationSet.raised] — something floating over the
  ///   page, what `UgamSheet` / `UgamDialog` / the dock paint.
  ///
  /// These are the Material 3 level-1 and level-2 dp values, so the framework's
  /// own shadow geometry lands where the token scale does.
  static const double _restDp = 1;
  static const double _raisedDp = 3;

  static ThemeData _build(UgamColorSet c, Brightness brightness) {
    final e = brightness == Brightness.dark
        ? UgamElevation.dark
        : UgamElevation.light;

    // The TINT comes from the scale — a stock Card's shade has to be the same
    // warm near-black as an UgamCard's, or Daylight ends up with two different
    // coloured shadows on one screen — but it is handed over at FULL alpha.
    // Skia multiplies the shadow colour's alpha by its own ambient/spot factors
    // (0.039 / 0.25) before painting, so passing the token's own 10% would
    // render a shadow at ~2.5% and Material would still look flat.
    final shadowColor = e.rest.last.color.withValues(alpha: 1);

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
      // Every Material widget that paints its own shadow reads this when
      // useMaterial3 is on ([RawMaterialButton], and therefore the FAB, take it
      // straight off the theme). Setting it once here is what keeps a stock
      // popup menu or dropdown from casting a cold grey shadow next to an
      // UgamCard's warm one.
      shadowColor: shadowColor,
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
      // NO `fontFamilyFallback` wiring here, on purpose — it is already
      // present and re-stating it would be dead code. Every slot below is an
      // `UgamText` step, each of which carries `UgamText.indicFallback`, and
      // `copyWith(color:)` preserves it. That covers the whole app: a bare
      // `Text` reads `textTheme.bodyMedium` through `DefaultTextStyle`, and a
      // hand-rolled `TextStyle(...)` at a call site is `inherit: true`, so
      // `TextStyle.merge` fills its null `fontFamilyFallback` from that same
      // inherited style. The only slots NOT carrying it are the ones this
      // TextTheme leaves null (`displaySmall`), which `ThemeData.localize`
      // fills from the Typography geometry — nothing in the app reads them.
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
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.xxl,
            vertical: UgamSpacing.lg,
          ),
          shape: const StadiumBorder(),
          textStyle: UgamText.titleS.copyWith(color: c.onAccent),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.accent,
          side: BorderSide(color: c.accent, width: 1.5),
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.xl,
            vertical: UgamSpacing.md + 2,
          ),
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
        // A stock [Card] is a card. It was pinned at 0 while [UgamCard] moved
        // to level 1, so the handful of screens still using the Material widget
        // read as holes in an otherwise lifted app.
        elevation: _restDp,
        shadowColor: shadowColor,
        // M3 composites `surfaceTint` (= colorScheme.surfaceTint = the amber
        // accent) over the fill in proportion to elevation, so the moment the
        // line above stopped being 0 every stock Card would have picked up a
        // copper wash. Depth here is shadow + the tonal `card` token, never a
        // hue shift — that is the whole basis of [UgamColors.dark].
        surfaceTintColor: Colors.transparent,
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
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 0),
      bottomSheetTheme: BottomSheetThemeData(
        // `UgamSheet` passes the scrim per-call, but plenty of sheets are shown
        // straight through `showModalBottomSheet` (and the framework shows its
        // own — date pickers, the Material text-selection menus). Without this
        // they inherit Material's 32% barrier, at which the page behind stays
        // bright and fully legible and the sheet reads as one more card instead
        // of a layer above everything. This is the same 55%/60% [UgamElevation]
        // hands `UgamSheet`, so both routes agree.
        modalBarrierColor: e.scrim,
        // NO `shadowColor`/`elevation` here, deliberately. M3 already defaults
        // a sheet's shadowColor to transparent, so the framework paints none
        // and `_SheetShell` owns the level-2 cast with its own `raised`
        // boxShadow. Switching the framework's shadow on would paint a SECOND
        // one behind every `UgamSheet` — the shell is presented on a
        // transparent BottomSheet Material, so that shadow would not be
        // occluded, it would fringe out around the shell. On Midnight that is
        // precisely the pooled smudge [UgamElevation] was cut back to remove.
        //
        // The surface tokens below are the part worth centralising: without
        // them a sheet that skips `UgamSheet` lands on M3's
        // `surfaceContainerLow`, a tone this ColorScheme never defines, and a
        // 28 px corner instead of [UgamRadius.sheet].
        backgroundColor: c.card,
        modalBackgroundColor: c.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(UgamRadius.sheet),
          ),
        ),
      ),
      // `UgamDialog` sets its own barrier from the same token; this covers the
      // raw `showDialog` / `showDatePicker` call sites that never went through
      // it, so no dialog in the app is left on Material's `black54`.
      dialogTheme: DialogThemeData(
        barrierColor: e.scrim,
        backgroundColor: c.card,
        elevation: _raisedDp,
        shadowColor: shadowColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        // A FAB is by definition *floating*: it sits over scrolling content and
        // never moves out of the way, which is the level-2 contract the dock
        // and the sheets already use. At 0 it was a flat amber disc pasted on
        // the page. The colour comes from the theme's `shadowColor` above —
        // [FloatingActionButtonThemeData] has no shadowColor of its own, and
        // RawMaterialButton reads [ThemeData.shadowColor] under M3.
        elevation: _raisedDp,
        // Pressed/hover states track the resting level rather than jumping to
        // Material's stock 12/8 dp, which would out-elevate every sheet.
        highlightElevation: _raisedDp,
        focusElevation: _raisedDp,
        hoverElevation: _raisedDp,
        shape: const CircleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onAccent : c.ink3,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.cardElev,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (_) => Colors.transparent,
        ),
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
      // INTERIM. Three screens still call the raw Material `showTimePicker`
      // (`add_bus_screen.dart`, `create_tour_screen.dart`,
      // `edit_tour_screen.dart`), which without this theme renders in stock
      // Material purple on a stock surface. Theming it here fixes all three at
      // once; a shared `UgamSheet`-based picker is the real fix and is
      // deliberately deferred (it is a 3-call-site behavioural change).
      //
      // The dial hand is the one solid accent here: it is the selection
      // indicator on a modal surface, not a screen-level CTA, so the
      // accent-rationing law does not apply.
      timePickerTheme: TimePickerThemeData(
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.sheet),
        ),
        helpTextStyle: UgamText.micro.copyWith(color: c.ink2),
        dialBackgroundColor: c.cardElev,
        dialHandColor: c.accent,
        dialTextColor: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onAccent : c.ink,
        ),
        dialTextStyle: UgamText.body.copyWith(color: c.ink),
        hourMinuteColor: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accentFill : c.cardElev,
        ),
        hourMinuteTextColor: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.ink,
        ),
        hourMinuteTextStyle: UgamText.titleXl.copyWith(color: c.ink),
        hourMinuteShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        dayPeriodColor: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accentFill : c.cardElev,
        ),
        dayPeriodTextColor: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.ink2,
        ),
        dayPeriodTextStyle: UgamText.bodyStrong.copyWith(color: c.ink),
        dayPeriodBorderSide: BorderSide(color: c.border),
        dayPeriodShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          side: BorderSide(color: c.border),
        ),
        entryModeIconColor: c.ink2,
        padding: const EdgeInsets.all(UgamSpacing.xl),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.cardElev,
      ),
      iconTheme: IconThemeData(color: c.ink),
    );
  }
}
