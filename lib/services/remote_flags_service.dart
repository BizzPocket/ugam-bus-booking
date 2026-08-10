import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_info.dart';
import '../config/remote_flags_config.dart';

/// What the launch gate has decided for this session.
enum LaunchDecision {
  /// Normal operation. This is the answer whenever anything is uncertain.
  proceed,

  /// A newer build exists and is worth taking, but this one still works.
  updateRecommended,

  /// This build is below the supported floor and must not continue.
  updateRequired,

  /// The backend is deliberately down.
  maintenance,
}

/// The remote flag document, with fail-open defaults compiled in.
///
/// Every default is the "nothing is wrong" value, so an absent, unreachable or
/// unparseable document leaves the app behaving exactly as it does today.
@immutable
class RemoteFlags {
  /// Builds strictly below this are blocked. 0 blocks nobody.
  final int minSupportedBuild;

  /// Builds strictly below this get a dismissible nudge. 0 nudges nobody.
  final int recommendedBuild;

  final bool maintenanceMode;

  /// Feature kill switches, read by name. Absent means "on".
  final Map<String, bool> kill;

  /// Numeric knobs (timeouts, page sizes, hold TTL) read by name.
  final Map<String, num> tunables;

  const RemoteFlags({
    this.minSupportedBuild = 0,
    this.recommendedBuild = 0,
    this.maintenanceMode = false,
    this.kill = const {},
    this.tunables = const {},
  });

  /// The state the app runs in when it has never successfully fetched.
  static const RemoteFlags defaults = RemoteFlags();

  /// Tolerant by design: an unknown key is ignored, a wrong-typed value falls
  /// back to its default rather than throwing. A malformed document must never
  /// be able to brick a client.
  factory RemoteFlags.fromJson(Map<String, dynamic> json) {
    int asInt(String key) {
      final v = json[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    Map<String, T> typedMap<T>(String key) {
      final raw = json[key];
      if (raw is! Map) return const {};
      final out = <String, T>{};
      raw.forEach((k, v) {
        if (v is T) out['$k'] = v;
      });
      return out;
    }

    return RemoteFlags(
      minSupportedBuild: asInt('min_supported_build'),
      recommendedBuild: asInt('recommended_build'),
      maintenanceMode: json['maintenance_mode'] == true,
      kill: typedMap<bool>('kill'),
      tunables: typedMap<num>('tunables'),
    );
  }
}

/// Fetches the flag document. Swappable so tests can drive the service without
/// a network, and so a different backend can be adopted without touching the
/// gate.
typedef FlagsFetcher = Future<String?> Function();

/// Holds the current [RemoteFlags] and answers the one question the UI asks:
/// may this launch proceed?
///
/// THE RULES THIS OBEYS
///  1. Fail open, always. Timeout, parse failure, empty cache, unreadable build
///     number — every one of them resolves to [LaunchDecision.proceed]. A
///     misconfigured flag server must not be able to brick the app.
///  2. Nothing on the boot path awaits this. [warm] is fire-and-forget with its
///     own timeout; the decision is read later from cached-or-default state.
///     The bootstrap Future.wait in main.dart has no timeout of its own, so a
///     network future placed there would hang the splash forever on a 2G link.
///  3. The cache is last-known-good. A fetch that fails leaves the previous
///     document in place rather than reverting to defaults.
class RemoteFlagsService extends GetxService {
  static const String _cacheKey = 'remote_flags.doc';

  final FlagsFetcher? _fetcher;

  RemoteFlagsService({FlagsFetcher? fetcher}) : _fetcher = fetcher;

  final Rx<RemoteFlags> flags = const RemoteFlags().obs;

  /// True once warm() has finished, successfully or not. The gate does not wait
  /// on it — this exists so the UI can avoid flashing a nudge that a
  /// half-loaded document would have suppressed.
  final RxBool settled = false.obs;

  bool isKilled(String feature) => flags.value.kill[feature] == true;

  num? tunable(String name) => flags.value.tunables[name];

  /// Loads the cached document, then refreshes in the background.
  ///
  /// Awaiting this is safe — it performs no network I/O itself — but the
  /// refresh it kicks off is deliberately not awaited.
  Future<void> warm() async {
    await _loadCache();
    if (RemoteFlagsConfig.enabled || _fetcher != null) {
      // Explicitly not awaited: the boot path must never depend on it.
      unawaited(_refresh());
    } else {
      settled.value = true;
    }
  }

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        flags.value = RemoteFlags.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('[flags] cache ignored: $e');
    }
  }

  Future<void> _refresh() async {
    try {
      final body = await (_fetcher ?? _httpFetch)();
      if (body == null || body.isEmpty) return;

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;

      flags.value = RemoteFlags.fromJson(decoded);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, body);
    } catch (e) {
      // Offline, DNS failure, timeout, bad JSON — keep last-known-good.
      debugPrint('[flags] refresh failed: $e');
    } finally {
      settled.value = true;
    }
  }

  static Future<String?> _httpFetch() async {
    if (!RemoteFlagsConfig.enabled) return null;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = RemoteFlagsConfig.fetchTimeout;
      final request = await client
          .getUrl(Uri.parse(RemoteFlagsConfig.url))
          .timeout(RemoteFlagsConfig.fetchTimeout);
      final response =
          await request.close().timeout(RemoteFlagsConfig.fetchTimeout);
      if (response.statusCode != HttpStatus.ok) return null;
      if (response.contentLength > RemoteFlagsConfig.maxBytes) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(RemoteFlagsConfig.fetchTimeout);
      return body.length > RemoteFlagsConfig.maxBytes ? null : body;
    } finally {
      client?.close(force: true);
    }
  }

  /// The launch decision for [buildNumber], defaulting to this build.
  ///
  /// Maintenance outranks the version gate: if the backend is down, telling the
  /// user to update would send them to a store for a build that also cannot
  /// work.
  LaunchDecision decide({String? buildNumber}) {
    final f = flags.value;
    if (f.maintenanceMode) return LaunchDecision.maintenance;

    // AppInfo.load() swallows PackageInfo failures and leaves an empty string.
    // An unreadable identity must never block — fail open.
    final raw = buildNumber ?? AppInfo.buildNumber;
    final build = int.tryParse(raw.trim());
    if (build == null) return LaunchDecision.proceed;

    if (f.minSupportedBuild > 0 && build < f.minSupportedBuild) {
      return LaunchDecision.updateRequired;
    }
    if (f.recommendedBuild > 0 && build < f.recommendedBuild) {
      return LaunchDecision.updateRecommended;
    }
    return LaunchDecision.proceed;
  }
}
