import 'dart:async';

import 'package:http/http.dart' as http;

/// Puts a deadline on every HTTP request the Supabase client makes.
///
/// WHY THIS EXISTS
/// `Supabase.initialize` was given no `httpClient`, so every PostgREST read,
/// every RPC, every storage call awaited a socket with no timeout at all —
/// roughly 37 direct call sites across a dozen files. `SyncService` bounds its
/// own reads, and nothing else does.
///
/// On the 2G links this app is built for, "no timeout" does not mean "slow". It
/// means a spinner that never resolves: the handler chart, cash writes, Finance
/// and the pickup screen all hang with no error and no retry affordance. The
/// error reporter cannot see it either, because a hang is not an exception —
/// it is the absence of one.
///
/// A deadline converts an infinite wait into a `TimeoutException`, which the
/// existing error paths already know how to show and the reporter already
/// captures. That is the whole point: not to make slow requests fast, but to
/// make stuck requests finish.
///
/// REMOTELY TUNABLE
/// [defaultTimeout] is mutable and read per request, so `RemoteFlagsService`
/// can raise it from the flag document without a release. If a region turns
/// out to need 45 seconds, that is a config change, not a store submission.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  /// Generous on purpose.
  ///
  /// This is a backstop against hanging forever, NOT a latency budget. Reads
  /// that want to fail fast set their own shorter deadline — SyncService
  /// already does. Too tight here would kill a slow-but-working request on a
  /// 2G link, which is worse than the bug: a large seat-chart PDF upload
  /// legitimately takes tens of seconds on a bad connection.
  static Duration defaultTimeout = const Duration(seconds: 30);

  /// Clamps whatever the flag document says, so a bad config value cannot
  /// reintroduce the unbounded wait (0 or negative) or make it absurd.
  static void applyRemoteTimeout(num? seconds) {
    if (seconds == null) return;
    final s = seconds.round();
    if (s < 5 || s > 120) return;
    defaultTimeout = Duration(seconds: s);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).timeout(
      defaultTimeout,
      onTimeout: () {
        // Named explicitly: a bare TimeoutException from deep inside the
        // Supabase client is very hard to attribute in a crash report.
        throw TimeoutException(
          'No response from ${request.method} ${request.url.path} within '
          '${defaultTimeout.inSeconds}s',
          defaultTimeout,
        );
      },
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
