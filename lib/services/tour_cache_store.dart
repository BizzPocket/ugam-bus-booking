import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/tour.dart';

/// READ-SIDE ONLY disk cache of the tour graph — tours + buses + bus LAYOUTS +
/// passengers + groups — so the chart and the roster are readable with no
/// network, and so a cold start paints from disk instead of a spinner.
///
/// ── Why this is not the cache that was deleted ────────────────────────────
///
/// `SyncService`'s header records that a SQLite offline cache + write queue
/// (`OfflineDatabase`) was removed because it (1) let stale tours survive
/// logout / reinstall — Android Auto Backup restored the database — and (2)
/// masked real fetch failures as empty results. Both defects are structurally
/// impossible here, and the structure is the point:
///
///  1. **It cannot outlive the session.** Every file is keyed by the logged-in
///     ADMIN's id, an anonymous / customer viewer is never cached at all,
///     [clearAll] runs on logout and on any cold start that does not restore an
///     admin session, and the bytes live in the platform's NO-BACKUP cache
///     directory (see [_platformCacheDirectory]) so no restore path can bring
///     them back after a reinstall.
///  2. **It cannot masquerade as live.** Every envelope carries [savedAt], and
///     the ONLY way to read one is [read], which hands that timestamp back. The
///     caller (`TourController`) flags the data as cached and the UI says so.
///     There is no "return the cache and pretend the fetch worked" path,
///     because nothing in here ever runs on a fetch failure — it runs on a
///     fetch SUCCESS, and only the controller decides what to show.
///
/// There is deliberately NO write queue / outbox. Writes still require the
/// network and still fail fast; that contract is unchanged. Nor does a cached
/// grid ever travel back to the server: a hydrated bus is built by exactly the
/// path a fetched one is (`Bus.fromMap` → `Bus.layout`), so `Bus.toPatch` still
/// takes `includeLayout` from the CALLER and a from-disk grid can never be
/// mistaken for one this operation just built.
class TourCacheStore {
  /// Bump to orphan every cached file at once (a model shape change, a fixed
  /// encode bug). A file written by another version is deleted on read rather
  /// than half-parsed.
  static const int schemaVersion = 1;

  /// Sub-directory under the platform cache dir. Kept separate so [clearAll]
  /// can drop the whole tree without touching anything else the OS or another
  /// plugin has put in the cache directory.
  static const String _folder = 'tour_graph';

  TourCacheStore({Future<Directory?> Function()? directory})
      : _resolveDirectory = directory ?? _platformCacheDirectory;

  /// Test seam: point the store at a temp dir instead of the platform one
  /// (there is no path_provider plugin under `flutter test`).
  @visibleForTesting
  factory TourCacheStore.forDirectory(Directory dir) =>
      TourCacheStore(directory: () async => dir);

  /// Process-wide default. Replaceable in tests.
  static TourCacheStore instance = TourCacheStore();

  final Future<Directory?> Function() _resolveDirectory;

  /// Serialises disk work so a debounced write can never interleave with a
  /// logout [clearAll] and re-create the directory it just removed.
  Future<void> _queue = Future<void>.value();

