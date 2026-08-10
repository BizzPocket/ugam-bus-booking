import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_info.dart';
import '../config/remote_flags_config.dart';
import 'timeout_http_client.dart';

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

/// One conditional-GET outcome.
///
/// [notModified] is the interesting state: the server confirmed the cached copy
/// is current and sent no body. Distinct from a failure (also no body) — one
/// means "you are up to date", the other means "keep what you have and try
/// later", and only the first should be treated as success.
@immutable
class _FetchResult {
  final String? body;
  final String? etag;
  final bool notModified;

  const _FetchResult({this.body, this.etag, this.notModified = false});
}

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
  static const String _etagKey = 'remote_flags.etag';
  static const String _fetchedAtKey = 'remote_flags.fetched_at';

  /// Don't go to the network more than this often.
  ///
  /// On a 2G link the ROUND TRIP dominates, not the payload — the flag document
  /// is a few hundred bytes. A conditional request saves the body; only not
  /// making the request saves the latency. Foregrounding the app repeatedly
  /// must not mean repeatedly waiting on a socket.
  ///
  /// Short enough that a kill switch still lands within a quarter of an hour on
  /// an app in active use, and any cold start bypasses it anyway.
  static const Duration minFetchInterval = Duration(minutes: 15);

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
        _applyTunables();
      }
    } catch (e) {
      debugPrint('[flags] cache ignored: $e');
    }
  }

  /// Pushes tunables into the subsystems that own them.
  ///
  /// Applied from the CACHE too, not just a fresh fetch — the cached value is
  /// the one in force during the cold start where a stuck request hurts most,
  /// and waiting for the network to learn how long to wait for the network is
  /// the wrong way round.
  void _applyTunables() {
    TimeoutHttpClient.applyRemoteTimeout(
      flags.value.tunables['http_timeout_seconds'],
    );
  }

  /// [force] skips the [minFetchInterval] throttle. Cold start forces; a
  /// foreground resume does not.
  Future<void> _refresh({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!force && _fetcher == null) {
        final last = prefs.getInt(_fetchedAtKey);
        if (last != null) {
          final age = DateTime.now().millisecondsSinceEpoch - last;
          if (age >= 0 && age < minFetchInterval.inMilliseconds) {
            // Cheapest possible refresh: none at all.
            return;
          }
        }
      }

      final knownEtag = prefs.getString(_etagKey);
      final injected = _fetcher;
      final result = injected != null
          ? _FetchResult(body: await injected())
          : await _httpFetch(knownEtag);

      // Stamp the attempt even on a 304 or a no-op, so a healthy unchanged
      // document does not re-request every 15 minutes forever.
      await prefs.setInt(
        _fetchedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );

      // 304 Not Modified — the cached document is already correct, and no body
      // crossed the wire. This is the common case and the reason for the ETag.
      if (result.notModified) return;

      final body = result.body;
      if (body == null || body.isEmpty) return;

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;

      flags.value = RemoteFlags.fromJson(decoded);
      _applyTunables();
      await prefs.setString(_cacheKey, body);
      if (result.etag != null && result.etag!.isNotEmpty) {
        await prefs.setString(_etagKey, result.etag!);
      }
    } catch (e) {
      // Offline, DNS failure, timeout, bad JSON — keep last-known-good.
      debugPrint('[flags] refresh failed: $e');
    } finally {
      settled.value = true;
    }
  }

  static Future<_FetchResult> _httpFetch(String? knownEtag) async {
    if (!RemoteFlagsConfig.enabled) return const _FetchResult();
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = RemoteFlagsConfig.fetchTimeout;
      final request = await client
          .getUrl(Uri.parse(RemoteFlagsConfig.url))
          .timeout(RemoteFlagsConfig.fetchTimeout);

      // Conditional GET. Supabase Storage is S3-backed and serves an ETag; an
      // unchanged document comes back as a bodyless 304. If the host ever stops
      // sending one, knownEtag stays null and this degrades to a plain GET —
      // exactly today's behaviour, never a failure.
      if (knownEtag != null && knownEtag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, knownEtag);
      }

      final response =
          await request.close().timeout(RemoteFlagsConfig.fetchTimeout);

      if (response.statusCode == HttpStatus.notModified) {
        return const _FetchResult(notModified: true);
      }
      if (response.statusCode != HttpStatus.ok) return const _FetchResult();
      if (response.contentLength > RemoteFlagsConfig.maxBytes) {
        return const _FetchResult();
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(RemoteFlagsConfig.fetchTimeout);
      if (body.length > RemoteFlagsConfig.maxBytes) return const _FetchResult();

      return _FetchResult(
        body: body,
        etag: response.headers.value(HttpHeaders.etagHeader),
      );
    } finally {
      client?.close(force: true);
    }
  }

  /// Force a check now, ignoring [minFetchInterval]. For a pull-to-refresh or
  /// an explicit "check for updates" affordance.
  Future<void> refreshNow() => _refresh(force: true);

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
