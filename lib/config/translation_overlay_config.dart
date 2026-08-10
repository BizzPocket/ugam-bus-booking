/// Where the remote translation overlay is fetched from.
///
/// The overlay is a *delta*: a small JSON of only the keys that changed since
/// the build shipped. The bundled catalogue in `assets/translations/` stays in
/// `pubspec.yaml` permanently as the offline floor — the overlay never replaces
/// it, only merges over it.
///
/// While [baseUrl] is empty the whole feature is dormant: the loader reads the
/// bundled catalogue and nothing else, no network call is ever made, and
/// behaviour is bit-identical to before it existed. Point it at a public bucket
/// to switch it on without a store release.
class TranslationOverlayConfig {
  const TranslationOverlayConfig._();

  /// Base URL holding one `langCode.json` delta file per locale.
  ///
  /// Expected layout, e.g. for a Supabase public bucket:
  /// `https://PROJECT.supabase.co/storage/v1/object/public/i18n/gu.json`
  /// in which case this constant is everything up to and including `/i18n`.
  ///
  /// Empty = feature off. This is the default and is deliberately safe.
  static const String baseUrl = String.fromEnvironment(
    'I18N_OVERLAY_BASE_URL',
    defaultValue: '',
  );

  static bool get enabled => baseUrl.isNotEmpty;

  /// Hard ceiling on a downloaded delta. A delta is expected to be a few KB;
  /// anything approaching the size of a full catalogue means someone uploaded
  /// the wrong file, and we refuse it rather than cache it.
  static const int maxBytes = 64 * 1024;

  /// The overlay must never make a user wait. Well under the shortest
  /// reasonable cold start.
  static const Duration fetchTimeout = Duration(seconds: 5);
}
