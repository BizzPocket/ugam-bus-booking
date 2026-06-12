import 'package:easy_localization/easy_localization.dart';
import 'package:uuid/uuid.dart';

/// Category of a tour/bus expense.
enum ExpenseCategory {
  driver,
  fuel,
  food,
  toll,
  busOwner,
  other;

  String get displayName {
    switch (this) {
      case ExpenseCategory.driver:
        return tr('enums.expense_category.driver');
      case ExpenseCategory.fuel:
        return tr('enums.expense_category.fuel');
      case ExpenseCategory.food:
        return tr('enums.expense_category.food');
      case ExpenseCategory.toll:
        return tr('enums.expense_category.toll');
      case ExpenseCategory.busOwner:
        return tr('enums.expense_category.busOwner');
      case ExpenseCategory.other:
        return tr('enums.expense_category.other');
    }
  }

  /// Parse from stored string; unknown values fall back to [other].
  static ExpenseCategory fromString(String? value) {
    return ExpenseCategory.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ExpenseCategory.other,
    );
  }
}

/// An expense logged against a specific bus on a tour.
class Expense {
  final String id;
  final String tourId;
  final String busId;
  final ExpenseCategory category;
  final String label;
  final double amount;
  final String? paidBy;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  Expense({
    String? id,
    required this.tourId,
    required this.busId,
    this.category = ExpenseCategory.other,
    required this.label,
    this.amount = 0,
    this.paidBy,
    this.note,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
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
      'paid_by': paidBy,
      'note': note,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Expense.fromMap(Map<String, dynamic> map) {
    return Expense(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      busId: (map['bus_id'] ?? '').toString(),
      category: ExpenseCategory.fromString(map['category'] as String?),
      label: (map['label'] ?? '').toString(),
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      paidBy: map['paid_by'] as String?,
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

  Expense copyWith({
    String? tourId,
    String? busId,
    ExpenseCategory? category,
    String? label,
    double? amount,
    String? paidBy,
    String? note,
  }) {
    return Expense(
      id: id,
      tourId: tourId ?? this.tourId,
      busId: busId ?? this.busId,
      category: category ?? this.category,
      label: label ?? this.label,
      amount: amount ?? this.amount,
      paidBy: paidBy ?? this.paidBy,
      note: note ?? this.note,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Expense && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
