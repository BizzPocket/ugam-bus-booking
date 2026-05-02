import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

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
    await db.insert('cache', {
      'key': key,
      'data': jsonEncode(data),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<dynamic> getCachedData(String key) async {
    final db = await database;
    final result = await db.query('cache', where: 'key = ?', whereArgs: [key]);
    if (result.isEmpty) return null;
    return jsonDecode(result.first['data'] as String);
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

  Future<void> clearCache() async {
    final db = await database;
    await db.delete('cache');
  }
}
