import 'bus_details.dart';
import 'seat_assignment.dart';

/// One passenger's seats on one tour, resolved by the `seat_lookup_by_phone`
/// RPC — the "Find my seat by phone" result. Unlike [CustomerRequestEntry] this
/// is NOT tied to a booking_request, so it surfaces seats for passengers the
/// agent added manually (who have no in-app ticket otherwise). Only ever built
/// for LOCKED / completed tours, so the seats here are final.
class SeatTicket {
  final String tourId;
  final String tourTitle;
  final String fromCity;
  final String toCity;
  final DateTime? departureDate;
  final String status;
  final String passengerName;

  /// The passenger's assigned seats (busId + seatId), already filtered to
  /// entries that carry a busId server-side.
  final List<SeatAssignment> assignedSeats;

  /// The bus diagram(s) this passenger has seats on — enough to render the
  /// layout with their own seats highlighted.
  final List<Bus> buses;

  const SeatTicket({
    required this.tourId,
    required this.tourTitle,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    required this.status,
    required this.passengerName,
    required this.assignedSeats,
    required this.buses,
  });

  /// The set of this passenger's seat ids on [busId].
  Set<String> seatIdsForBus(String busId) => assignedSeats
      .where((s) => s.busId == busId)
      .map((s) => s.seatId)
      .toSet();

  /// Distinct seat ids across all buses, sorted — for the summary chip.
  List<String> get seatIds {
    final ids = assignedSeats.map((s) => s.seatId).toSet().toList()..sort();
    return ids;
  }

  factory SeatTicket.fromJson(Map<String, dynamic> m) {
    return SeatTicket(
      tourId: (m['tour_id'] ?? '').toString(),
      tourTitle: (m['tour_title'] ?? '').toString(),
      fromCity: (m['from_city'] ?? '').toString(),
      toCity: (m['to_city'] ?? '').toString(),
      departureDate: m['departure_date'] != null
          ? DateTime.tryParse(m['departure_date'].toString())
          : null,
      status: (m['status'] ?? '').toString(),
      passengerName: (m['passenger_name'] ?? '').toString(),
      assignedSeats: _parseSeats(m['assigned_seats']),
      buses: _parseBuses(m['buses']),
    );
  }

  /// Decode the `assigned_seats` jsonb: a list of `{busId, seatId}` maps. Entries
  /// missing either key are dropped (they can't be drawn on a layout).
  static List<SeatAssignment> _parseSeats(dynamic value) {
    if (value is! List) return const [];
    final out = <SeatAssignment>[];
    for (final raw in value) {
      if (raw is Map) {
        final seatId = raw['seatId']?.toString();
        final busId = raw['busId']?.toString();
        if (seatId == null || busId == null) continue;
        out.add(SeatAssignment(busId: busId, seatId: seatId));
      }
    }
    return out;
  }

  static List<Bus> _parseBuses(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Bus.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }
}
