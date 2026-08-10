import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/translation_overlay_config.dart';

/// Loads the bundled translation catalogue and merges a cached remote *delta*
/// over the top of it.
///
/// WHY THIS EXISTS
/// Roughly a fifth of this repo's commit history is blocked by nothing but
/// `assets/translations/{en,gu,hi}.json`. A bundled asset cannot be changed
/// without a store release on either platform — and no code-push mechanism can
/// carry assets either. Copy is data, not code, so fetching it at runtime sits
/// outside App Store Guideline 2.5.2 entirely and needs no policy argument.
///
/// THE RULES THIS OBEYS
///  1. The bundled catalogue is the floor and is never removed from
///     `pubspec.yaml`. A first install with no network shows real copy, not
///     raw keys.
///  2. [load] never touches the network and never throws. It reads the bundle
///     plus a cache that a previous run wrote. A corrupt or absent cache
///     degrades silently to the bundled catalogue.
///  3. The network refresh ([TranslationOverlaySync.refresh]) runs after first
///     paint and only affects the NEXT launch. Nothing about startup waits on
///     it.
///
/// Point 2 is the important one: EasyLocalization renders
/// `errorWidget ?? ErrorWidget(...)` when a loader throws, and this app
/// globally redefines `ErrorWidget.builder` as a red diagnostic dump. A loader
/// that could throw would turn a CDN blip into a full-screen crash-looking page
/// for the entire user base.
class RemoteTranslationLoader extends AssetLoader {
  /// Overrides [TranslationOverlayConfig.enabled]. Tests set this so the
  /// cache-and-merge path is exercised without a configured base URL —
  /// otherwise the dormant short-circuit below would make those tests pass
  /// without touching the code they claim to cover.
  final bool? enabledOverride;

  const RemoteTranslationLoader({this.enabledOverride});

  bool get _enabled => enabledOverride ?? TranslationOverlayConfig.enabled;

  static String cacheKey(String langCode) => 'i18n.overlay.$langCode';
  static String etagKey(String langCode) => 'i18n.overlay.etag.$langCode';

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final bundled = await _loadBundled(path, locale);

    if (!_enabled) return bundled;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey(locale.languageCode));
      if (raw == null || raw.isEmpty) return bundled;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return bundled;

      return deepMerge(bundled, decoded);
    } catch (e) {
      // A bad cache must never cost the user their app. Drop the overlay and
      // carry on with what shipped in the binary.
      debugPrint('[i18n] overlay ignored for ${locale.languageCode}: $e');
      return bundled;
    }
  }

  /// The catalogue compiled into the binary. If this fails the app genuinely
  /// has no copy for the locale, so the error is allowed to surface exactly as
  /// it did before this loader existed.
  Future<Map<String, dynamic>> _loadBundled(String path, Locale locale) async {
    final raw = await rootBundle.loadString('$path/${locale.languageCode}.json');
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Recursive merge of [overlay] onto [base].
  ///
  /// Nested maps merge key-by-key so a delta can override a single leaf —
  /// `{"booking_form": {"label_name": "..."}}` replaces just that string and
  /// leaves the rest of `booking_form` untouched. Any non-map value in the
  /// overlay wins outright. Keys absent from the overlay are untouched.
  @visibleForTesting
  static Map<String, dynamic> deepMerge(
    Map<String, dynamic> base,
    Map<String, dynamic> overlay,
  ) {
    final out = Map<String, dynamic>.from(base);
    overlay.forEach((key, value) {
      final existing = out[key];
      if (existing is Map<String, dynamic> && value is Map<String, dynamic>) {
        out[key] = deepMerge(existing, value);
      } else {
        out[key] = value;
      }
    });
    return out;
  }
}

/// Background refresh of the translation delta.
///
/// Deliberately NOT part of the loader: fetching during [AssetLoader.load]
/// would put a network call on the boot path, which is the one thing this
/// app's cold start cannot afford. Call [refresh] after first paint; whatever
/// it writes applies on the next launch.
class TranslationOverlaySync {
  const TranslationOverlaySync._();

  /// Fetches the delta for [langCode] and caches it. Returns true when the
  /// cache changed. Never throws — every failure path is a no-op.
  static Future<bool> refresh(String langCode) async {
    if (!TranslationOverlayConfig.enabled) return false;

    HttpClient? client;
    try {
      final uri = Uri.parse('${TranslationOverlayConfig.baseUrl}/$langCode.json');
      final prefs = await SharedPreferences.getInstance();
      final knownEtag = prefs.getString(RemoteTranslationLoader.etagKey(langCode));

      client = HttpClient()
        ..connectionTimeout = TranslationOverlayConfig.fetchTimeout;

      final request = await client
          .getUrl(uri)
          .timeout(TranslationOverlayConfig.fetchTimeout);
      if (knownEtag != null && knownEtag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, knownEtag);
      }

      final response =
          await request.close().timeout(TranslationOverlayConfig.fetchTimeout);

      // Unchanged since the last fetch — the cache is already correct.
      if (response.statusCode == HttpStatus.notModified) return false;
      if (response.statusCode != HttpStatus.ok) return false;

      // Refuse anything delta-shaped only in name. A full catalogue here means
      // the wrong file was uploaded, and caching it would defeat the point of
      // keeping the bundle as the floor.
      if (response.contentLength > TranslationOverlayConfig.maxBytes) {
        debugPrint('[i18n] overlay for $langCode too large, refused');
        return false;
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(TranslationOverlayConfig.fetchTimeout);

      if (body.length > TranslationOverlayConfig.maxBytes) return false;

      // Parse before caching: a cache is only worth writing if it will load.
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return false;

      await prefs.setString(RemoteTranslationLoader.cacheKey(langCode), body);
      final etag = response.headers.value(HttpHeaders.etagHeader);
      if (etag != null && etag.isNotEmpty) {
        await prefs.setString(RemoteTranslationLoader.etagKey(langCode), etag);
      }
      return true;
    } catch (e) {
      // Offline, DNS failure, timeout, malformed JSON, storage error — all the
      // same answer: keep whatever we already had.
      debugPrint('[i18n] overlay refresh failed for $langCode: $e');
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// Clears a cached overlay, returning the locale to bundled copy. The manual
  /// escape hatch if a bad delta ever ships.
  static Future<void> clear(String langCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteTranslationLoader.cacheKey(langCode));
      await prefs.remove(RemoteTranslationLoader.etagKey(langCode));
    } catch (_) {
      // Nothing to do — a failed clear leaves the previous copy in place.
    }
  }
}
