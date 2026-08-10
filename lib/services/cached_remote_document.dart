import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One small JSON document fetched over plain HTTPS, cached, and refreshed
/// frugally.
///
/// Extracted because this is the third thing in the app that needs exactly the
/// same discipline — the flag document, the translation deltas, and now the
/// content blocks — and three subtly different copies of conditional-GET plus
/// throttling plus last-known-good is how one of them quietly stops working.
///
/// (`RemoteFlagsService` and `TranslationOverlaySync` predate this and still
/// carry their own copies. They are tested and working, so they are left alone
/// for now rather than refactored under a deadline; new callers use this.)
///
/// THE DISCIPLINE, which is the whole point:
///
///   - **Never on the boot path.** [load] reads only the cache and is
///     synchronous-ish; [refresh] does the network and nothing awaits it.
///   - **Conditional GET.** An unchanged document returns a bodyless 304. On a
///     2G link the round trip dominates, so this saves the payload, not the
///     latency.
///   - **A minimum interval.** Which does save the latency, by not making the
///     request at all. Cold start bypasses it.
///   - **Last-known-good.** A failed refresh keeps the previous copy. Offline
///     is not a reason to lose content that already arrived.
///   - **It cannot throw.** Every path returns rather than propagating. A
///     content document is never worth an exception.
class CachedRemoteDocument {
  CachedRemoteDocument({
    required this.name,
    required this.url,
    this.maxBytes = 64 * 1024,
    this.timeout = const Duration(seconds: 5),
    this.minFetchInterval = const Duration(minutes: 15),
    Future<String?> Function(String? knownEtag)? fetcher,
  }) : _injectedFetcher = fetcher;

  /// Cache namespace. Must be stable — changing it orphans the cache.
  final String name;

  /// Empty means dormant: no network call is ever made and [load] returns the
  /// cache only (which will also be empty on a fresh install).
  final String url;

  final int maxBytes;
  final Duration timeout;
  final Duration minFetchInterval;

  final Future<String?> Function(String? knownEtag)? _injectedFetcher;

  bool get enabled => url.isNotEmpty || _injectedFetcher != null;

  String get _bodyKey => 'remotedoc.$name.body';
  String get _etagKey => 'remotedoc.$name.etag';
  String get _atKey => 'remotedoc.$name.fetched_at';

  /// The cached document, decoded. Null when nothing has ever been cached or
  /// the cache is unreadable. Performs no network I/O.
  Future<Object?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_bodyKey);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw);
    } catch (e) {
      debugPrint('[$name] cache unreadable, ignoring: $e');
      return null;
    }
  }

  /// Fetches if the interval has elapsed. Returns the decoded document when it
  /// CHANGED, null otherwise — including on 304, throttle, and every failure.
  ///
  /// Deliberately not awaited by callers on a UI path.
  Future<Object?> refresh({bool force = false}) async {
    if (!enabled) return null;
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!force) {
        final last = prefs.getInt(_atKey);
        if (last != null) {
          final age = DateTime.now().millisecondsSinceEpoch - last;
          if (age >= 0 && age < minFetchInterval.inMilliseconds) return null;
        }
      }

      final knownEtag = prefs.getString(_etagKey);
      final fetcher = _injectedFetcher;
      final result =
          fetcher != null ? _Fetched(body: await fetcher(knownEtag)) : await _http(knownEtag);

      // Stamp even on 304 and on failure, so a healthy unchanged document does
      // not re-request every interval forever.
      await prefs.setInt(_atKey, DateTime.now().millisecondsSinceEpoch);

      if (result.notModified) return null;
      final body = result.body;
      if (body == null || body.isEmpty) return null;

      final decoded = jsonDecode(body);
      await prefs.setString(_bodyKey, body);
      if (result.etag != null && result.etag!.isNotEmpty) {
        await prefs.setString(_etagKey, result.etag!);
      }
      return decoded;
    } catch (e) {
      debugPrint('[$name] refresh failed, keeping last known good: $e');
      return null;
    }
  }

  /// Drops the cache. The manual escape hatch if a bad document ever ships.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_bodyKey);
      await prefs.remove(_etagKey);
      await prefs.remove(_atKey);
    } catch (_) {
      // Nothing sensible to do; the old copy simply stays.
    }
  }

  Future<_Fetched> _http(String? knownEtag) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      if (knownEtag != null && knownEtag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, knownEtag);
      }
      final response = await request.close().timeout(timeout);

      if (response.statusCode == HttpStatus.notModified) {
        return const _Fetched(notModified: true);
      }
      if (response.statusCode != HttpStatus.ok) return const _Fetched();
      if (response.contentLength > maxBytes) {
        debugPrint('[$name] document too large, refused');
        return const _Fetched();
      }

      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (body.length > maxBytes) return const _Fetched();

      return _Fetched(
        body: body,
        etag: response.headers.value(HttpHeaders.etagHeader),
      );
    } finally {
      client?.close(force: true);
    }
  }
}

@immutable
class _Fetched {
  final String? body;
  final String? etag;
  final bool notModified;
  const _Fetched({this.body, this.etag, this.notModified = false});
}
