import 'package:uuid/uuid.dart';

/// Money collected from a single passenger on a specific bus/tour.
///
/// Tracks what the passenger owed ([amountDue]), what cash was actually
/// taken in ([amountReceived]), and any cash given back ([amountRefunded]).
/// The derived [balance] tells the handler whether change is owed to the
/// customer or the customer still owes money.
class Collection {
  static const Object _unset = Object();

  final String id;
  final String tourId;
  final String busId;
  final String passengerId;
  final String seatId;
  final double amountDue;
  final double amountReceived;
  final double amountRefunded;
  final String? note;
  final String? collectedBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Collection({
    String? id,
    required this.tourId,
    required this.busId,
    required this.passengerId,
    this.seatId = '',
    this.amountDue = 0,
    this.amountReceived = 0,
    this.amountRefunded = 0,
    this.note,
    this.collectedBy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Cash the collection actually holds.
  double get netCollected => amountReceived - amountRefunded;

  /// +ve = owe customer change; -ve = customer still owes.
  double get balance => amountReceived - amountRefunded - amountDue;

  bool get isReturnDue => balance > 0;
  bool get isShortfall => balance < 0;
  bool get isSquare => balance == 0;

  double get changeToReturn => balance > 0 ? balance : 0;
  double get stillToCollect => balance < 0 ? -balance : 0;

  // ── Postgres serialization ────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'bus_id': busId,
      'passenger_id': passengerId,
      'seat_id': seatId,
      'amount_due': amountDue,
      'amount_received': amountReceived,
      'amount_refunded': amountRefunded,
      'note': note,
      'collected_by': collectedBy,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Collection.fromMap(Map<String, dynamic> map) {
    return Collection(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      busId: (map['bus_id'] ?? '').toString(),
      passengerId: (map['passenger_id'] ?? '').toString(),
      seatId: (map['seat_id'] ?? '').toString(),
      amountDue: (map['amount_due'] as num?)?.toDouble() ?? 0,
      amountReceived: (map['amount_received'] as num?)?.toDouble() ?? 0,
      amountRefunded: (map['amount_refunded'] as num?)?.toDouble() ?? 0,
      note: map['note'] as String?,
      collectedBy: map['collected_by'] as String?,
      createdAt: _parseDate(map['created_at']),
      updatedAt: _parseDate(map['updated_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  Collection copyWith({
    String? tourId,
    String? busId,
    String? passengerId,
    String? seatId,
    double? amountDue,
    double? amountReceived,
    double? amountRefunded,
    Object? note = _unset,
    Object? collectedBy = _unset,
  }) {
    return Collection(
      id: id,
      tourId: tourId ?? this.tourId,
      busId: busId ?? this.busId,
      passengerId: passengerId ?? this.passengerId,
      seatId: seatId ?? this.seatId,
      amountDue: amountDue ?? this.amountDue,
      amountReceived: amountReceived ?? this.amountReceived,
      amountRefunded: amountRefunded ?? this.amountRefunded,
      note: identical(note, _unset) ? this.note : note as String?,
      collectedBy: identical(collectedBy, _unset)
          ? this.collectedBy
          : collectedBy as String?,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Collection && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
