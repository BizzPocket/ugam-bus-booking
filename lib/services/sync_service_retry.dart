part of 'sync_service.dart';

extension _SyncRetry on SyncService {
  // ── Retry / transient-failure policy ────────────────────────────────
  // Single home for resilience. Each attempt is bounded by [_withTimeout];
  // only transient (network/transport/5xx/timeout) failures are re-run.
  // Terminal errors (RLS/auth, unique-violation, missing-function) surface
  // immediately, and the LAST error is rethrown once attempts are exhausted.

  /// Runs [action] up to [maxAttempts] times with exponential backoff
  /// (~400ms, then ~1200ms) between attempts. A retry happens only when the
  /// error is deemed retryable — by [isRetryable] if supplied, otherwise by
  /// [_isRetryable] (which honours [retryOnTimeout]). Idempotent callers pass
  /// nothing (retry transient incl. timeout); the non-idempotent swap RPC
  /// passes a pre-send-only predicate so a timeout never triggers a re-swap.
  ///
  /// [timeout] bounds each ATTEMPT of [action] as a whole. Pass `null` when
  /// [action] already bounds its own latency internally (X-5: a paginated
  /// read applies [readTimeout] to each individual page round trip) — that
  /// avoids double-bounding a multi-page read with one more aggregate
  /// timeout on top of its own per-page ones.
  Future<T> _withRetry<T>(
    Future<T> Function() action, {
    required Duration? timeout,
    required String label,
    int maxAttempts = 3,
    bool retryOnTimeout = true,
    bool Function(Object error)? isRetryable,
  }) async {
    final predicate =
        isRetryable ??
        ((Object e) => retry.isRetryable(e, retryOnTimeout: retryOnTimeout));
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return timeout != null
            ? await _withTimeout(action(), timeout, label)
            : await action();
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        final isLastAttempt = attempt == maxAttempts - 1;
        if (isLastAttempt || !predicate(e)) rethrow;
        final backoffMs = (400 * math.pow(3, attempt)).round();
        dev.log(
          'RETRY $label — attempt ${attempt + 1}/$maxAttempts failed ($e); '
          'waiting ${backoffMs}ms',
          name: 'SyncService',
        );
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
      }
    }
    // Loop always returns or rethrows; this satisfies the analyzer.
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
  }

  Future<T> _withTimeout<T>(Future<T> future, Duration duration, String label) {
    return future.timeout(
      duration,
      onTimeout: () => throw TimeoutException('$label timed out', duration),
    );
  }
}
