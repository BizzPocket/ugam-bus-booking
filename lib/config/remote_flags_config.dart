/// Where the remote flag document is fetched from.
///
/// A single small JSON holding the launch gate, the maintenance switch, feature
/// kill switches and numeric tunables. Deliberately NOT Firebase Remote Config:
/// that would add a federated native plugin (a store build on both platforms,
/// plus console setup) to ship what is fundamentally one small file. The
/// fetcher is swappable, so Remote Config can be adopted later — for its
/// percentage targeting — without the gate itself changing.
///
/// While [baseUrl] is empty the service is dormant: no network call is ever
/// made, every flag reads its compiled-in default, and the launch gate never
/// blocks. That is the default and it is deliberately safe.
class RemoteFlagsConfig {
  const RemoteFlagsConfig._();

  /// Full URL of the flags JSON, e.g. a public bucket object.
  /// Empty = feature off.
  static const String url = String.fromEnvironment(
    'REMOTE_FLAGS_URL',
    defaultValue: '',
  );

  static bool get enabled => url.isNotEmpty;

  /// The flags document is a handful of lines. Anything larger is the wrong
  /// file and is refused rather than cached.
  static const int maxBytes = 32 * 1024;

  /// The gate must never make a user wait. This bounds the background warm,
  /// which nothing on the boot path awaits anyway.
  static const Duration fetchTimeout = Duration(seconds: 3);
}
