import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_retry_policy.dart';
import 'package:occubusbooking/services/sync_service.dart'
    show RpcUnavailableException, SyncService;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('isRetryable', () {
    test('missing RPC is terminal', () {
      expect(isRetryable(RpcUnavailableException('fn'), retryOnTimeout: true),
          isFalse);
    });

    test('timeout is retryable only for idempotent callers', () {
      final e = TimeoutException('slow');
      expect(isRetryable(e, retryOnTimeout: true), isTrue);
      expect(isRetryable(e, retryOnTimeout: false), isFalse);
    });

    test('auth error is terminal', () {
      expect(isRetryable(const AuthException('bad session'),
          retryOnTimeout: true), isFalse);
    });

    test('constraint / RLS codes are terminal; 5xx & explicit 503 transient',
        () {
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '42501'),
              retryOnTimeout: true),
          isFalse); // RLS denial
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '23505'),
              retryOnTimeout: true),
          isFalse); // unique_violation (has its own fallback)
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '503'),
              retryOnTimeout: true),
          isTrue);
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '500'),
              retryOnTimeout: true),
          isTrue); // status >= 500
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '400'),
              retryOnTimeout: true),
          isFalse); // status 4xx terminal
      expect(
          isRetryable(const PostgrestException(message: 'x', code: 'PGRST001'),
              retryOnTimeout: true),
          isTrue); // explicit DB-unreachable code
    });

    // X-4: classification is typed (exception type + known codes), never a
    // message-substring guess. A null/unknown Postgrest code — even one whose
    // *message* reads like a network failure — is terminal.
    test('unknown/null-code postgrest is non-retryable (no message sniffing)',
        () {
      expect(
          isRetryable(
              const PostgrestException(message: 'Failed host lookup: db'),
              retryOnTimeout: true),
          isFalse);
      expect(
          isRetryable(
              const PostgrestException(message: 'connection reset by peer'),
              retryOnTimeout: true),
          isFalse);
      expect(
          isRetryable(const PostgrestException(message: 'permission denied'),
              retryOnTimeout: true),
          isFalse);
    });

    test('dart:io transport failures are transient', () {
      expect(isRetryable(const SocketException('boom'), retryOnTimeout: true),
          isTrue);
      expect(isRetryable(const HttpException('boom'), retryOnTimeout: true),
          isTrue);
    });

    // X-4: an unknown exception type is terminal even when its message
    // contains a transport-sounding word — no message sniffing.
    test('unknown exception types are non-retryable regardless of message',
        () {
      expect(isRetryable(Exception('totally unknown'), retryOnTimeout: true),
          isFalse);
      expect(
          isRetryable(Exception('some network glitch'), retryOnTimeout: true),
          isFalse);
    });
  });

  group('resolveInsertConflict', () {
    test('23505 with an existing id → update-by-id', () {
      expect(resolveInsertConflict(code: '23505', rowWithIdExists: true),
          InsertConflictAction.updateById);
    });
    test('23505 on a different column (no row at id) → rethrow', () {
      expect(resolveInsertConflict(code: '23505', rowWithIdExists: false),
          InsertConflictAction.rethrowError);
    });
    test('non-23505 codes → rethrow', () {
      expect(resolveInsertConflict(code: '23503', rowWithIdExists: true),
          InsertConflictAction.rethrowError);
      expect(resolveInsertConflict(code: null, rowWithIdExists: false),
          InsertConflictAction.rethrowError);
    });
  });

  group('isPreSendConnectionError (non-idempotent swap)', () {
    test('true only for pre-send socket failures', () {
      expect(
          isPreSendConnectionError(
              const SocketException('Failed host lookup: api')),
          isTrue);
      expect(isPreSendConnectionError(const SocketException('Connection refused')),
          isTrue);
      expect(
          isPreSendConnectionError(
              const SocketException('Network is unreachable')),
          isTrue);
      expect(isPreSendConnectionError(const SocketException('No route to host')),
          isTrue);
    });
    test('false for mid-flight resets and timeouts (never re-swap)', () {
      expect(
          isPreSendConnectionError(
              const SocketException('Connection reset by peer')),
          isFalse);
      expect(isPreSendConnectionError(TimeoutException('slow')), isFalse);
    });
  });

  // Deploy-order safety for migration 054. The archive filter must switch
  // itself off — and ONLY off — when the server says `deleted_at` is missing.
  // Getting the classifier too broad silently disables archive filtering for
  // the whole session; too narrow and every read 400s on a healthy network.
  group('soft-delete deploy probe', () {
    setUp(SyncService.resetSoftDeleteProbe);
    tearDown(SyncService.resetSoftDeleteProbe);

    PostgrestException pg(String message, {String? code}) =>
        PostgrestException(message: message, code: code);

    test('recognises the missing deleted_at column (by SQLSTATE)', () {
      expect(
        SyncService.isMissingDeletedAtError(
            pg('column tours.deleted_at does not exist', code: '42703')),
        isTrue,
      );
    });

    test('recognises it by message alone when no SQLSTATE is supplied', () {
      expect(
        SyncService.isMissingDeletedAtError(
            pg('column collections.deleted_at does not exist')),
        isTrue,
      );
    });

    test('an UNRELATED missing column must NOT disarm the filter', () {
      // The dangerous false positive: one unrelated schema gap would otherwise
      // switch archive filtering off everywhere for the rest of the session.
      expect(
        SyncService.isMissingDeletedAtError(
            pg('column buses.pickup_code does not exist', code: '42703')),
        isFalse,
      );
    });

    test('an RLS refusal must NOT disarm the filter', () {
      expect(
        SyncService.isMissingDeletedAtError(
            pg('permission denied for table collections', code: '42501')),
        isFalse,
      );
    });

    test('non-Postgrest errors are never a schema signal', () {
      expect(SyncService.isMissingDeletedAtError(TimeoutException('slow')),
          isFalse);
      expect(
          SyncService.isMissingDeletedAtError(
              const SocketException('Failed host lookup: api')),
          isFalse);
    });

    test('the filter is armed by default', () {
      expect(SyncService.softDeleteFilterActive, isTrue);
    });
  });
}
