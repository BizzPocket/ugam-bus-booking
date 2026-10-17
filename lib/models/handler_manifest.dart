import 'attendance.dart';
import 'bus_details.dart';
import 'collection.dart';
import 'expense.dart';
import 'income_entry.dart';
import 'passenger.dart';
import 'passenger_group.dart';
import 'seat_assignment.dart';

/// The full bus chart a tour handler sees: every bus on the tour plus every
/// passenger, so the handler can render an occupancy-aware seat grid.
///
/// Produced by the `handler_tour_manifest` RPC, which returns a single json
/// object `{buses: [...], passengers: [...], groups: [...], collections: [...],
/// expenses: [...], incomes: [...]}`. Only the tour handler is authorized to
/// receive it (see [CustomerRequestsStore.isRequestHandler]).
class HandlerManifest {
  final List<Bus> buses;
  final List<Passenger> passengers;
  final List<Collection> collections;

  /// Every expense logged against any bus on this tour. Surfaced so the handler
  /// can review the bus's running costs and reconcile cash on the ground.
  final List<Expense> expenses;

  /// Every income entry logged against any bus on this tour. Surfaced so the
  /// handler can review the bus's incoming money and reconcile cash on the
  /// ground.
  final List<IncomeEntry> incomes;

  /// Every attendance row logged against any bus on this tour. Surfaced so the
  /// handler can see who boarded each leg and reconcile the manifest on the
  /// ground.
  final List<Attendance> attendance;

  /// Agent-defined cross-booking groups for this tour (labels + stable colours).
  final List<PassengerGroup> groups;

  const HandlerManifest({
    this.buses = const [],
    this.passengers = const [],
    this.collections = const [],
    this.expenses = const [],
    this.incomes = const [],
    this.attendance = const [],
    this.groups = const [],
  });

  factory HandlerManifest.fromJson(Map<String, dynamic> json) {
    return HandlerManifest(
      buses: _parseList(json['buses'], Bus.fromMap),
      passengers: _parseList(json['passengers'], Passenger.fromMap),
      collections: _parseList(json['collections'], Collection.fromMap),
      expenses: _parseList(json['expenses'], Expense.fromMap),
      incomes: _parseList(json['incomes'], IncomeEntry.fromMap),
      attendance: _parseList(json['attendance'], Attendance.fromMap),
      groups: _parseList(json['groups'], PassengerGroup.fromMap),
    );
  }

  /// Parses one json array of the manifest: non-list input reads as empty
  /// (unmodifiable, like the `const []` it replaces), non-map elements are
  /// dropped.
  static List<T> _parseList<T>(
    dynamic value,
    T Function(Map<String, dynamic>) fromMap,
  ) {
    if (value is! List) return List<T>.unmodifiable(const []);
    return value
        .whereType<Map>()
        .map((m) => fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// The agent's label for [groupId], or null when unknown / ungrouped.
  String? groupLabel(String? groupId) {
    if (groupId == null || groupId.isEmpty) return null;
    for (final g in groups) {
      if (g.id == groupId) {
        final label = g.label.trim();
        return label.isEmpty ? null : label;
      }
    }
    return null;
  }

  /// The passenger occupying [seatId] on bus [busId], or null if the seat is
  /// free. Matches by bus AND seat so the same seat label on different buses
  /// stays distinct.
  Passenger? seatOccupant(String busId, String seatId) {
    final target = SeatAssignment(busId: busId, seatId: seatId);
    for (final passenger in passengers) {
      if (passenger.assignedSeats.contains(target)) return passenger;
    }
    return null;
  }

  /// The collection recorded for [passengerId] on bus [busId], or null if no
  /// money has been collected yet for that passenger on that bus.
  Collection? collectionFor(String passengerId, String busId, String seatId) {
    for (final collection in collections) {
      if (collection.passengerId == passengerId &&
          collection.busId == busId &&
          collection.seatId == seatId) {
        return collection;
      }
    }
    return null;
  }

  /// The attendance row recorded for [passengerId] on bus [busId] for [leg], or
  /// null if attendance hasn't been marked yet for that passenger on that leg.
  Attendance? attendanceFor(
    String passengerId,
    String busId,
    AttendanceLeg leg,
  ) {
    for (final row in attendance) {
      if (row.passengerId == passengerId &&
          row.busId == busId &&
          row.leg == leg) {
        return row;
      }
    }
    return null;
  }
}
