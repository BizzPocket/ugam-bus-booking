import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/config/i18n_config.dart';
import 'package:occubusbooking/config/translation_overlay_config.dart';
import 'package:occubusbooking/services/remote_translation_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The overlay's whole safety case is "it cannot make the app worse than the
/// bundled catalogue". These tests pin that, not the happy path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Dormant: exactly what ships until a base URL is configured.
  const loader = RemoteTranslationLoader();
  // Active: forces the cache-read + merge path so it is genuinely covered.
  const liveLoader = RemoteTranslationLoader(enabledOverride: true);
  const gu = Locale('gu');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('deepMerge', () {
    test('overlay leaf replaces base leaf, siblings survive', () {
      final merged = RemoteTranslationLoader.deepMerge(
        {
          'booking_form': {'label_name': 'old', 'label_phone': 'keep'},
          'other': 'untouched',
        },
        {
          'booking_form': {'label_name': 'new'},
        },
      );

      expect(merged['booking_form']['label_name'], 'new');
      expect(merged['booking_form']['label_phone'], 'keep');
      expect(merged['other'], 'untouched');
    });

    test('overlay can add a key the bundle never had', () {
      final merged = RemoteTranslationLoader.deepMerge(
        {'a': 1},
        {'b': 2},
      );
      expect(merged['a'], 1);
      expect(merged['b'], 2);
    });

    test('merging nothing changes nothing', () {
      final base = {
        'x': {'y': 'z'},
      };
      expect(RemoteTranslationLoader.deepMerge(base, {}), equals(base));
    });

    test('does not mutate the base map', () {
      final base = <String, dynamic>{
        'nested': <String, dynamic>{'k': 'original'},
      };
      RemoteTranslationLoader.deepMerge(base, {
        'nested': {'k': 'changed'},
      });
      expect(base['nested']['k'], 'original');
    });
  });

  group('load', () {
    test('returns the bundled catalogue when the feature is off', () async {
      // baseUrl defaults to empty, so the overlay is dormant and the loader is
      // a pass-through over rootBundle.
      expect(TranslationOverlayConfig.enabled, isFalse);

      final result = await loader.load(I18nConfig.assetPath, gu);

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('a cached overlay is applied over the bundled catalogue', () async {
      final bundled = await liveLoader.load(I18nConfig.assetPath, gu);
      // Pick a real top-level section from the shipped catalogue so the test
      // proves a genuine override rather than a bare insertion.
      final section = bundled!.entries
          .firstWhere((e) => e.value is Map<String, dynamic>);
      final leafKey =
          (section.value as Map<String, dynamic>).keys.firstWhere((k) =>
              (section.value as Map<String, dynamic>)[k] is String);

      SharedPreferences.setMockInitialValues({
        RemoteTranslationLoader.cacheKey('gu'): jsonEncode({
          section.key: {leafKey: 'OVERLAID'},
        }),
      });

      final result = await liveLoader.load(I18nConfig.assetPath, gu);

      expect(result![section.key][leafKey], 'OVERLAID');
      // Untouched siblings survive — a delta must not blow away its section.
      expect(result.keys.length, bundled.keys.length);
    });

    test('a corrupt cached overlay degrades to bundled copy, never throws',
        () async {
      SharedPreferences.setMockInitialValues({
        RemoteTranslationLoader.cacheKey('gu'): '{ this is not json',
      });

      final result = await liveLoader.load(I18nConfig.assetPath, gu);

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('a non-map cached overlay is ignored', () async {
      SharedPreferences.setMockInitialValues({
        RemoteTranslationLoader.cacheKey('gu'): jsonEncode(['not', 'a', 'map']),
      });

      final result = await liveLoader.load(I18nConfig.assetPath, gu);

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('every shipped locale loads from the bundle', () async {
      for (final locale in I18nConfig.supportedLocales) {
        final result = await loader.load(I18nConfig.assetPath, locale);
        expect(
          result,
          isNotEmpty,
          reason: '${locale.languageCode} must have bundled copy as the '
              'offline floor',
        );
      }
    });
  });

  group('TranslationOverlaySync', () {
    test('refresh is a no-op while the feature is off', () async {
      expect(await TranslationOverlaySync.refresh('gu'), isFalse);
    });

    test('clear removes both the cache and the etag', () async {
      SharedPreferences.setMockInitialValues({
        RemoteTranslationLoader.cacheKey('gu'): '{}',
        RemoteTranslationLoader.etagKey('gu'): 'W/"abc"',
      });

      await TranslationOverlaySync.clear('gu');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(RemoteTranslationLoader.cacheKey('gu')), isNull);
      expect(prefs.getString(RemoteTranslationLoader.etagKey('gu')), isNull);
    });
  });
}
