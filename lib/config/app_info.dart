import 'package:package_info_plus/package_info_plus.dart';

/// Holds the app's marketing version, read once from the platform bundle at
/// boot so the settings + customer "more" footers always reflect the real
/// pubspec version instead of a hand-maintained constant that drifts.
class AppInfo {
  AppInfo._();

  /// Marketing version (e.g. `1.0.16`). Empty until [load] completes; by the
  /// time any screen renders, bootstrap has already awaited [load].
  static String version = '';

  /// Build number (e.g. `19`).
  static String buildNumber = '';

  /// Reads the version from the platform package metadata. Best-effort: if it
  /// throws (unlikely), the footer simply shows an empty version rather than
  /// crashing boot.
  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
    } catch (_) {
      // Leave defaults; the footer degrades gracefully.
    }
  }
}
