import 'customer_requests_store.dart';

/// One row of `chart_hold_status_lookup` (migration 067): the live state of a
/// chart booking's SEAT HOLD.
///
/// Holds exist only on tours that collect an online advance. `chart_hold_seats`
/// (migration 064) writes a `seat_holds` row with a 5-minute TTL; the
/// `booking_requests` row is not created until `chart_finalize_hold` runs, once
/// the advance is confirmed. So for the whole pay window — and forever after,
/// if the customer never pays — the booking lookup legitimately returns nothing.
class ChartHoldSnapshot {
  final String requestId;

  /// `seat_holds.id` — what a late UPI claim is recorded against.
  final String? holdId;

  final String? busId;

  /// `pending` | `finalized` | `released` | `expired`, mirroring the CHECK
  /// constraint on `seat_holds.status`.
  final String status;

  final DateTime? expiresAt;
  final int berths;

  const ChartHoldSnapshot({
    required this.requestId,
    required this.status,
    this.holdId,
    this.busId,
    this.expiresAt,
    this.berths = 0,
  });

  factory ChartHoldSnapshot.fromMap(Map<String, dynamic> map) {
    final raw = map['expires_at'];
    return ChartHoldSnapshot(
      requestId: (map['request_id'] ?? '').toString(),
      holdId: map['hold_id']?.toString(),
      busId: map['bus_id']?.toString(),
      status: (map['status'] ?? '').toString(),
      expiresAt: raw == null ? null : DateTime.tryParse(raw.toString()),
      berths: (map['berths'] as num?)?.toInt() ?? 0,
    );
  }

  /// Whether this hold is still blocking seats at [now].
  ///
  /// A null [expiresAt] counts as EXPIRED, not as forever. A hold with no
  /// deadline would otherwise pin a customer's ticket to "held" permanently and
  /// leave them no way forward — failing closed is the safer read, because the
  /// server's own availability query filters on `expires_at > now()` and would
  /// already have released the seats.
  bool isActiveAt(DateTime now) {
    if (status != 'pending') return false;
    final until = expiresAt;
    if (until == null) return false;
    return until.isAfter(now);
  }
}

/// Which seats a hold is sitting on, and how many people that is.
class HoldSeatsSummary {
  final List<String> seatIds;
  final int berths;
  const HoldSeatsSummary({required this.seatIds, required this.berths});
}

/// Summarise the raw `seat_holds.seats` jsonb — `[{seatId, berths, …}]`.
///
/// `tour_pending_seat_holds` already returned this, but the organiser's holds
/// card rendered only a name and a phone. Faced with an unpaid hold they could
/// not see WHICH berths it was blocking, so "Pay later" was a decision made
/// blind. Berths are summed rather than counted, because one cell can be two
/// people — three whole doubles is six passengers, not three.
///
/// Defensive about shape: this crosses a jsonb boundary, and a malformed row
/// must degrade to an empty summary rather than take down the money board.
HoldSeatsSummary summariseHoldSeats(dynamic seats) {
  if (seats is! List) {
    return const HoldSeatsSummary(seatIds: [], berths: 0);
  }
  final ids = <String>[];
  var berths = 0;
  for (final raw in seats) {
    if (raw is! Map) continue;
    final id = raw['seatId']?.toString();
    if (id != null && id.isNotEmpty) ids.add(id);
    berths += (raw['berths'] as num?)?.toInt() ?? 1;
  }
  return HoldSeatsSummary(seatIds: ids, berths: berths);
}

/// Decide what a locally-stored request means when the server has NO
/// `booking_requests` row for it.
///
/// *** THE BUG THIS REPLACES ***
/// `CustomerRequestsStore.refresh()` treated an empty booking lookup as proof
/// the organiser had deleted the tour, and called `markCancelled()`. For the
/// advance path that is simply wrong: a live, seats-blocked, unpaid hold has no
/// booking row by design. A customer who held 6 berths and had not yet paid saw
/// their ticket read "Cancelled" while the chart still showed their seats gone.
///
/// Resolution order, most specific first:
///   1. hold is pending and unexpired  -> `held`    (+ countdown)
///   2. hold is finalized              -> unchanged (the booking row is landing)
///   3. hold exists but is dead        -> `expired` (re-bookable)
///   4. no hold at all                 -> `rejected` (genuine deletion)
CustomerRequestEntry resolveMissingBookingRow({
  required CustomerRequestEntry existing,
  required ChartHoldSnapshot? hold,
  required DateTime now,
}) {
  // Never resurrect a ticket the customer or organiser already killed.
  if (existing.status == 'rejected') return existing;

  if (hold != null) {
    if (hold.isActiveAt(now)) {
      return existing.copyWith(
        status: 'held',
        holdExpiresAt: hold.expiresAt,
        // Refresh the hold id from the server: a ticket restored from an older
        // app version, or from a device backup, may not have captured one.
        holdId: hold.holdId,
        lastRefreshedAt: now,
      );
    }

    // The hold already became a booking; the two lookups simply raced. Leaving
    // the entry alone lets the next refresh pick up the real booking row —
    // downgrading it here would flash a wrong status at the customer.
    if (hold.status == 'finalized') return existing;

    // Released, expired, or past its deadline: the seats are back on sale, so
    // the customer can book again. That is NOT the same as cancelled, which is
    // terminal.
    return existing.copyWith(
      status: 'expired',
      holdExpiresAt: hold.expiresAt,
      lastRefreshedAt: now,
    );
  }

  // No booking row AND no hold — the original, correct interpretation.
  return existing.markCancelled(at: now);
}