  Future<T?> _serialised<T extends Object>(Future<T?> Function() action) {
    final completer = Completer<T?>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        // A cache is never worth an exception on a UI path.
        dev.log('tour cache op failed: $e\n$st', name: 'TourCacheStore');
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<void> _serialisedVoid(Future<void> Function() action) =>
      _serialised<bool>(() async {
        await action();
        return true;
      });

  /// The platform's cache directory — Android `Context.getCacheDir()`, iOS
  /// `NSCachesDirectory`.
  ///
  /// CHOSEN FOR THE BACKUP EXCLUSION, not for the name. This is the mechanism
  /// that makes "a reinstall cannot restore yesterday's tours" true:
  ///
  ///  * Android — Auto Backup and device-to-device transfer NEVER include
  ///    `getCacheDir()`. `getApplicationSupportDirectory()` (`files/`) IS
  ///    included by default, which is exactly how the deleted `OfflineDatabase`
  ///    came back from the dead after an uninstall.
  ///  * iOS — `Caches/` is excluded from iCloud and iTunes/Finder backups by
  ///    Apple's own data-storage rules. `getApplicationSupportDirectory()`
  ///    (`Library/Application Support/`) is backed up.
  ///
  /// Belt-and-braces on Android: the manifest already sets
  /// `allowBackup="false"` + `fullBackupContent="false"`, and now also
  /// `dataExtractionRules` — `allowBackup="false"` alone does NOT stop the
  /// Android 12+ device-to-device transfer channel.
  ///
  /// The OS may evict a cache directory under storage pressure. That is the
  /// correct trade for this data: losing it costs one network fetch, whereas
  /// keeping it somewhere durable costs the exact bug this replaces.
  static Future<Directory?> _platformCacheDirectory() async {
    try {
      return await getApplicationCacheDirectory();
    } catch (e) {
      // No plugin (unit tests), or the platform refused. Cache stays dormant.
      dev.log('no cache directory: $e', name: 'TourCacheStore');
      return null;
    }
  }

  Future<Directory?> _dir({bool create = false}) async {
    final base = await _resolveDirectory();
    if (base == null) return null;
    final dir = Directory('${base.path}${Platform.pathSeparator}$_folder');
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// One file per scope. Sanitised because the scope key is composed from an
  /// id we did not generate; [read] re-checks the scope INSIDE the envelope so
  /// two keys that sanitise to the same filename can never serve each other's
  /// tours.
  Future<File?> _fileFor(String scopeKey, {bool create = false}) async {
    final dir = await _dir(create: create);
    if (dir == null) return null;
    final safe = scopeKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}$safe.json');
  }

  /// The last graph saved for [scopeKey], or null when there is none, it is
  /// unreadable, or it was written by a different schema version.
  ///
  /// Never throws. A corrupt file is DELETED rather than retried forever.
  Future<TourGraphSnapshot?> read(String scopeKey) =>
      _serialised<TourGraphSnapshot>(() async {
        final file = await _fileFor(scopeKey);
        if (file == null || !await file.exists()) return null;
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map) throw const FormatException('not an object');
          final map = Map<String, dynamic>.from(decoded);
          if (map['schema'] != schemaVersion) {
            await file.delete();
            return null;
          }
          if (map['scope'] != scopeKey) {
            // Sanitised-filename collision, or a hand-edited file. Refuse it —
            // serving another admin's tours is worse than serving none.
            await file.delete();
            return null;
          }
          return TourGraphSnapshot(
            scopeKey: scopeKey,
            savedAt: DateTime.tryParse('${map['saved_at']}') ?? DateTime.now(),
            tours: [
              for (final t in (map['tours'] as List? ?? const []))
                if (t is Map) decodeTour(Map<String, dynamic>.from(t)),
            ],
            layoutKnownNullBusIds: {
              for (final id in (map['layout_known_null'] as List? ?? const []))
                if (id is String) id,
            },
          );
        } catch (e, st) {
          dev.log('cache unreadable, dropping: $e\n$st', name: 'TourCacheStore');
          try {
            await file.delete();
          } catch (_) {
            // Nothing sensible to do — the next write overwrites it anyway.
          }
          return null;
        }
      });

  /// Replaces the cached graph for [TourGraphSnapshot.scopeKey].
  ///
  /// Writes to a sibling temp file and RENAMES it into place. A process kill
  /// mid-write would otherwise leave a truncated JSON document that the next
  /// cold start reads as "no cache" — which is survivable — or, worse, as a
  /// short list of tours, which is not: a half-written graph rendered as if it
  /// were the whole graph is data loss the operator cannot see.
  Future<void> write(TourGraphSnapshot snapshot) =>
      _serialisedVoid(() async {
        final file = await _fileFor(snapshot.scopeKey, create: true);
        if (file == null) return;
        final payload = jsonEncode({
          'schema': schemaVersion,
          'scope': snapshot.scopeKey,
          'saved_at': snapshot.savedAt.toIso8601String(),
          'layout_known_null': snapshot.layoutKnownNullBusIds.toList(),
          'tours': [for (final t in snapshot.tours) encodeTour(t)],
        });
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(payload, flush: true);
        await tmp.rename(file.path);
      });

  /// Drops EVERY cached scope, not just one.
  ///
  /// Called on logout and on any cold start that does not restore an admin
  /// session. Deliberately not scoped to the admin who is leaving: a device
  /// two agents share must not keep the first one's roster on disk after the
  /// second signs in, and "wipe everything" is the only version of that rule
  /// with no edge case.
  Future<void> clearAll() => _serialisedVoid(() async {
        final dir = await _dir();
        if (dir == null || !await dir.exists()) return;
        await dir.delete(recursive: true);
      });
}

