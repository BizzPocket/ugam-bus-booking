import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'bus_type.dart';
import 'seat_layout.dart';
import 'seat_type.dart';
import 'passenger.dart';
import 'trip_type.dart';

/// A named, flexible price band covering a contiguous range of rows.
///
/// Generalises the old single "rear zone" into any number of named tiers — a
/// premium front band, a discounted back band, or any explicit row range. The
/// [price] is PER BERTH (per person), exactly like the legacy `rear_price`, so a
/// whole double sofa sitting inside a band costs 2 × [price].
///
/// Rows are 0-based and INCLUSIVE: a band with `fromRow: 0, toRow: 1` covers the
/// first two rows. Bands take precedence over the per-seat-type overrides for the
/// rows they cover (matching the old rear-zone-wins rule). When two bands overlap
/// a row, the FIRST band in the list wins, so callers should order them by intent.
class PriceBand {
  final String label;
  final int fromRow; // inclusive, 0-based
  final int toRow; // inclusive, 0-based
  final double price; // per berth / per person

  const PriceBand({
    required this.label,
    required this.fromRow,
    required this.toRow,
    required this.price,
  });

  /// True when [row] falls inside this band (inclusive on both ends). The
  /// bounds are normalised so a band entered "backwards" (toRow < fromRow)
  /// still matches the intended range.
  bool covers(int row) {
    final lo = fromRow <= toRow ? fromRow : toRow;
    final hi = fromRow <= toRow ? toRow : fromRow;
    return row >= lo && row <= hi;
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'fromRow': fromRow,
        'toRow': toRow,
        'price': price,
      };

  factory PriceBand.fromMap(Map<String, dynamic> map) => PriceBand(
        label: (map['label'] ?? '').toString(),
        fromRow: (map['fromRow'] as num?)?.toInt() ?? 0,
        toRow: (map['toRow'] as num?)?.toInt() ?? 0,
        price: (map['price'] as num?)?.toDouble() ?? 0,
      );

  PriceBand copyWith({
    String? label,
    int? fromRow,
    int? toRow,
    double? price,
  }) =>
      PriceBand(
        label: label ?? this.label,
        fromRow: fromRow ?? this.fromRow,
        toRow: toRow ?? this.toRow,
        price: price ?? this.price,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PriceBand &&
          other.label == label &&
          other.fromRow == fromRow &&
          other.toRow == toRow &&
          other.price == price;

  @override
  int get hashCode => Object.hash(label, fromRow, toRow, price);
}

/// A bus in the admin's fleet (per-admin, not per-tour).
///
/// The agent enters details when the bus owner provides them.
class Bus {
  final String id;
  final String? ownerId;

  /// Tour this bus is assigned to. Set when an agent adds the bus to a
  /// specific tour via [TourController.addBus]. Nullable so a bus can
  /// exist in the fleet without yet being assigned to a tour.
  final String? tourId;

  /// The passenger who handles THIS bus (per-bus handler). Set via
  /// [TourController.setBusHandler]; cleared via [TourController.removeBusHandler].
  /// Nullable so a bus can exist without a handler assigned yet. A per-bus
  /// handler later sees ONLY their own bus(es).
  final String? handlerPassengerId;

  final String name; // "Bus 1", "Bus 2", …
  final String busNumber; // GJ05HU7162
  final String driverName;
  final String driverPhone;
  final String? ownerName;
  final String? ownerPhone;
  final bool isAC;
  final String busType;
  final int totalSeatsLegacy; // legacy field — prefer layout.totalSeats

  /// Per-seat price for this bus. Overrides the tour-level price.
  /// Defaults to 0; agents may set it when adding the bus.
  final double pricePerSeat;

  /// Full rent paid to the bus owner for this bus. Auto-counted as a
  /// `busOwner` expense in the money summaries (single source of truth — it is
  /// NOT a DB expense row), so the handler can never add it manually.
  /// Defaults to 0; agents set it when adding the bus.
  final double busPrice;

  /// Per-bus departure place / venue. Overrides the tour-level boarding place
  /// wherever boarding is shown (esp. the PDF footer). Defaults to ''.
  final String boardingPoint;

