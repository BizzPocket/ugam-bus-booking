import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// Worst-case sustained uplink this app is built for (GPRS-class, bytes/s).
  /// Used only to stretch the deadline for a LARGE request body.
  static const int _slowestUplinkBytesPerSecond = 4000;

  /// Upper bound on the stretched upload deadline, so a huge body cannot buy
  /// an effectively unbounded wait.
  static const Duration _maxUploadDeadline = Duration(minutes: 3);

  /// The deadline for [request] to be SENT and answered with headers.
  ///
  /// [defaultTimeout] alone covers the whole upload as well as the server's
  /// reply, so a 300 kB seat-chart image on a 4 kB/s uplink — 75 s of pure
  /// transfer — was killed at 30 s every time, and every retry re-uploaded it
  /// from zero. A body larger than 64 kB gets its transfer time at the slowest
  /// link speed added on top, capped at [_maxUploadDeadline]. Small requests
  /// (every PostgREST read/write) are untouched.
  @visibleForTesting
  static Duration deadlineFor(http.BaseRequest request) {
    final length = request.contentLength ?? 0;
    if (length <= 64 * 1024) return defaultTimeout;
    final transfer = Duration(
      milliseconds: (length * 1000 / _slowestUplinkBytesPerSecond).round(),
    );
    final total = defaultTimeout + transfer;
    return total > _maxUploadDeadline ? _maxUploadDeadline : total;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final deadline = deadlineFor(request);
    final response = await _inner.send(request).timeout(
      deadline,
      onTimeout: () {
        // Named explicitly: a bare TimeoutException from deep inside the
        // Supabase client is very hard to attribute in a crash report.
        throw TimeoutException(
          'No response from ${request.method} ${request.url.path} within '
          '${deadline.inSeconds}s',
          deadline,
        );
      },
    );

    // The deadline above ends when the HEADERS arrive. The body is a separate
    // stream, and on a lossy link the classic failure is a socket that delivers
    // the headers and then goes silent mid-body (signal lost on a moving bus):
    // with no bound here that read waits on the OS TCP timeout — many minutes —
    // behind a spinner, holding one of SyncService's two cellular read slots.
    //
    // This is an IDLE timeout, not a total one: it fires only when no bytes at
    // all arrive for [defaultTimeout], so a slow-but-progressing download of a
    // large roster or a poster is never killed.
    final idle = defaultTimeout;
    final body = response.stream.timeout(
      idle,
      onTimeout: (sink) {
        sink.addError(
          TimeoutException(
            'Response body from ${request.method} ${request.url.path} '
            'stalled for ${idle.inSeconds}s',
            idle,
          ),
        );
        sink.close();
      },
    );
    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
