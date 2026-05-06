import 'seat_type.dart';

/// A single line in a passenger's seat request.
///
/// Example: "1 Double Sofa Lower" → `RequestLine(SeatType.doubleSofa, SeatPosition.lower, 1)`
/// Example: "2 Seater"            → `RequestLine(SeatType.seater, null, 2)`
class RequestLine {
  final SeatType seatType;
  final SeatPosition? position; // null for Seater
  final int qty;

  const RequestLine({required this.seatType, this.position, required this.qty});

  /// Human-readable label like "Double Sofa Lower ×2" or "Seater ×1".
  String get label => '${seatTypeLabel(seatType, position)} ×$qty';

  /// Short chip label like "DL×2" or "ST×1".
  String get shortLabel => '${seatIdPrefix(seatType, position)}×$qty';

  Map<String, dynamic> toMap() {
    return {'seatType': seatType.name, 'position': position?.name, 'qty': qty};
  }

  factory RequestLine.fromMap(Map<String, dynamic> map) {
    return RequestLine(
      seatType: SeatType.fromString(map['seatType'] as String),
      position: SeatPosition.fromString(map['position'] as String?),
      qty: (map['qty'] as num).toInt(),
    );
  }

  RequestLine copyWith({SeatType? seatType, SeatPosition? position, int? qty}) {
    return RequestLine(
      seatType: seatType ?? this.seatType,
      position: position ?? this.position,
      qty: qty ?? this.qty,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RequestLine &&
          other.seatType == seatType &&
          other.position == position &&
          other.qty == qty;

  @override
  int get hashCode => Object.hash(seatType, position, qty);
}
