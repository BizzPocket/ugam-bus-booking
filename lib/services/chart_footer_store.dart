import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chart_footer.dart';

/// Persists the editable [ChartFooter] per tour in `shared_preferences`.
///
/// Key: `chart_footer_<tourId>`, value: JSON-encoded [ChartFooter]. No DB or
/// schema change — mirrors the SharedPreferences access pattern used by
/// `ThemeController`.
class ChartFooterStore {
  static String _keyFor(String tourId) => 'chart_footer_$tourId';

  /// Loads the saved footer for [tourId], or an empty [ChartFooter] if none
  /// exists (or the stored value is unparseable).
  static Future<ChartFooter> load(String tourId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_keyFor(tourId));
    if (stored == null || stored.isEmpty) {
      return const ChartFooter();
    }
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      return ChartFooter.fromJson(decoded);
    } catch (_) {
      return const ChartFooter();
    }
  }

  /// Saves [footer] for [tourId] as a JSON-encoded string.
  static Future<void> save(String tourId, ChartFooter footer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(tourId), jsonEncode(footer.toJson()));
  }
}
