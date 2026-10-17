part of '../tour_controller.dart';

/// Cross-booking groups and remembered-companion suggestions.
mixin _TourGroups on _TourBuses {
  /// Cross-booking groups for [tourId] (empty when the tour is unknown or
  /// has no groups yet). Loaded by the sync layer alongside passengers/buses.
  List<PassengerGroup> groupsForTour(String tourId) =>
      getTour(tourId)?.groups ?? const <PassengerGroup>[];

  /// Suggested groups derived from customer memory: clusters of passengers
  /// PRESENT in [tourId] who are remembered to travel together (from past
  /// tours) and are ALL currently ungrouped. Restricting to fully-ungrouped
  /// clusters keeps the one-tap [recreateCompanionGroup] unambiguous — it
  /// never has to move someone out of an existing group. Each cluster has 2+
  /// members; empty when memory is unavailable or nothing matches.
  List<List<Passenger>> suggestedCompanionGroups(String tourId) {
    if (!Get.isRegistered<CustomerMemoryController>()) return const [];
    final tour = getTour(tourId);
    if (tour == null) return const [];
    final memory = Get.find<CustomerMemoryController>();

    final byPhone = <String, Passenger>{
      for (final p in tour.passengers.where((p) => p.groupId == null))
        normalisePhone(p.phone): p,
    };
    if (byPhone.length < 2) return const [];

    // Union-find over eligible passengers; edges are remembered companions.
    final parent = {for (final k in byPhone.keys) k: k};
    String find(String x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]!]!;
        x = parent[x]!;
      }
      return x;
    }

    var anyEdge = false;
    for (final phone in byPhone.keys) {
      for (final comp in memory.companionPhonesFor(phone)) {
        final cp = normalisePhone(comp);
        if (byPhone.containsKey(cp)) {
          parent[find(phone)] = find(cp);
          anyEdge = true;
        }
      }
    }
    if (!anyEdge) return const [];

    final clusters = <String, List<Passenger>>{};
    for (final phone in byPhone.keys) {
      (clusters[find(phone)] ??= <Passenger>[]).add(byPhone[phone]!);
    }
    return clusters.values.where((m) => m.length >= 2).toList();
  }

  /// One-tap creation of a remembered companion group: makes a fresh group
  /// (labelled from the members' first names) and attaches every member.
  Future<void> recreateCompanionGroup(
    String tourId,
    List<Passenger> members,
  ) async {
    if (members.length < 2) return;
    final label = members
        .map((m) => m.name.trim().split(RegExp(r'\s+')).first)
        .where((s) => s.isNotEmpty)
        .take(3)
        .join(' & ');
    final groupId = await createGroup(
      tourId,
      label.isEmpty ? tr('errors.default_group_label') : label,
      colorIndex: groupsForTour(tourId).length,
    );
    for (final m in members) {
      await setPassengerGroup(tourId, m.id, groupId);
    }
  }

  // Groups (cross-booking)
  //
  // Groups live in their own `passenger_groups` table (one row per group,
  // keyed by tour_id) and are embedded into Tour.groups by the sync layer.
  // These mirror the existing offline-first CRUD shape: stage an optimistic
  // local mutation, await the server write, and on failure pull fresh state
  // + surface the error.

  /// Create a new cross-booking group on [tourId]. Returns the new group id.
  Future<String> createGroup(
    String tourId,
    String label, {
    int colorIndex = 0,
  }) async {
    final group = PassengerGroup(
      tourId: tourId,
      label: label,
      colorIndex: colorIndex,
    );
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(groups: [...t.groups, group]),
      ),
      persist: () => _sync.smartInsert(
        table: 'passenger_groups',
        entityId: group.id,
        data: group.toMap(),
      ),
      failure: tr('errors.create_group'),
    );
    return group.id;
  }

  /// Set or clear a passenger's group membership. Pass `null` to ungroup.
  Future<void> setPassengerGroup(
    String tourId,
    String passengerId,
    String? groupId,
  ) async {
    Passenger? updated;
    await _write(
      // copyWith uses `??`, so it can't clear group_id back to null. Build the
      // updated passenger explicitly to allow an explicit null (ungroup).
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = _passengerWithGroup(p, groupId);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_group'),
    );
  }

  /// Delete a group: first clears `group_id` on every member (locally and on
  /// the server) so no passenger row dangles a reference to a deleted group,
  /// then deletes the group row itself.
  Future<void> deleteGroup(String tourId, String groupId) async {
    final tour = getTour(tourId);
    if (tour == null) return;

    final members = tour.passengers.where((p) => p.groupId == groupId).toList();

    await _write(
      // Optimistic local update: clear members, drop the group row.
      optimistic: () => _updateTourLocal(tourId, (t) {
        final nextPassengers = t.passengers
            .map((p) => p.groupId == groupId ? _passengerWithGroup(p, null) : p)
            .toList();
        final nextGroups = t.groups.where((g) => g.id != groupId).toList();
        return t.copyWith(passengers: nextPassengers, groups: nextGroups);
      }),
      persist: () async {
        for (final p in members) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: _passengerWithGroup(p, null).toMap(),
          );
        }
        await _sync.smartDelete(table: 'passenger_groups', entityId: groupId);
      },
      failure: tr('errors.delete_group'),
    );
  }

  /// Rebuild [Passenger] with an explicit (possibly null) group id.
  ///
  /// Routed through [Passenger.copyWith] + its `clearGroup` escape, NOT a
  /// hand-rolled full constructor. The old rebuild listed every field by hand
  /// and so silently dropped each one added after it was written — pickup
  /// location, cancelledAt, cancelRequestedAt and seatsNotifiedSig were all
  /// being nulled. Since the result is persisted via `toMap()`, that wasn't a
  /// local-only glitch: (un)grouping a passenger WIPED those columns on the
  /// server (resurrecting cancelled riders, losing their pickup point, and
  /// falsely flagging seats as changed-since-notified). copyWith can never
  /// drop a field, so this cannot rot again.
  Passenger _passengerWithGroup(Passenger p, String? groupId) =>
      p.copyWith(groupId: groupId, clearGroup: groupId == null);
}
