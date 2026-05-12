import 'package:flutter/material.dart';

/// Centralises i18n constants so screens and the locale picker share one
/// source of truth.
class I18nConfig {
  /// Asset folder that easy_localization scans for `<code>.json` files.
  static const String assetPath = 'assets/translations';

  /// Languages the app ships with, in display order.
  static const List<Locale> supportedLocales = [
    Locale('gu'), // Gujarati — primary
    Locale('en'), // English
    Locale('hi'), // Hindi
  ];

  /// Fallback locale used when the device locale is not in [supportedLocales].
  static const Locale fallbackLocale = Locale('gu');

  /// Human-readable label for a locale (used in the language picker).
  /// Each label is written in its own script so users can find their language
  /// even when the app is currently displaying a different one.
  static String labelFor(Locale locale) {
    switch (locale.languageCode) {
      case 'gu':
        return 'ગુજરાતી';
      case 'hi':
        return 'हिंदी';
      case 'en':
        return 'English';
      default:
        return locale.languageCode;
    }
  }

  I18nConfig._();
}