/// The tour graph as it was when it was last known FRESH, plus the one piece of
/// out-of-band state a chart cannot be rendered correctly without.
@immutable
class TourGraphSnapshot {
  /// Per-admin cache scope (see `TourController.cacheScopeKey`).
  final String scopeKey;

  /// When this graph was last confirmed against the server — NOT when the file
  /// was written. This is the number the staleness indicator shows, so it has
  /// to mean "the data is this old", not "the file is this old".
  final DateTime savedAt;

  final List<Tour> tours;

  /// Bus ids the SERVER positively answered `layout: null` for.
  ///
  /// MUST round-trip. `Bus.layout == null` is ambiguous — "not fetched yet" vs
  /// "this bus genuinely has no grid" — and only this set tells them apart (see
  /// `TourController._layoutKnownNullBusIds`). Without it a cached cold start
  /// re-derives the WRONG half of that ambiguity and every bus reads as
  /// "loading forever" or, worse, as "no seat plan" on a bus that has one.
  final Set<String> layoutKnownNullBusIds;

  const TourGraphSnapshot({
    required this.scopeKey,
    required this.savedAt,
    required this.tours,
    this.layoutKnownNullBusIds = const {},
  });
}

/// Encode one tour for the cache — the WHOLE tour, including the embedded
/// buses (with layouts), passengers and groups.
///
/// NOT `Tour.toMap()`. That method is a PostgREST write payload, and it is
/// deliberately asymmetric with `Tour.fromMap`: it omits `booking_mode`
/// (a column that isn't on every server), the advance/UPI collection fields,
/// `bus_id`, and the timestamps, and it drops null-valued keys entirely. Round
/// -tripping through it would silently reset a chart-mode tour to request mode
/// and blank its UPI payee on the next cold start. So the write payload is used
/// for the fields it does carry and every remaining field `Tour.fromMap` reads
/// is added explicitly here. `bus_details`, `passenger` and `passenger_group`
/// toMap/fromMap ARE symmetric and are used as-is.
///
/// Dates go out as full ISO strings rather than `Tour.toMap`'s date-only form,
/// so the round trip is exact instead of truncating to midnight.
@visibleForTesting
Map<String, dynamic> encodeTour(Tour t) => {
      ...t.toMap(),
      'owner_id': t.ownerId,
      'bus_id': t.busId,
      'description': t.description,
      'handler_id': t.handlerId,
      'created_by': t.createdBy,
      'booking_mode': t.bookingMode.storageKey,
      'advance_per_berth_paise': t.advancePerBerthPaise,
      'collect_vpa': t.collectVpa,
      'collect_payee_name': t.collectPayeeName,
      'broadcast_message': t.broadcastMessage,
      'broadcast_image_url': t.broadcastImageUrl,
      'departure_date': t.departureDate.toIso8601String(),
      'return_date': t.returnDate?.toIso8601String(),
      'created_at': t.createdAt.toIso8601String(),
      'updated_at': t.updatedAt.toIso8601String(),
      // The seat grids. This is the payload that makes a chart readable with no
      // network, and it is ~71% of the bus bytes — the exact reason cold start
      // fetches it lazily and the exact reason it is worth holding on disk.
      'buses': [for (final b in t.buses) b.toMap()],
      'passengers': [for (final p in t.passengers) p.toMap()],
      'groups': [for (final g in t.groups) g.toMap()],
    };

/// Inverse of [encodeTour]. `Tour.fromMap` already parses the embedded
/// `buses` / `passengers` / `groups` lists, so this is mostly a guard that the
/// nested lists are the shape it expects.
@visibleForTesting
Tour decodeTour(Map<String, dynamic> map) => Tour.fromMap({
      ...map,
      'buses': [
        for (final b in (map['buses'] as List? ?? const []))
          if (b is Map) Map<String, dynamic>.from(b),
      ],
      'passengers': [
        for (final p in (map['passengers'] as List? ?? const []))
          if (p is Map) Map<String, dynamic>.from(p),
      ],
      'groups': [
        for (final g in (map['groups'] as List? ?? const []))
          if (g is Map) Map<String, dynamic>.from(g),
      ],
    });

