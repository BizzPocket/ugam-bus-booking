part of 'seat_chart_booking_service.dart';

// Result / payload value types for [SeatChartBookingService]'s chart RPCs.

/// Outcome of a `chart_claim_seats` call.
///
/// A claim either wholly succeeds or wholly fails — there is no partial write.
/// [conflicts] names the seats that were lost (taken in the meantime, held back
/// by the organiser, or unknown), so the UI can point at them on the chart
/// instead of showing a generic error.
class ChartClaimResult {
  final bool ok;
  final String? requestId;
  final String? passengerId;
  final int berths;
  final List<String> conflicts;

  /// Set when the server refused outright (tour closed, bad leg, too many
  /// seats) rather than losing a race.
  final String? errorMessage;

  const ChartClaimResult({
    required this.ok,
    this.requestId,
    this.passengerId,
    this.berths = 0,
    this.conflicts = const [],
    this.errorMessage,
  });

  bool get lostSeats => !ok && conflicts.isNotEmpty;
}

/// One bus's share of a multi-bus checkout.
///
/// Each bus carries its OWN `requestId` because the server writes one
/// booking_request per bus — that is what keeps every passenger row's seats
/// inside a single bus and leaves billing, the manifest and the WhatsApp
/// ticket working unchanged.
class BusClaim {
  final String busId;
  final String requestId;
  final List<ChartPick> picks;

  const BusClaim({
    required this.busId,
    required this.requestId,
    required this.picks,
  });

  Map<String, dynamic> toPayload() => {
        'busId': busId,
        'requestId': requestId,
        'seats': claimPayload(picks),
      };
}

/// One bus's booking, as written by `chart_claim_seats_multi`.
class PartyBooking {
  final String busId;
  final String requestId;
  final String passengerId;
  final int berths;

  const PartyBooking({
    required this.busId,
    required this.requestId,
    required this.passengerId,
    this.berths = 0,
  });
}

/// A seat lost during a multi-bus claim, named WITH its bus — a bare seat id
/// would be ambiguous, since every sleeper on the tour has a "DU1".
class PartyConflict {
  final String busId;
  final String seatId;
  const PartyConflict({required this.busId, required this.seatId});
}

class ChartMultiClaimResult {
  final bool ok;
  final String? partyId;
  final List<PartyBooking> bookings;
  final List<PartyConflict> conflicts;
  final int berths;
  final String? errorMessage;

  const ChartMultiClaimResult({
    required this.ok,
    this.partyId,
    this.bookings = const [],
    this.conflicts = const [],
    this.berths = 0,
    this.errorMessage,
  });

  bool get lostSeats => !ok && conflicts.isNotEmpty;

  factory ChartMultiClaimResult.fromRpc(dynamic result) {
    if (result is! Map) return const ChartMultiClaimResult(ok: false);
    final map = Map<String, dynamic>.from(result);
    if (map['ok'] != true) {
      return ChartMultiClaimResult(
        ok: false,
        conflicts: _parseConflicts(map['conflicts']),
      );
    }
    return ChartMultiClaimResult(
      ok: true,
      partyId: map['party_id']?.toString(),
      berths: (map['berths'] as num?)?.toInt() ?? 0,
      bookings: [
        for (final row in (map['bookings'] as List? ?? const []))
          if (row is Map)
            PartyBooking(
              busId: row['bus_id']?.toString() ?? '',
              requestId: row['request_id']?.toString() ?? '',
              passengerId: row['passenger_id']?.toString() ?? '',
              berths: (row['berths'] as num?)?.toInt() ?? 0,
            ),
      ],
    );
  }
}

/// One bus's hold within a party hold.
class PartyHold {
  final String holdId;
  final String busId;
  final String requestId;

  const PartyHold({
    required this.holdId,
    required this.busId,
    required this.requestId,
  });
}

class ChartMultiHoldResult {
  final bool ok;
  final String? partyId;
  final List<PartyHold> holds;
  final List<PartyConflict> conflicts;

  /// One deadline for the WHOLE party — see migration 068.
  final DateTime? expiresAt;
  final int berths;
  final String? errorMessage;

  const ChartMultiHoldResult({
    required this.ok,
    this.partyId,
    this.holds = const [],
    this.conflicts = const [],
    this.expiresAt,
    this.berths = 0,
    this.errorMessage,
  });

  bool get lostSeats => !ok && conflicts.isNotEmpty;

  factory ChartMultiHoldResult.fromRpc(dynamic result) {
    if (result is! Map) return const ChartMultiHoldResult(ok: false);
    final map = Map<String, dynamic>.from(result);
    if (map['ok'] != true) {
      return ChartMultiHoldResult(
        ok: false,
        conflicts: _parseConflicts(map['conflicts']),
      );
    }
    return ChartMultiHoldResult(
      ok: true,
      partyId: map['party_id']?.toString(),
      berths: (map['berths'] as num?)?.toInt() ?? 0,
      expiresAt: map['expires_at'] == null
          ? null
          : DateTime.tryParse(map['expires_at'].toString()),
      holds: [
        for (final row in (map['holds'] as List? ?? const []))
          if (row is Map)
            PartyHold(
              holdId: row['hold_id']?.toString() ?? '',
              busId: row['bus_id']?.toString() ?? '',
              requestId: row['request_id']?.toString() ?? '',
            ),
      ],
    );
  }
}

List<PartyConflict> _parseConflicts(dynamic raw) => [
      for (final row in (raw as List? ?? const []))
        if (row is Map)
          PartyConflict(
            busId: row['bus_id']?.toString() ?? '',
            seatId: row['seat_id']?.toString() ?? '',
          ),
    ];

/// Outcome of `chart_hold_seats`.
class ChartHoldResult {
  final bool ok;
  final String? holdId;
  final String? requestId;
  final DateTime? expiresAt;
  final List<String> conflicts;
  final String? errorMessage;

  const ChartHoldResult({
    required this.ok,
    this.holdId,
    this.requestId,
    this.expiresAt,
    this.conflicts = const [],
    this.errorMessage,
  });

  bool get lostSeats => !ok && conflicts.isNotEmpty;
}
