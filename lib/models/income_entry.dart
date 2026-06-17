import 'package:easy_localization/easy_localization.dart';
import 'package:uuid/uuid.dart';

/// Category of a tour/bus income entry.
enum IncomeCategory {
  cabin,
  gallery,
  other;

  String get displayName {
    switch (this) {
      case IncomeCategory.cabin:
        return tr('enums.income_category.cabin');
      case IncomeCategory.gallery:
        return tr('enums.income_category.gallery');
      case IncomeCategory.other:
        return tr('enums.income_category.other');
    }
  }

  /// Parse from stored string; unknown values fall back to [other].
  static IncomeCategory fromString(String? value) {
    return IncomeCategory.values.firstWhere(
      (e) => e.name == value,
      orElse: () => IncomeCategory.other,
    );
  }
}

/// An income entry logged against a specific bus on a tour.
class IncomeEntry {
  final String id;
  final String tourId;
  final String busId;
  final IncomeCategory category;
  final String label;
  final double amount;
  final String? receivedBy;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  IncomeEntry({
    String? id,
    required this.tourId,
    required this.busId,
    this.category = IncomeCategory.other,
    required this.label,
    this.amount = 0,
    this.receivedBy,
    this.note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  // ── Postgres serialization ────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'bus_id': busId,
      'category': category.name,
      'label': label,
      'amount': amount,
      'received_by': receivedBy,
      'note': note,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory IncomeEntry.fromMap(Map<String, dynamic> map) {
    return IncomeEntry(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      busId: (map['bus_id'] ?? '').toString(),
      category: IncomeCategory.fromString(map['category'] as String?),
      label: (map['label'] ?? '').toString(),
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      receivedBy: map['received_by'] as String?,
      note: map['note'] as String?,
      createdAt: _parseDate(map['created_at']),
      updatedAt: _parseDate(map['updated_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  IncomeEntry copyWith({
    String? tourId,
    String? busId,
    IncomeCategory? category,
    String? label,
    double? amount,
    String? receivedBy,
    String? note,
  }) {
    return IncomeEntry(
      id: id,
      tourId: tourId ?? this.tourId,
      busId: busId ?? this.busId,
      category: category ?? this.category,
      label: label ?? this.label,
      amount: amount ?? this.amount,
      receivedBy: receivedBy ?? this.receivedBy,
      note: note ?? this.note,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is IncomeEntry && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
