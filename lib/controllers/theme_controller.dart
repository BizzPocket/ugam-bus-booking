import 'package:get/get.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theme controller. Persists a tri-state `themeMode` (light / dark /
/// system) and a legacy `isDarkMode` boolean so existing screens that
/// still listen to the boolean keep working until their phase migrates
/// them.
///
/// Dark is the default for fresh installs (Phase 0 design system flip).
/// Existing users keep whatever they had previously selected.
class ThemeController extends GetxController {
  // Legacy boolean — true == dark. Kept for back-compat with old call
  // sites. New code should read `themeMode` directly.
  final isDarkMode = true.obs;

  // New tri-state. UI binds to this; the `isDarkMode` flag below
  // tracks the resolved value so existing observers still update.
  final themeMode = ThemeMode.dark.obs;

  static const _legacyKey = 'isDarkMode';
  static const _modeKey = 'themeMode';

  @override
  void onInit() {
    super.onInit();
    _loadPreference();
  }

  /// Toggle between light and dark explicitly (skips System). Kept for
  /// the old call site in `settings_screen.dart` — new code should use
  /// `setMode(ThemeMode)` instead.
  void toggleTheme() {
    setMode(isDarkMode.value ? ThemeMode.light : ThemeMode.dark);
  }

  void setMode(ThemeMode mode) {
    themeMode.value = mode;
    isDarkMode.value = _resolveIsDark(mode);
    Get.changeThemeMode(mode);
    _savePreference();
  }

  bool _resolveIsDark(ThemeMode mode) {
    if (mode == ThemeMode.dark) return true;
    if (mode == ThemeMode.light) return false;
    // System — use platform brightness as a best-effort. UI that reads
    // `isDarkMode` directly may be wrong if the system flips at
    // runtime; new screens should observe MediaQuery instead.
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    return brightness == Brightness.dark;
  }

  Future<void> _savePreference() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, themeMode.value.name);
    await prefs.setBool(_legacyKey, isDarkMode.value);
  }

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_modeKey);

    if (stored != null) {
      final mode = ThemeMode.values.firstWhere(
        (m) => m.name == stored,
        orElse: () => ThemeMode.dark,
      );
      setMode(mode);
      return;
    }

    // No tri-state pref yet — fall back to the legacy boolean. If it
    // exists, honour it; otherwise default to dark (new design language).
    final legacy = prefs.getBool(_legacyKey);
    final initial =
        legacy == null ? ThemeMode.dark : (legacy ? ThemeMode.dark : ThemeMode.light);
    setMode(initial);
  }
}
