import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_service.dart' show RpcUnavailableException;

/// What to do when an INSERT fails with 23505 (unique_violation).
enum InsertConflictAction { rethrowError, updateById }

/// Pure decision for the insert-conflict fallback. A 23505 whose row already
/// exists at this id means the same entity id was re-inserted → convert to an
/// UPDATE. A 23505 on a DIFFERENT column (e.g. (tour_id, phone) on passengers)
/// with no row at this id is a genuine conflict → rethrow. Any non-23505 code
/// is not this fallback's concern → rethrow.
InsertConflictAction resolveInsertConflict({
  required String? code,
  required bool rowWithIdExists,
}) {
  if (code != '23505') return InsertConflictAction.rethrowError;
  return rowWithIdExists
      ? InsertConflictAction.updateById
      : InsertConflictAction.rethrowError;
}

/// Classifies whether [e] is a transient failure worth retrying. Retry only
/// known network/transport/5xx failures (and, when [retryOnTimeout],
/// timeouts); every constraint, permission, auth, and missing-function error
/// is terminal.
///
/// X-4: classification is by exception TYPE and known codes only — never by
/// message-substring sniffing (fragile, locale/SDK-dependent). An unknown
/// exception type, or a `PostgrestException` with an unknown/null code, is
/// therefore terminal rather than guessed from its message.
bool isRetryable(Object e, {required bool retryOnTimeout}) {
  if (e is RpcUnavailableException) return false; // deploy issue — never helps
  if (e is TimeoutException) return retryOnTimeout; // only idempotent callers
  if (e is AuthException) return false; // invalid/expired session — terminal

  if (e is PostgrestException) {
    final code = e.code;
    const terminal = {
      '42501', // insufficient_privilege (RLS denial)
      '23505', // unique_violation (has insert->update fallback)
      '23503', // foreign_key_violation
      '23514', // check_violation
      '23502', // not_null_violation
      '22P02', // invalid_text_representation
      'PGRST202', // function not found
      '42883', // function does not exist
    };
    if (code != null && terminal.contains(code)) return false;
    if (code == '503' || code == 'PGRST001') return true;
    final status = int.tryParse(code ?? '');
    if (status != null) {
      if (status >= 500) return true;
      if (status >= 400) return false;
    }
    // Unknown / null code ⇒ terminal (no message sniffing).
    return false;
  }

  if (e is SocketException) return true;
  if (e is HttpException) return true;
  // Unknown exception type ⇒ terminal (no message sniffing).
  return false;
}

/// Certain the request never left the device: DNS failure, no route, or
/// connection refused BEFORE any bytes were sent. Excludes connection
/// reset/closed (can happen mid-flight after a write may already have landed)
/// and timeouts — used only for the non-idempotent swap RPC.
bool isPreSendConnectionError(Object e) {
  if (e is! SocketException) return false;
  final m = e.toString().toLowerCase();
  return m.contains('failed host lookup') ||
      m.contains('connection refused') ||
      m.contains('network is unreachable') ||
      m.contains('no route to host');
}
