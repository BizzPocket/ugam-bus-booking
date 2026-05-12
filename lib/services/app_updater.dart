import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// GitHub repo coordinates. Public so anonymous device installs can pull
/// `latest.json` and the APK without an auth token.
const _kReleaseOwner = 'BizzPocket';
const _kReleaseRepo  = 'ugam-bus-booking';

/// The release workflow uploads `latest.json` to every release. We hit the
/// `/releases/latest/download/<asset>` shortcut so the URL never has to
/// know which tag is current — GitHub follows the redirect for us.
const _kLatestManifestUrl =
    'https://github.com/$_kReleaseOwner/$_kReleaseRepo/releases/latest/download/latest.json';

class UpdateInfo {
  final String tag;        // e.g. v1.0.1
  final String version;    // e.g. 1.0.1 (semver-ish)
  final String apkUrl;
  final String? releaseNotes;
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.apkUrl,
    this.releaseNotes,
  });
}

/// One-shot helper that checks GitHub Releases, compares against the
/// installed build, downloads the APK to the app cache, and hands it to
/// the Android package installer. Android-only; iOS is a no-op.
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  bool _checkInFlight = false;

  /// Returns an [UpdateInfo] when a strictly-newer version is published.
  /// Returns `null` when the device is on the latest version or when
  /// anything in the lookup fails — auto-update should never block the
  /// app from starting.
  Future<UpdateInfo?> checkForUpdate() async {
    if (!Platform.isAndroid) return null;
    if (_checkInFlight) return null;
    _checkInFlight = true;
    try {
      final pkg = await PackageInfo.fromPlatform();
      final currentVersion = pkg.version;

      final res = await http
          .get(Uri.parse(_kLatestManifestUrl))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (json['tag'] as String?) ?? '';
      final version = (json['version'] as String?) ?? '';
      final apkUrl = (json['apk_url'] as String?) ?? '';
      if (version.isEmpty || apkUrl.isEmpty) return null;
      if (!_isNewer(version, currentVersion)) return null;

      return UpdateInfo(
        tag: tag,
        version: version,
        apkUrl: apkUrl,
        releaseNotes: json['notes'] as String?,
      );
    } catch (e, st) {
      debugPrint('AppUpdater.checkForUpdate failed: $e\n$st');
      return null;
    } finally {
      _checkInFlight = false;
    }
  }

  /// Downloads the APK and opens it. Android's package installer takes
  /// over from there — the user confirms, the new APK replaces the old
  /// one, the app relaunches.
  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) return;

    final ok = await _ensureInstallPermission();
    if (!ok) {
      throw const _UpdateException(
        'Install-from-unknown-sources permission was denied.',
      );
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ugam-bus-booking-${info.version}.apk');
    if (await file.exists()) {
      try { await file.delete(); } catch (_) {}
    }

    final req = http.Request('GET', Uri.parse(info.apkUrl));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    if (streamed.statusCode != 200) {
      throw _UpdateException(
        'Download failed: HTTP ${streamed.statusCode}',
      );
    }
    final total = streamed.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    await for (final chunk in streamed.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (onProgress != null && total > 0) {
        onProgress(received / total);
      }
    }
    await sink.flush();
    await sink.close();

    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      throw _UpdateException(
        'Could not launch installer: ${result.message}',
      );
    }
  }

  Future<bool> _ensureInstallPermission() async {
    // Android 8+: per-app "install unknown apps" toggle.
    final status = await Permission.requestInstallPackages.status;
    if (status.isGranted) return true;
    final asked = await Permission.requestInstallPackages.request();
    return asked.isGranted;
  }

  /// Returns true iff [remote] > [local] under dotted-numeric comparison
  /// (e.g. "1.2.10" > "1.2.9"). Falls back to string compare if either
  /// side has a non-numeric segment.
  bool _isNewer(String remote, String local) {
    final r = remote.split('.');
    final l = local.split('.');
    final len = r.length > l.length ? r.length : l.length;
    for (var i = 0; i < len; i++) {
      final ri = int.tryParse(i < r.length ? r[i] : '0');
      final li = int.tryParse(i < l.length ? l[i] : '0');
      if (ri == null || li == null) return remote.compareTo(local) > 0;
      if (ri > li) return true;
      if (ri < li) return false;
    }
    return false;
  }
}

class _UpdateException implements Exception {
  final String message;
  const _UpdateException(this.message);
  @override
  String toString() => message;
}
