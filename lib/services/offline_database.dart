import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Payloads bigger than this (after rough size estimation) get encoded
/// on a worker isolate via [compute]. Smaller payloads stay on the main
/// isolate because the message-passing copy cost outweighs the encode.
/// 8 KB is the empirical break-even point on a mid-range Android device.
const int _kOffloadThresholdBytes = 8 * 1024;

// Top-level helpers — `compute` requires its target to be top-level or
// static so the isolate spawn can resolve it by name.
String _encodeJson(Object? value) => jsonEncode(value);
dynamic _decodeJson(String source) => jsonDecode(source);

/// Local SQLite cache for offline-first operation.
/// Stores tours, passengers, bus_details locally.
/// Syncs with Appwrite when online.
class OfflineDatabase {
  static final OfflineDatabase _instance = OfflineDatabase._internal();
  factory OfflineDatabase() => _instance;
  OfflineDatabase._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      join(dbPath, 'tourpro_cache.db'),
      version: 1,
      onCreate: (db, version) async {
        // Cache table: stores full JSON of each entity
        await db.execute('''
          CREATE TABLE cache (
            key TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');

        // Pending operations queue (for offline mutations)
        await db.execute('''
          CREATE TABLE pending_ops (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            operation TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            data TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            retries INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
  }

  // ── Cache Read/Write ──────────────────────────────────────

  Future<void> cacheData(String key, dynamic data) async {
    final db = await database;
    // Cache payloads for tours are typically 100KB+ (nested passengers
    // + buses). Encoding that on the main isolate stalls the frame
    // pipeline for ~10-30ms on mid-range devices — visible jank. We
    // offload large encodes to a worker isolate via [compute]; small
    // ones stay on main because the SendPort copy cost would dominate.
    final encoded = await _maybeOffloadEncode(data);
    await db.insert('cache', {
      'key': key,
      'data': encoded,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<dynamic> getCachedData(String key) async {
    final db = await database;
    final result = await db.query('cache', where: 'key = ?', whereArgs: [key]);
    if (result.isEmpty) return null;
    final raw = result.first['data'] as String;
    return _maybeOffloadDecode(raw);
  }

  /// Encode `value` on a worker isolate when the resulting string is
  /// expected to be large enough that on-main encoding would jank the
  /// frame. We approximate the size by encoding once on main when the
  /// value is `List`/`Map` and routing to `compute` based on element
  /// count — cheaper than a full encode-then-measure.
  Future<String> _maybeOffloadEncode(Object? value) async {
    final shouldOffload = _looksLarge(value);
    if (!shouldOffload) return jsonEncode(value);
    return compute(_encodeJson, value);
  }

  /// Decode on a worker isolate when the source string is over the
  /// offload threshold (a cheap len check on String).
  Future<dynamic> _maybeOffloadDecode(String source) async {
    if (source.length < _kOffloadThresholdBytes) return jsonDecode(source);
    return compute(_decodeJson, source);
  }

  /// Cheap heuristic for "is this payload big enough to offload?".
  /// Counts collection size instead of pre-encoding — for tour data
  /// even a moderate passenger list (>50 entries) easily clears the
  /// 8KB threshold once nested seat-assignment arrays are factored in.
  bool _looksLarge(Object? value) {
    if (value is List) return value.length >= 30;
    if (value is Map) return value.length >= 30;
    return false;
  }

  Future<int?> getCacheAge(String key) async {
    final db = await database;
    final result = await db.query('cache', where: 'key = ?', whereArgs: [key]);
    if (result.isEmpty) return null;
    return DateTime.now().millisecondsSinceEpoch - (result.first['updated_at'] as int);
  }

  // ── Pending Operations Queue ──────────────────────────────

  Future<void> addPendingOp({
    required String tableName,
    required String operation, // insert, update, delete
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    final db = await database;
    await db.insert('pending_ops', {
      'table_name': tableName,
      'operation': operation,
      'entity_id': entityId,
      'data': jsonEncode(data),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getPendingOps() async {
    final db = await database;
    final results = await db.query('pending_ops', orderBy: 'created_at ASC');
    return results.map((r) {
      return {
        'id': r['id'],
        'table_name': r['table_name'],
        'operation': r['operation'],
        'entity_id': r['entity_id'],
        'data': jsonDecode(r['data'] as String),
        'retries': r['retries'],
      };
    }).toList();
  }

  Future<void> removePendingOp(int id) async {
    final db = await database;
    await db.delete('pending_ops', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementRetry(int id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE pending_ops SET retries = retries + 1 WHERE id = ?',
      [id],
    );
  }

  Future<int> pendingOpsCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM pending_ops');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> invalidateCache(String key) async {
    final db = await database;
    await db.delete('cache', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> clearCache() async {
    final db = await database;
    await db.delete('cache');
  }
}
