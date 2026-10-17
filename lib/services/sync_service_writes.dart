part of 'sync_service.dart';

/// The single server-write path behind [SyncService]'s public writes and
/// atomic seat RPCs.
extension _SyncServerWrites on SyncService {
  /// [_writeToServer] under the shared write retry policy. Every generic write
  /// is idempotent by entity id, so a timeout that actually landed converges
  /// on retry (see each caller for why).
  Future<void> _retriedWrite(
    String operation,
    String table,
    String entityId,
    Map<String, dynamic> data,
  ) => _withRetry(
    () => _writeToServer(
      operation: operation,
      table: table,
      entityId: entityId,
      data: data,
    ),
    timeout: SyncService._writeTimeout,
    label: '$operation $table',
  );

  /// Tables whose RLS policies require `owner_id = auth.uid()`. We backfill
  /// `owner_id` from the current session before writing so an admin write
  /// never lands without it.
  static const _ownerScopedTables = {
    'tours',
    'buses',
    'admin_contacts',
    'customer_memory',
  };

  Future<void> _callRpc(String fn, Map<String, dynamic> params) async {
    await _rpcOrUnavailable(fn, params);
  }

  /// Runs RPC [fn], translating "function does not exist" into
  /// [RpcUnavailableException]. Shared by [_callRpc] and
  /// [SyncService.callRpcResult].
  Future<dynamic> _rpcOrUnavailable(
    String fn,
    Map<String, dynamic> params,
  ) async {
    try {
      return await _client.rpc(fn, params: params);
    } on PostgrestException catch (e) {
      // PGRST202 (PostgREST) / 42883 (Postgres) = function does not exist —
      // the migration isn't deployed. Signal a graceful fallback.
      if (e.code == 'PGRST202' || e.code == '42883') {
        throw RpcUnavailableException(fn);
      }
      rethrow;
    }
  }

  /// Single source of truth for the actual server write. Throws on failure —
  /// callers decide whether to revert optimistic UI or surface an error.
  Future<void> _writeToServer({
    required String operation,
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    final clean = Map<String, dynamic>.from(data)
      ..remove(r'$id')
      ..remove(r'$createdAt')
      ..remove(r'$updatedAt');
    clean['id'] = entityId;

    // Backfill owner_id from the current Supabase Auth session for tables
    // whose RLS requires it.
    //
    // Skipped for 'patch': a patch promises to touch ONLY the caller's columns,
    // and an UPDATE does not need owner_id in the payload anyway — RLS matches
    // the row on its existing owner.
    final authUid = _client.auth.currentUser?.id;
    if (operation != 'patch' &&
        _ownerScopedTables.contains(table) &&
        authUid != null &&
        (clean['owner_id'] == null ||
            (clean['owner_id'] is String &&
                (clean['owner_id'] as String).isEmpty))) {
      clean['owner_id'] = authUid;
    }

    switch (operation) {
      case 'insert':
        try {
          await _client.from(table).insert(clean);
        } on PostgrestException catch (e) {
          // 23505 = unique_violation. Usually the conflict is on a non-id
          // column (e.g. (tour_id, phone) on passengers). Only fall back
          // to UPDATE when a row with this exact id already exists.
          final existing = e.code == '23505'
              ? await _client
                    .from(table)
                    .select('id')
                    .eq('id', entityId)
                    .maybeSingle()
              : null;
          switch (retry.resolveInsertConflict(
            code: e.code,
            rowWithIdExists: existing != null,
          )) {
            case retry.InsertConflictAction.updateById:
              final updateData = Map<String, dynamic>.from(clean)..remove('id');
              await _client.from(table).update(updateData).eq('id', entityId);
            case retry.InsertConflictAction.rethrowError:
              rethrow;
          }
        }
        break;
      case 'update':
        final updateData = Map<String, dynamic>.from(clean)..remove('id');
        final res = await _client
            .from(table)
            .update(updateData)
            .eq('id', entityId)
            .select();
        if ((res as List).isEmpty) {
          // Row missing — fall back to insert.
          await _client.from(table).insert(clean);
        }
        break;
      case 'patch':
        // Column-scoped update: writes ONLY the keys the caller supplied and
        // NEVER falls back to insert. The insert fallback above is safe for a
        // whole-entity map but catastrophic for a partial one — it would
        // materialise a row containing just the patched columns and defaults
        // for everything else.
        //
        // A patch that matches no row is therefore a BUG (wrong id, or the row
        // was deleted underneath us), and it surfaces as an error rather than
        // being papered over with a half-built row.
        final patchData = Map<String, dynamic>.from(clean)..remove('id');
        final patched = await _client
            .from(table)
            .update(patchData)
            .eq('id', entityId)
            .select();
        if ((patched as List).isEmpty) {
          throw StateError(
            'patch $table/$entityId matched no row — refusing to insert a '
            'partial row from ${patchData.keys.join(', ')}',
          );
        }
        break;
      case 'delete':
        // SOFT DELETE (054): money-bearing rows are archived, never destroyed.
        // Routed here rather than at the ~8 call sites so no future delete can
        // opt out by accident — the table set is the single switch.
        //
        // Idempotent like the hard delete it replaces: re-stamping deleted_at
        // on an already-archived row is harmless, so a timed-out write that
        // actually landed still converges on retry. `deleted_by` is only
        // stamped when there is a signed-in admin; handler-initiated deletes
        // record their own actor server-side in their RPCs.
        if (SyncService.softDeletableTables.contains(table)) {
          final archive = <String, dynamic>{
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          };
          if (authUid != null) archive['deleted_by'] = authUid;
          await _client.from(table).update(archive).eq('id', entityId);
        } else {
          await _client.from(table).delete().eq('id', entityId);
        }
        break;
    }
  }
}
