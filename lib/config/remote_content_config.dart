/// Where the server-driven content document is fetched from.
///
/// Narrow scope by design: notices, promos and links on the customer surface.
/// Not a UI language — see [ContentBlock] for why the seat chart, the money
/// surfaces and the handler flow stay native.
///
/// Empty means dormant: no network call is ever made and every content slot
/// renders nothing, exactly as before the feature existed. That is the default.
class RemoteContentConfig {
  const RemoteContentConfig._();

  /// Full URL of the content JSON, e.g. a public bucket object.
  static const String url = String.fromEnvironment(
    'REMOTE_CONTENT_URL',
    defaultValue: '',
  );

  static bool get enabled => url.isNotEmpty;

  /// A handful of blocks is a couple of KB. This ceiling exists so a wrong
  /// file — or a document that has grown into something it should not be —
  /// is refused rather than cached and rendered.
  static const int maxBytes = 32 * 1024;

  /// Content must never make a user wait; nothing awaits this on a UI path.
  static const Duration fetchTimeout = Duration(seconds: 5);
}
