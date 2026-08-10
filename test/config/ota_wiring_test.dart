import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/config/remote_flags_config.dart';
import 'package:occubusbooking/config/translation_overlay_config.dart';

/// Guards the OTA channel wiring in both directions.
///
/// Run bare (the normal suite) both channels must be DORMANT — that is the
/// shipped default and the reason a developer build never phones home.
///
/// Run with the real endpoints:
///
///   flutter test --dart-define-from-file=config/ota.json test/config/ota_wiring_test.dart
///
/// both must be live and well-formed. That second run is the only thing that
/// proves config/ota.json is actually reaching the compiler — a typo'd key name
/// fails silently otherwise, and the app ships unable to be force-updated with
/// nothing to indicate it.
void main() {
  final wired = RemoteFlagsConfig.enabled || TranslationOverlayConfig.enabled;

  test('dormant by default, live when the defines are supplied', () {
    if (!wired) {
      expect(RemoteFlagsConfig.url, isEmpty);
      expect(TranslationOverlayConfig.baseUrl, isEmpty);
      expect(RemoteFlagsConfig.enabled, isFalse);
      expect(TranslationOverlayConfig.enabled, isFalse);
      return;
    }

    // Partial wiring is the dangerous state: it looks configured and is half
    // dead. If either define lands, both must.
    expect(
      RemoteFlagsConfig.enabled,
      isTrue,
      reason: 'REMOTE_FLAGS_URL missing while the i18n one landed — check the '
          'key name in config/ota.json',
    );
    expect(
      TranslationOverlayConfig.enabled,
      isTrue,
      reason: 'I18N_OVERLAY_BASE_URL missing while the flags one landed',
    );
  });

  test('the endpoints are absolute https URLs', () {
    if (!wired) return;

    for (final url in [
      RemoteFlagsConfig.url,
      TranslationOverlayConfig.baseUrl,
    ]) {
      final uri = Uri.parse(url);
      expect(uri.isAbsolute, isTrue, reason: '$url is not absolute');
      expect(uri.scheme, 'https', reason: '$url must be https');
      expect(uri.host, isNotEmpty);
    }
  });

  test('the i18n base is a DIRECTORY, not a file', () {
    if (!TranslationOverlayConfig.enabled) return;

    // The loader appends /<langCode>.json. A base that already ends in .json
    // would request .../gu.json/gu.json and silently never overlay anything.
    expect(
      TranslationOverlayConfig.baseUrl.endsWith('.json'),
      isFalse,
      reason: 'I18N_OVERLAY_BASE_URL must be the folder, not a file — the '
          'loader appends /<lang>.json',
    );
    expect(TranslationOverlayConfig.baseUrl.endsWith('/'), isFalse,
        reason: 'no trailing slash — the loader adds one');
  });

  test('the flags endpoint IS a file', () {
    if (!RemoteFlagsConfig.enabled) return;
    expect(
      RemoteFlagsConfig.url.endsWith('.json'),
      isTrue,
      reason: 'REMOTE_FLAGS_URL is fetched verbatim; it must name the document',
    );
  });
}