  /// Per-bus departure time, canonical 'HH:mm' (mirrors [Tour.departureTime]).
  /// Overrides the tour-level / chart-footer departure time wherever boarding
  /// is shown. Nullable; null/'' means no per-bus time set.
  final String? departureTime;

  /// Optional per-seat-type overrides for the FRONT (non-rear) rows. Each falls
  /// back to [pricePerSeat] when null. [doubleSofaPrice] is the WHOLE double-sofa
  /// price (covers both berths), so one berth is half of it.
  final double? singleSofaPrice;
  final double? doubleSofaPrice;
  final double? seaterPrice;

  /// Rear-zone pricing. The last [rearRows] rows of the layout form a "rear zone"
  /// priced at [rearPrice] PER PERSON (a whole double sofa there = 2 × rearPrice).
  /// [rearRows] == 0 (or a null [rearPrice]) means no rear zone — every row uses
  /// the base/override pricing. The rear zone takes precedence over per-type
  /// overrides for the rows it covers.
  ///
  /// Kept for back-compat. New code should use [priceBands]; the rear zone is
  /// surfaced to the pricing engine as a synthesized trailing band via
  /// [effectiveBands] so both paths behave identically.
  final int rearRows;
  final double? rearPrice;

  /// Flexible, named price bands (front premium, back discount, or any explicit
  /// row range). Each band's price is per berth. Bands win over per-type
  /// overrides for the rows they cover; the FIRST matching band wins on overlap.
  /// See [PriceBand] and [berthPriceFor].
  final List<PriceBand> priceBands;

  final String? notes;
  final BusLayout? layout;
  final DateTime createdAt;
  final DateTime updatedAt;

