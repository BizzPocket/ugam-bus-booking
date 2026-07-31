import '../utils/json_coerce.dart';
import 'seat_type.dart';
import 'trip_type.dart';

/// A single line in a passenger's seat request.
///
/// Example: "1 Double Sofa Lower" → `RequestLine(SeatType.doubleSofa, SeatPosition.lower, 1)`
/// Example: "2 Seater"            → `RequestLine(SeatType.seater, null, 2)`
///
/// The trip [leg] lives per line: one request can mix legs (e.g. 2 double-sofa
/// lines round-trip + 1 single-sofa line outbound-only), and the same seat type
/// may appear as multiple lines with different legs.
class RequestLine {
  final SeatType seatType;
  final SeatPosition? position; // null for Seater
  final int qty;

  /// Which legs of the tour this line travels on. Defaults to round-trip;
  /// legacy rows missing the key also fall back to round-trip via
  /// [TripType.fromString].
  final TripType leg;

  const RequestLine({
    required this.seatType,
    this.position,
    required this.qty,
    this.leg = TripType.roundTrip,
  });

  /// Human-readable label like "Double Sofa Lower ×2" or "Seater ×1".
  /// A non-round-trip leg is reflected with a concise suffix:
  /// outbound-only → " • GO", return-only → " • RET".
  String get label =>
      '${seatTypeLabel(seatType, position)} ×$qty$_legSuffix';

  /// Short chip label like "DL×2" or "ST×1". A non-round-trip leg adds a tight
  /// marker: outbound-only → "·GO", return-only → "·RET".
  String get shortLabel =>
      '${seatIdPrefix(seatType, position)}×$qty$_shortLegMarker';

  String get _legSuffix {
    switch (leg) {
      case TripType.outboundOnly:
        return ' • GO';
      case TripType.returnOnly:
        return ' • RET';
      case TripType.roundTrip:
        return '';
    }
  }

  String get _shortLegMarker {
    switch (leg) {
      case TripType.outboundOnly:
        return '·GO';
      case TripType.returnOnly:
        return '·RET';
      case TripType.roundTrip:
        return '';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'seatType': seatType.name,
      'position': position?.name,
      'qty': qty,
      'leg': leg.storageKey,
    };
  }

  /// [fallbackLeg] is used ONLY when the stored map has no explicit `leg` key —
  /// i.e. legacy rows written before the per-line leg existed, whose leg lived
  /// on the passenger's `trip_type`. New rows always serialize an explicit
  /// `leg`, so the fallback never overrides real per-line data.
  factory RequestLine.fromMap(
    Map<String, dynamic> map, {
    TripType fallbackLeg = TripType.roundTrip,
  }) {
    // Coerced, not cast: this parses an element of the `request_lines` JSONB
    // array, and Postgres type-checks nothing inside jsonb. A throw here would
    // propagate out of Passenger.fromMap and fail the entire roster load.
    //
    // An unparseable qty becomes 0 rather than a guess: the line stays visible
    // on the roster but contributes no demand, so a corrupt row can never
    // silently inflate capacity. Negatives are clamped for the same reason.
    final qty = coerceInt(map['qty']);
    return RequestLine(
      seatType: SeatType.fromString(coerceString(map['seatType']) ?? ''),
      position: SeatPosition.fromString(coerceString(map['position'])),
      qty: qty < 0 ? 0 : qty,
      leg: map.containsKey('leg')
          ? TripType.fromString(coerceString(map['leg']))
          : fallbackLeg,
    );
  }

  RequestLine copyWith({
    SeatType? seatType,
    SeatPosition? position,
    int? qty,
    TripType? leg,
  }) {
    return RequestLine(
      seatType: seatType ?? this.seatType,
      position: position ?? this.position,
      qty: qty ?? this.qty,
      leg: leg ?? this.leg,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RequestLine &&
          other.seatType == seatType &&
          other.position == position &&
          other.qty == qty &&
          other.leg == leg;

  @override
  int get hashCode => Object.hash(seatType, position, qty, leg);
}
