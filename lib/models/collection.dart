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

  /// The slice of [amountReceived] that arrived ONLINE (a UPI advance), not as
  /// cash in the handler's pocket.
  ///
  /// Server-owned. `confirm_payment_claim` writes it, and 062's
  /// `finance_sync_collection` books exactly this slice to `bank.gateway`
  /// instead of `cash.handler`. The client reads it and never writes it — see
  /// the note in [toMap].
  final double amountOnline;

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
    this.amountOnline = 0,
    this.amountRefunded = 0,
    this.note,
    this.collectedBy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Everything received against this row, however it arrived, less refunds.
  ///
  /// This is the RIDER's position — what they have paid. It is NOT what the
  /// handler is holding; use [netCash] for that.
  double get netCollected => amountReceived - amountRefunded;

  /// CASH the handler is actually holding for this row.
  ///
  /// A UPI advance lands in the organiser's bank, never in the handler's
  /// pocket, so it must not appear in what the handler is asked to hand over.
  /// This mirrors the ledger exactly: `finance_bus_summary` (063) restricts
  /// `collected_minor` to `cash.handler` receipts and refunds, so any figure
  /// that drives a handover must subtract the online slice or the two disagree
  /// by precisely that amount — a cash dispute at the moment money changes
  /// hands.
  double get netCash => amountReceived - amountOnline - amountRefunded;

  /// Sub-rupee tolerance for money classification. Fractional dues (one-leg
  /// 0.5, sofa/2, bus/seats) can leave sub-rupee residuals in [balance]; without
  /// a tolerance a fully-paid rider stays "return due"/"owing" forever off a few
  /// paise. Anything inside ±[kMoneyEpsilon] rupees is treated as square.
  static const double kMoneyEpsilon = 0.005;

  /// +ve = owe customer change; -ve = customer still owes.
  double get balance => amountReceived - amountRefunded - amountDue;

  bool get isReturnDue => balance > kMoneyEpsilon;
  bool get isShortfall => balance < -kMoneyEpsilon;
  bool get isSquare => balance.abs() < kMoneyEpsilon;

  double get changeToReturn => isSquare ? 0 : (balance > 0 ? balance : 0);
  double get stillToCollect => isSquare ? 0 : (balance < 0 ? -balance : 0);

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
      // amount_online is deliberately ABSENT. It is written only by
      // confirm_payment_claim; a client PATCH carrying a stale value (or the
      // 0 default on a row the client has never refreshed) would silently
      // re-book an online advance as handler cash. Reading it is safe, echoing
      // it back is not.
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
      amountOnline: (map['amount_online'] as num?)?.toDouble() ?? 0,
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
    double? amountOnline,
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
      // Carried through so a local edit of cash or refunds cannot silently
      // reclassify an online advance as handler cash.
      amountOnline: amountOnline ?? this.amountOnline,
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