  Bus({
    String? id,
    this.ownerId,
    this.tourId,
    this.handlerPassengerId,
    required this.name,
    this.busNumber = '',
    this.driverName = '',
    this.driverPhone = '',
    this.ownerName,
    this.ownerPhone,
    this.isAC = false,
    this.busType = 'Semi-Sleeper',
    this.totalSeatsLegacy = 0,
    this.pricePerSeat = 0,
    this.busPrice = 0,
    this.boardingPoint = '',
    this.departureTime,
    this.singleSofaPrice,
    this.doubleSofaPrice,
    this.seaterPrice,
    this.rearRows = 0,
    this.rearPrice,
    this.priceBands = const [],
    this.notes,
    this.layout,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Human-facing label for this bus: the NAME leads, with the registration
  /// number appended as a secondary detail when present — e.g.
  /// `"Bus 1 · GJ05LE9510"`. Falls back to just the name when no registration
  /// has been entered. This is the single source of truth for every place that
  /// shows a bus as a title/identifier, so the convention can't drift per screen.
  String get displayLabel {
    final reg = busNumber.trim();
    return reg.isEmpty ? name : '$name · $reg';
  }

  /// Customer-facing bus label — the NAME only, never the registration number.
  /// The plate is an operational detail the agent needs to identify the physical
  /// vehicle ([displayLabel]); customers just need the name (e.g. "Raj"). This is
  /// the single source for every customer surface (WhatsApp confirmation, their
  /// seat-chart image, Find-my-seat, customer tour detail), so the convention
  /// can't drift per screen the way a hand-rolled "name only" would.
  String get customerLabel => name.trim().isEmpty ? displayLabel : name.trim();

  /// Parsed bus type enum. The underlying `busType` string is kept on the
  /// Appwrite document for forward compatibility with arbitrary type names
  /// the agent may have used previously (e.g. "Semi-Sleeper").
  BusType get busTypeEnum {
    final lower = busType.toLowerCase();
    if (lower.contains('seater')) return BusType.seater;
    if (lower.contains('mixed')) return BusType.mixed;
    return BusType.sleeper;
  }

  /// Total seats — prefers the visual layout, falls back to the legacy count.
  int get totalSeats => layout?.totalSeats ?? totalSeatsLegacy;

  /// All seat IDs from the layout.
  List<String> get allSeatIds => layout?.allSeatIds ?? [];

  /// Seat counts by prefix (e.g. {"DL": 8, "DU": 8, "SL": 4, "SU": 4, "ST": 6}).
  Map<String, int> get seatCounts => layout?.seatCounts ?? {};

  // ── Postgres serialization ────────────────────────────────

  /// Column map for a column-scoped UPDATE (see `SyncService.updatePatch`).
  ///
  /// Identical to [toMap] except `layout` is present ONLY when [includeLayout]
  /// is true, and the caller — not this model — decides that.
  ///
  /// `layout` is fetched LAZILY: cold start omits the jsonb because it is ~71%
  /// of bus bytes on a 2G link, so an in-memory bus routinely holds
  /// `layout == null` for a bus that has a perfectly good seat grid on the
  /// server. A write that carried that null erased the grid — the bug that cost
  /// two live seat charts. An ABSENT key leaves the column alone; a null key
  /// destroys it, so the distinction here is load-bearing.
  ///
  /// Pass `includeLayout: true` only when this operation actually built a new
  /// layout. Never derive it from `layout != null`: that is precisely the
  /// inference that fails, because an unloaded layout and a deliberately-cleared
  /// one are indistinguishable in memory.
  Map<String, dynamic> toPatch({required bool includeLayout}) {
    final patch = toMap();
    if (!includeLayout) patch.remove('layout');
    return patch;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'owner_id': ownerId,
      'tour_id': tourId,
      'handler_passenger_id': handlerPassengerId,
      'name': name,
      // Empty registration must be NULL, not ''. The partial unique index
      // `buses(owner_id, registration_no) where registration_no is not null`
      // treats '' as a real value, so two unfilled buses on the same tour
      // collide unless we send NULL.
      'registration_no': busNumber.isEmpty ? null : busNumber,
      'driver_name': driverName,
      'driver_phone': driverPhone,
      'owner_name': ownerName,
      'owner_phone': ownerPhone,
      'is_ac': isAC,
      'bus_type': busType,
      'total_seats': totalSeatsLegacy,
      'price_per_seat': pricePerSeat,
      'bus_price': busPrice,
      'boarding_point': boardingPoint,
      'departure_time': departureTime,
      'single_sofa_price': singleSofaPrice,
      'double_sofa_price': doubleSofaPrice,
      'seater_price': seaterPrice,
      'rear_rows': rearRows,
      'rear_price': rearPrice,
      'price_bands': priceBands.map((b) => b.toMap()).toList(),
      'notes': notes,
      'layout': layout?.toMap(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Bus.fromMap(Map<String, dynamic> map) {
    return Bus(
      id: ((map['id']) as String?) ?? const Uuid().v4(),
      ownerId: map['owner_id'] as String?,
      tourId: map['tour_id'] as String?,
      handlerPassengerId: map['handler_passenger_id'] as String?,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? map['name'] as String
          : 'Bus',
      busNumber: (map['registration_no'] ?? '').toString(),
      driverName: (map['driver_name'] ?? '').toString(),
      driverPhone: (map['driver_phone'] ?? '').toString(),
      ownerName: map['owner_name'] as String?,
      ownerPhone: map['owner_phone'] as String?,
      isAC: map['is_ac'] as bool? ?? false,
      busType: map['bus_type'] as String? ?? 'Semi-Sleeper',
      totalSeatsLegacy: map['total_seats'] as int? ?? 0,
      pricePerSeat: (map['price_per_seat'] as num?)?.toDouble() ?? 0,
      busPrice: (map['bus_price'] as num?)?.toDouble() ?? 0,
      boardingPoint: (map['boarding_point'] ?? '').toString(),
      departureTime: (map['departure_time'] as String?)?.isNotEmpty == true
          ? map['departure_time'] as String
          : null,
      singleSofaPrice: (map['single_sofa_price'] as num?)?.toDouble(),
      doubleSofaPrice: (map['double_sofa_price'] as num?)?.toDouble(),
      seaterPrice: (map['seater_price'] as num?)?.toDouble(),
      rearRows: (map['rear_rows'] as num?)?.toInt() ?? 0,
      rearPrice: (map['rear_price'] as num?)?.toDouble(),
      priceBands: _parsePriceBands(map['price_bands']),
      notes: map['notes'] as String?,
      layout: _parseLayout(map['layout']),
      createdAt: _parseDate(map['created_at']),
      updatedAt: _parseDate(map['updated_at']),
    );
  }

  /// Parse the `price_bands` jsonb column. Accepts a decoded List, a JSON
  /// string (when the driver hands jsonb back as text), or null/anything else
  /// (→ empty). Malformed entries are skipped so one bad row can't break load.
  static List<PriceBand> _parsePriceBands(dynamic value) {
    dynamic decoded = value;
    if (decoded is String) {
      if (decoded.trim().isEmpty) return const [];
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return const [];
      }
    }
    if (decoded is! List) return const [];
    final bands = <PriceBand>[];
    for (final e in decoded) {
      if (e is Map) {
        try {
          bands.add(PriceBand.fromMap(Map<String, dynamic>.from(e)));
        } catch (_) {
          // skip malformed band
        }
      }
    }
    return bands;
  }

  static BusLayout? _parseLayout(dynamic value) {
    if (value == null) return null;
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return BusLayout.fromMap(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        return null;
      }
    }
    if (value is Map) {
      return BusLayout.fromMap(Map<String, dynamic>.from(value));
    }
    return null;
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  Bus copyWith({
    String? ownerId,
    String? tourId,
    String? handlerPassengerId,
    String? name,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? ownerName,
    String? ownerPhone,
    bool? isAC,
    String? busType,
    int? totalSeatsLegacy,
    double? pricePerSeat,
    double? busPrice,
    String? boardingPoint,
    String? departureTime,
    double? singleSofaPrice,
    double? doubleSofaPrice,
    double? seaterPrice,
    int? rearRows,
    double? rearPrice,
    List<PriceBand>? priceBands,
    String? notes,
    BusLayout? layout,
  }) {
    return Bus(
      id: id,
      ownerId: ownerId ?? this.ownerId,
      tourId: tourId ?? this.tourId,
      handlerPassengerId: handlerPassengerId ?? this.handlerPassengerId,
      name: name ?? this.name,
      busNumber: busNumber ?? this.busNumber,
      driverName: driverName ?? this.driverName,
      driverPhone: driverPhone ?? this.driverPhone,
      ownerName: ownerName ?? this.ownerName,
      ownerPhone: ownerPhone ?? this.ownerPhone,
      isAC: isAC ?? this.isAC,
      busType: busType ?? this.busType,
      totalSeatsLegacy: totalSeatsLegacy ?? this.totalSeatsLegacy,
      pricePerSeat: pricePerSeat ?? this.pricePerSeat,
      busPrice: busPrice ?? this.busPrice,
      boardingPoint: boardingPoint ?? this.boardingPoint,
      departureTime: departureTime ?? this.departureTime,
      singleSofaPrice: singleSofaPrice ?? this.singleSofaPrice,
      doubleSofaPrice: doubleSofaPrice ?? this.doubleSofaPrice,
      seaterPrice: seaterPrice ?? this.seaterPrice,
      rearRows: rearRows ?? this.rearRows,
      rearPrice: rearPrice ?? this.rearPrice,
      priceBands: priceBands ?? this.priceBands,
      notes: notes ?? this.notes,
      layout: layout ?? this.layout,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  // ── Fare calculation ──────────────────────────────────────

  /// The bands the pricing engine actually consults, in precedence order.
  ///
  /// The explicit [priceBands] come first (FIRST match wins), then the legacy
  /// rear zone is appended as a synthesized trailing band so old buses that only
  /// set [rearRows]/[rearPrice] keep pricing exactly as before. When both are
  /// configured the explicit bands take priority for any rows they cover.
  List<PriceBand> get effectiveBands {
    final l = layout;
    final out = <PriceBand>[...priceBands];
    if (l != null && rearRows > 0 && rearPrice != null) {
      final from = (l.rows - rearRows).clamp(0, l.rows - 1);
      out.add(PriceBand(
        label: 'Rear',
        fromRow: from,
        toRow: l.rows - 1,
        price: rearPrice!,
      ));
    }
    return out;
  }

  /// The first effective band covering [row], or null when no band applies.
  PriceBand? bandForRow(int row) {
    for (final b in effectiveBands) {
      if (b.covers(row)) return b;
    }
    return null;
  }

  /// Index of the first effective band covering [row] within [effectiveBands]
  /// (precedence order), or null when no band applies. Drives the stable
  /// per-band colour on the handler chart so a row's wash and the band key
  /// agree — see `priceBandColor`.
  int? bandIndexForRow(int row) {
    final bands = effectiveBands;
    for (var i = 0; i < bands.length; i++) {
      if (bands[i].covers(row)) return i;
    }
    return null;
  }

  /// Per-person (per-berth) price for a seat of [type] sitting in [row], BEFORE
  /// the trip-type factor. Pricing is per person and driven by row position:
  ///
  ///   1. Price band — when [row] is covered by an [effectiveBands] entry, every
  ///      berth there costs that band's per-person price regardless of seat type
  ///      (so a WHOLE double sofa inside a band = 2 × band price). Bands win over
  ///      per-type overrides for the rows they cover; the legacy rear zone is one
  ///      such band (see [effectiveBands]).
  ///   2. Front / unbanded rows — a per-type override when set, otherwise
  ///      [pricePerSeat]. [doubleSofaPrice] is the WHOLE-sofa override, so one
  ///      berth is half of it; with no override a double berth is the full
  ///      per-person base price (a whole double sofa therefore costs
  ///      2 × [pricePerSeat]).
  double berthPriceFor(SeatType type, int row) {
    final band = bandForRow(row);
    if (band != null) return band.price;
    switch (type) {
      case SeatType.singleSofa:
        return singleSofaPrice ?? pricePerSeat;
      case SeatType.doubleSofa:
        return doubleSofaPrice != null ? doubleSofaPrice! / 2 : pricePerSeat;
      case SeatType.seater:
        return seaterPrice ?? pricePerSeat;
    }
  }

  /// Round trip pays full; a single leg (outbound-only / return-only) pays half.
  static double tripFactor(TripType t) => t == TripType.roundTrip ? 1.0 : 0.5;

  /// The CHEAPEST claimable berth on this bus for [leg] — the "from ₹X" figure.
  ///
  /// Scans the real, unreserved cells and prices each through [berthPriceFor],
  /// so a banded bus quotes its cheapest band and never promises the dearest
  /// berth. Returns null when the bus has no layout or no sellable seat, which
  /// callers MUST treat as "no price to show" rather than as ₹0 — a tour whose
  /// buses aren't priced yet must show nothing, not "from ₹0".
  ///
  /// Shared on purpose: the seat picker's leg pills and the public tour page
  /// both read this, so the number a customer sees before they tap can never
  /// disagree with the one they see after.
  double? fromBerthPrice(TripType leg) {
    final l = layout;
    if (l == null) return null;
    double? min;
    for (final c in l.grid) {
      if (!c.hasSeat || c.reserved || c.seatType == null) continue;
      final p = berthPriceFor(c.seatType!, c.row) * tripFactor(leg);
      if (min == null || p < min) min = p;
    }
    // A layout full of unpriced seats resolves to 0.0, which is a real answer
    // ("free") only in theory — in practice it means the agent hasn't set the
    // price yet, so report "unknown" and let the caller hide the row.
    if (min == null || min <= 0) return null;
    return min;
  }

  /// Index of every seat cell on this bus by its seat ID (only real seats).
  Map<String, SeatCell> _cellsById() {
    final cellById = <String, SeatCell>{};
    final l = layout;
    if (l == null) return cellById;
    for (final c in l.grid) {
      final sid = c.seatId;
      if (sid != null && c.seatType != null) cellById[sid] = c;
    }
    return cellById;
  }

  /// Total a passenger owes for the berths they hold ON THIS bus, after the
  /// trip-type factor.
  ///
  /// Each assignment entry is one berth, so a WHOLE double sofa (two entries on
  /// the same seatId held by this passenger) naturally sums to the full sofa
  /// price (2 × the per-berth band/override price), while a SHARED double (one
  /// entry) is half. Summing per entry keeps both cases correct.
  double amountDueFor(Passenger passenger) {
    final cellById = _cellsById();
    if (cellById.isEmpty) return 0;
    // Sum the rounded PER-SEAT dues over the DISTINCT seats this passenger holds
    // on this bus (a whole double sofa is two assignment entries on one seatId —
    // one collection record). Delegating to [amountDueForSeat] guarantees the
    // whole-passenger total equals the sum of its per-seat collection records, so
    // rounding each seat to whole rupees can never introduce a ₹1 mismatch.
    final seen = <String>{};
    double sum = 0;
    for (final a in passenger.assignedSeats) {
      if (a.busId != id) continue;
      final base = a.seatId.split('#').first;
      if (cellById[base] == null) continue;
      if (!seen.add(base)) continue;
      sum += amountDueForSeat(passenger, base);
    }
    return sum;
  }

  /// Amount due for one DISTINCT seat held by [passenger] on this bus, after the
  /// trip factor. This is the per-collection-record amount — collections are
  /// keyed `(passenger, bus, seat)`, so a whole double sofa is ONE record that
  /// must carry the FULL sofa price.
  ///
  /// WHOLE-SOFA FIX: when [passenger] holds BOTH berths of a double-sofa cell
  /// (two assignment entries on the same seatId → sole occupant), this returns
  /// the FULL double-sofa price (2 × the per-berth price). When they hold just
  /// one berth (a SHARED double) it returns the single-berth (half) price. Every
  /// other seat type is always a single berth.
  double amountDueForSeat(Passenger passenger, String seatId) {
    final cellById = _cellsById();
    if (cellById.isEmpty) return 0;
    final baseSeatId = seatId.split('#').first;
    final c = cellById[baseSeatId];
    if (c == null) return 0;
    final berthPrice = berthPriceFor(c.seatType!, c.row);
    // Price EACH berth this passenger holds on the seat by its OWN stored leg,
    // then sum. A double sofa held in full is two entries on one seatId; a
    // shared/single is one. Reading the per-seat SeatAssignment.leg (half for a
    // one-way berth) mirrors the capacity engine (tour_capacity: a.leg ??
    // legForSeatType) — the coarse legForSeatType collapsed a mixed same-type
    // booking to the heavier (round-trip) leg and over-charged a genuinely
    // one-leg seat. Summing PER BERTH also prices a whole double whose two
    // berths carry different-weight legs correctly (round-trip + one-way =
    // 1.0 + 0.5), which berths × one-factor could not. Legacy berths with no
    // recorded leg fall back to the coarse per-type leg.
    final coarseLeg =
        passenger.legForSeatType(c.seatType!, position: c.position);
    final berthLegs = <TripType>[
      for (final a in passenger.assignedSeats)
        if (a.busId == id && a.seatId.split('#').first == baseSeatId)
          a.leg ?? coarseLeg,
    ];
    // A seat can be held on BOTH legs (leg reuse), so a rider can hold up to
    // (physical berths × 2 legs) one-leg berth-legs: a double = 2 berths × 2 =
    // FOUR (a GO double + a RET double folded onto one sofa — 2 GO + 2 RET), a
    // single/seater = TWO (1 GO + 1 RET). Summing them all prices a
    // fully-occupied-both-legs seat correctly (4 × half == 2 × full for a
    // double); the cap only guards against stray duplicate rows. An earlier cap
    // of 2 wrongly under-charged such a merged double at half.
    final maxBerthLegs = c.seatType!.berthsPerUnit * 2;
    final legs = berthLegs.isEmpty
        ? <TripType>[coarseLeg]
        : (berthLegs.length > maxBerthLegs
            ? berthLegs.sublist(0, maxBerthLegs)
            : berthLegs);
    var due = 0.0;
    for (final l in legs) {
      due += berthPrice * tripFactor(l);
    }
    // Round the FINAL per-seat due to whole rupees at source. Fractional inputs
    // (one-leg 0.5 factor, sofa/2, bus/seats) otherwise leave sub-rupee dues that
    // never square against integer cash. This is the single per-collection-record
    // amount, so rounding here keeps every stored due an integer.
    return due.roundToDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Bus && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
