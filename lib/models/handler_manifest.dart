import 'attendance.dart';
import 'bus_details.dart';
import 'collection.dart';
import 'expense.dart';
import 'passenger.dart';
import 'seat_assignment.dart';

/// The full bus chart a tour handler sees: every bus on the tour plus every
/// passenger, so the handler can render an occupancy-aware seat grid.
///
/// Produced by the `handler_tour_manifest` RPC, which returns a single json
/// object `{buses: [...], passengers: [...], collections: [...],
/// expenses: [...]}`. Only the tour handler is authorized to receive it (see
/// [CustomerRequestsStore.isRequestHandler]).
class HandlerManifest {
  final List<Bus> buses;
  final List<Passenger> passengers;
  final List<Collection> collections;

  /// Every expense logged against any bus on this tour. Surfaced so the handler
  /// can review the bus's running costs and reconcile cash on the ground.
  final List<Expense> expenses;

  /// Every attendance row logged against any bus on this tour. Surfaced so the
  /// handler can see who boarded each leg and reconcile the manifest on the
  /// ground.
  final List<Attendance> attendance;

  const HandlerManifest({
    this.buses = const [],
    this.passengers = const [],
    this.collections = const [],
    this.expenses = const [],
    this.attendance = const [],
  });

  factory HandlerManifest.fromJson(Map<String, dynamic> json) {
    return HandlerManifest(
      buses: _parseBuses(json['buses']),
      passengers: _parsePassengers(json['passengers']),
      collections: _parseCollections(json['collections']),
      expenses: _parseExpenses(json['expenses']),
      attendance: _parseAttendance(json['attendance']),
    );
  }

  static List<Bus> _parseBuses(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Bus.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  static List<Passenger> _parsePassengers(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Passenger.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  static List<Collection> _parseCollections(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Collection.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  static List<Expense> _parseExpenses(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Expense.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  static List<Attendance> _parseAttendance(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Attendance.fromMap(Map<String, dynamic>.from(m)))
        .toList();
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
