import 'package:uuid/uuid.dart';

/// Record of cash handed over by a bus handler to the admin.
///
/// [expectedAmount] is what the handler was supposed to remit (typically
/// net collections minus on-route expenses); [handedOverAmount] is what
/// they actually gave. [shortfall] flags any gap.
class BusHandover {
  final String id;
  final String tourId;
  final String busId;
  final double expectedAmount;
  final double handedOverAmount;
  final String? note;
  final DateTime settledAt;
  final DateTime createdAt;

  /// Who logged this row — `'admin'` (the organiser's money screen) or
  /// `'handler'` (the handler's own bus chart). READ-ONLY on the client: it is
  /// stamped server-side by `handler_upsert_handover` and defaults to `'admin'`
  /// in Postgres, and it is deliberately absent from [toMap] so the admin's
  /// direct table write never sends a column the live schema might not have yet
  /// (PostgREST rejects the WHOLE payload on one unknown key). The handler UI
  /// reads it to keep admin-recorded settlements read-only.
  final String source;

  BusHandover({
    String? id,
    required this.tourId,
    required this.busId,
    this.expectedAmount = 0,
    this.handedOverAmount = 0,
    this.note,
    this.source = 'admin',
    DateTime? settledAt,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        settledAt = settledAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  /// +ve = handler still owes admin.
  double get shortfall => expectedAmount - handedOverAmount;

  /// Whether the handler logged this row themselves (and may therefore edit or
  /// delete it). Admin-recorded settlements stay read-only on the handler side.
  bool get byHandler => source == 'handler';

  // ── Postgres serialization ────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'bus_id': busId,
      'expected_amount': expectedAmount,
      'handed_over_amount': handedOverAmount,
      'note': note,
      'settled_at': settledAt.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory BusHandover.fromMap(Map<String, dynamic> map) {
    return BusHandover(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      busId: (map['bus_id'] ?? '').toString(),
      expectedAmount: (map['expected_amount'] as num?)?.toDouble() ?? 0,
      handedOverAmount: (map['handed_over_amount'] as num?)?.toDouble() ?? 0,
      note: map['note'] as String?,
      source: (map['source'] as String?)?.isNotEmpty == true
          ? map['source'] as String
          : 'admin',
      settledAt: _parseDate(map['settled_at']),
      createdAt: _parseDate(map['created_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  BusHandover copyWith({
    String? tourId,
    String? busId,
    double? expectedAmount,
    double? handedOverAmount,
    String? note,
    DateTime? settledAt,
  }) {
    return BusHandover(
      id: id,
      tourId: tourId ?? this.tourId,
      busId: busId ?? this.busId,
      expectedAmount: expectedAmount ?? this.expectedAmount,
      handedOverAmount: handedOverAmount ?? this.handedOverAmount,
      note: note ?? this.note,
      source: source,
      settledAt: settledAt ?? this.settledAt,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BusHandover && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
