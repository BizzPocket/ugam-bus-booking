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

  /// Whether the list has been fetched at least once (success OR handled error).
  final RxBool loadedOnce = false.obs;

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
  /// no-ops after the first (successful or failed) load.
  Future<void> ensureLoaded() async {
    if (loadedOnce.value) return;
    await refresh();
  }

  /// Reloads the full list from Supabase. On error the current list is left
  /// untouched, but [loadedOnce] is still set so callers stop waiting.
  @override
  Future<void> refresh() async {
    try {
      final rows =
          await _client
                  .from(_table)
                  .select()
                  .order('sort_order', ascending: true)
                  .order('created_at', ascending: true)
              as List;
      all.assignAll(
        rows.map(
          (r) => PickupLocation.fromMap(Map<String, dynamic>.from(r as Map)),
        ),
      );
    } catch (e, st) {
      dev.log('pickup refresh failed: $e\n$st', name: 'PickupController');
    } finally {
      loadedOnce.value = true;
    }
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
