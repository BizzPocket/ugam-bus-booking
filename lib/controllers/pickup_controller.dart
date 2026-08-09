import 'dart:developer' as dev;

import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/pickup_location.dart';

/// Owns the GLOBAL list of pickup points (migration 031's `pickup_locations`).
///
/// The list is shared across every tour: the admin manages it once in Settings
/// and customers OPTIONALLY pick one when they book. [all] holds every row for
/// the admin manager; [active] is the customer-facing subset (visible points, in
/// manual order). Registered lazily in `app.dart` and loaded on first use via
/// [ensureLoaded], so any screen can depend on it without triggering a fetch
/// until the list is actually shown.
class PickupController extends GetxController {
  static const String _table = 'pickup_locations';

  /// Every row, in server order. The admin manager renders off this list.
  final RxList<PickupLocation> all = <PickupLocation>[].obs;

  /// Whether the list has been fetched at least once successfully.
  final RxBool loadedOnce = false.obs;

  /// True when the last refresh failed — [ensureLoaded] will retry.
  final RxBool loadFailed = false.obs;

  Future<void>? _refreshInFlight;
  int _refreshGeneration = 0;

  SupabaseClient get _client => Supabase.instance.client;

  /// The customer-facing subset: only visible points, in manual [sortOrder].
  List<PickupLocation> get active =>
      all.where((p) => p.isActive).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// The admin-facing short code for a pickup id, or null if unknown/blank.
  /// Reads the reactive [all] list so callers wrapped in Obx repaint on load.
  ///
  /// The read happens on EVERY path, including the "nothing to look up" ones: a
  /// bare early-return would leave an enclosing Obx with zero observables, which
  /// GetX reports as "improper use of a GetX" and paints as an error box.
  String? codeFor(String? id) {
    final rows = all.toList(growable: false);
    if (id == null) return null;
    for (final p in rows) {
      if (p.id == id) return _normCode(p.code);
    }
    return null;
  }

  /// Loads the list once. Safe to call from every screen that needs it — it
  /// no-ops after the first successful load. Retries after a failed attempt.
  Future<void> ensureLoaded() async {
    if (loadedOnce.value && !loadFailed.value) return;
    await refresh();
  }

  /// Reloads the full list from Supabase. On error the current list is left
  /// untouched and [loadFailed] is set so [ensureLoaded] can retry.
  @override
  Future<void> refresh() async {
    if (_refreshInFlight != null) return _refreshInFlight!;
    final future = _refreshBody();
    _refreshInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    }
  }

  Future<void> _refreshBody() async {
    final gen = ++_refreshGeneration;
    try {
      final rows = await _client
          .from(_table)
          .select(
            'id,name,code,sort_order,is_active',
          )
          .order('sort_order', ascending: true)
          .order('created_at', ascending: true) as List;
      if (gen != _refreshGeneration) return;
      all.assignAll(
        rows.map(
          (r) => PickupLocation.fromMap(Map<String, dynamic>.from(r as Map)),
        ),
      );
      loadedOnce.value = true;
      loadFailed.value = false;
    } catch (e, st) {
      if (gen != _refreshGeneration) return;
      dev.log('pickup refresh failed: $e\n$st', name: 'PickupController');
      loadFailed.value = true;
      // Do NOT set loadedOnce on failure — ensureLoaded must retry.
    }
  }

  /// The pickup point's position in the admin's manual serial — the ONE order
  /// every surface that lists pickups should read in (manager list, customer
  /// picker, the handler's pickup-grouped rosters). Lower sorts first.
  ///
  /// Resolves by [id] first, then falls back to a case-insensitive [name] match
  /// so a booking snapshot taken before the id column (or one whose point was
  /// renamed-and-recreated) still lands in the right slot. Returns null when the
  /// point isn't in the list at all — including before the list has loaded — so
  /// callers can order the leftovers themselves.
  ///
  /// Reads the reactive [all] list on EVERY path (see [codeFor] for why).
  int? rankFor({String? id, String? name}) {
    // `all` arrives ordered by sort_order, created_at — index IS the serial.
    final rows = all.toList(growable: false);
    if (id != null && id.isNotEmpty) {
      final i = rows.indexWhere((p) => p.id == id);
      if (i >= 0) return i;
    }
    final n = (name ?? '').trim().toLowerCase();
    if (n.isEmpty) return null;
    final i = rows.indexWhere((p) => p.name.trim().toLowerCase() == n);
    return i >= 0 ? i : null;
  }

  /// Normalises an admin-facing short code: trims, upper-cases, caps at 6 chars,
  /// and maps a blank code to null (so the column stays null, not "").
  String? _normCode(String? code) {
    final t = (code ?? '').trim().toUpperCase();
    if (t.isEmpty) return null;
    return t.length > 6 ? t.substring(0, 6) : t;
  }

  /// Adds a new pickup point at the end of the list. No-ops on a blank name.
  Future<void> addLocation(String name, {String? code}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final maxOrder = all.isEmpty
        ? 0
        : all.map((p) => p.sortOrder).reduce((a, b) => a > b ? a : b);
    await _client.from(_table).insert({
      'name': trimmed,
      'code': _normCode(code),
      'sort_order': maxOrder + 1,
    });
    await refresh();
  }

  /// Updates one point's name (and admin-facing short code). No-ops on a blank
  /// name. Passing a blank/null [code] clears it.
  Future<void> updateLocation(
    String id, {
    required String name,
    String? code,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _client
        .from(_table)
        .update({'name': trimmed, 'code': _normCode(code)})
        .eq('id', id);
    await refresh();
  }

  /// Shows or hides a point from the customer picker (keeps the row for the
  /// admin manager and historical snapshots).
  Future<void> setActive(String id, bool isActive) async {
    await _client.from(_table).update({'is_active': isActive}).eq('id', id);
    await refresh();
  }

  /// Permanently removes a point. Historical requests keep their snapshotted
  /// name (there is no FK), so past bookings stay readable.
  Future<void> deleteLocation(String id) async {
    await _client.from(_table).delete().eq('id', id);
    await refresh();
  }

  /// Reorders the ACTIVE list (drag-to-reorder from the admin manager) and
  /// persists the new [sortOrder] of every row whose position changed.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = active;
    if (oldIndex < 0 || oldIndex >= list.length) return;
    // ReorderableListView reports newIndex as the slot AFTER removal when an
    // item moves down — normalise it to a plain target index.
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= list.length) target = list.length - 1;

    final moved = list.removeAt(oldIndex);
    list.insert(target, moved);

    // Reassign sort_order sequentially; only push rows that actually changed.
    for (var i = 0; i < list.length; i++) {
      final loc = list[i];
      if (loc.sortOrder == i) continue;
      await _client.from(_table).update({'sort_order': i}).eq('id', loc.id);
    }
    await refresh();
  }
}
