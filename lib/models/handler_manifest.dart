import 'bus_details.dart';
import 'collection.dart';
import 'passenger.dart';
import 'seat_assignment.dart';

/// The full bus chart a tour handler sees: every bus on the tour plus every
/// passenger, so the handler can render an occupancy-aware seat grid.
///
/// Produced by the `handler_tour_manifest` RPC, which returns a single json
/// object `{buses: [...], passengers: [...]}`. Only the tour handler is
/// authorized to receive it (see [CustomerRequestsStore.isRequestHandler]).
class HandlerManifest {
  final List<Bus> buses;
  final List<Passenger> passengers;
  final List<Collection> collections;

  const HandlerManifest({
    this.buses = const [],
    this.passengers = const [],
    this.collections = const [],
  });

  factory HandlerManifest.fromJson(Map<String, dynamic> json) {
    return HandlerManifest(
      buses: _parseBuses(json['buses']),
      passengers: _parsePassengers(json['passengers']),
      collections: _parseCollections(json['collections']),
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
}
