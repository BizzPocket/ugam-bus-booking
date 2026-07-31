import 'dart:convert';

/// Which leg of the trip a seat chart belongs to.
///
/// [return_] carries a trailing underscore because `return` is a reserved Dart
/// keyword. The DB column `leg` stores the plain string `'outbound'`/`'return'`;
/// use [wire] / [fromWire] to cross that boundary.
enum SnapshotLeg {
  outbound,
  return_;

  /// DB / JSON string form of this leg (`'outbound'` or `'return'`).
  String get wire => this == SnapshotLeg.outbound ? 'outbound' : 'return';

  /// Parse the DB / JSON string form back into a [SnapshotLeg].
  /// Anything other than `'return'` is treated as outbound (defensive default).
  static SnapshotLeg fromWire(String s) =>
      s == 'return' ? SnapshotLeg.return_ : SnapshotLeg.outbound;
}

/// One occupant frozen at a single seat for one leg.
///
/// A seat cannot be double-booked within a leg, so this is a 1:1 seat→rider
/// record. [phone] is optional (some legacy/handler rows have no number).
class SnapshotSeat {
  final String seatId;
  final String name;
  final String? phone;

  const SnapshotSeat({
    required this.seatId,
    required this.name,
    this.phone,
  });

  Map<String, dynamic> toMap() {
    return {
      'seatId': seatId,
      'name': name,
      // Omit the key entirely when absent to keep the stored JSON tidy.
      if (phone != null) 'phone': phone,
    };
  }

  factory SnapshotSeat.fromMap(Map<String, dynamic> map) {
    return SnapshotSeat(
      seatId: (map['seatId'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      phone: map['phone'] as String?,
    );
  }
}

/// Every occupied seat on one bus for one leg.
///
/// Keyed by the live [busId] so the read screen can pair this frozen list back
/// to the preserved `Bus` layout record (a bus deleted after completion simply
/// has no matching layout and its section is skipped).
class SnapshotBus {
  final String busId;
  final List<SnapshotSeat> seats;

  const SnapshotBus({
    required this.busId,
    required this.seats,
  });

  /// The occupant frozen at [seatId] on this bus, or null if the seat was empty.
  /// Only the FIRST rider — use [occupantsAt] on any surface that must show a
  /// shared berth truthfully.
  SnapshotSeat? occupant(String seatId) {
    for (final s in seats) {
      if (s.seatId == seatId) return s;
    }
    return null;
  }

  /// EVERY rider frozen at [seatId] on this bus, in capture order (GO first).
  ///
  /// A Double Sofa is two berths, so one seatId can carry two DIFFERENT riders
  /// on the same leg. [occupant] returns only the first, which silently erased
  /// the second from the archived chart — the same "one rider per seat"
  /// assumption that blanked the printed chart. Read-only surfaces must use this.
  List<SnapshotSeat> occupantsAt(String seatId) =>
      [for (final s in seats) if (s.seatId == seatId) s];

  Map<String, dynamic> toMap() {
    return {
      'busId': busId,
      'seats': seats.map((s) => s.toMap()).toList(),
    };
  }

  factory SnapshotBus.fromMap(Map<String, dynamic> map) {
    final rawSeats = (map['seats'] as List?) ?? const [];
    return SnapshotBus(
      busId: (map['busId'] ?? '').toString(),
      seats: rawSeats
          .map((e) => SnapshotSeat.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

/// A frozen per-leg seat chart for a tour — the one piece of seat data that the
/// live editor destroys when it recycles GO seats for the return leg.
///
/// Persisted in `public.tour_seat_snapshots`: the row's `leg`/`captured_at`
/// columns map to [leg]/[capturedAt], and the JSON `snapshot_data` column holds
/// `{ "buses": [...] }` which maps to [buses].
class TourSeatSnapshot {
  final String tourId;
  final SnapshotLeg leg;
  final List<SnapshotBus> buses;
  final DateTime capturedAt;

  const TourSeatSnapshot({
    required this.tourId,
    required this.leg,
    required this.buses,
    required this.capturedAt,
  });

  // ── Postgres serialization ────────────────────────────────

  /// Build a model from a `tour_seat_snapshots` DB row.
  ///
  /// `snapshot_data` may arrive already-decoded as a `Map` (Supabase jsonb) or
  /// as a raw JSON `String`; both are handled. `captured_at` may be an ISO
  /// string or a `DateTime`.
  factory TourSeatSnapshot.fromMap(Map<String, dynamic> row) {
    final raw = row['snapshot_data'];
    final Map<String, dynamic> data = raw is String
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};

    final rawBuses = (data['buses'] as List?) ?? const [];

    return TourSeatSnapshot(
      tourId: (row['tour_id'] ?? '').toString(),
      leg: SnapshotLeg.fromWire((row['leg'] ?? 'outbound').toString()),
      buses: rawBuses
          .map((e) => SnapshotBus.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      capturedAt: _parseDate(row['captured_at']),
    );
  }

  /// Row map for upsert. `id` is omitted — the controller supplies the entity id
  /// separately (the unique `(tour_id, leg)` pair is the natural key).
  Map<String, dynamic> toMap() {
    return {
      'tour_id': tourId,
      'leg': leg.wire,
      'snapshot_data': {
        'buses': buses.map((b) => b.toMap()).toList(),
      },
      'captured_at': capturedAt.toIso8601String(),
    };
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }
}
