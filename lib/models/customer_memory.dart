import 'priority_status.dart';

/// One row in `customer_memory` — the per-admin, phone-keyed memory of a
/// returning customer. About 80% of customers repeat across tours, but their
/// agent-set priority and group membership live ONLY inside per-tour
/// `passengers` rows, which cascade-delete with the tour. Before a tour is
/// deleted the app snapshots that into this table so a returning phone can be
/// auto-restored on the next tour.
///
/// The compound key is `(ownerId, phone)`. `phone` is always the 10-digit
/// normalised form (see `normalisePhone`); normalise before comparing.
///
/// [companions] is the union of phones this customer has shared a group with
/// across past tours — the "travels with" memory used to recreate a group in
/// one tap.
class CustomerMemory {
  final String id;
  final String ownerId;
  final String phone;
  final String name;
  final PriorityStatus priorityStatus;
  final String? priorityReason;
  final List<String> companions;
  final DateTime createdAt;
  final DateTime updatedAt;

  CustomerMemory({
    required this.id,
    required this.ownerId,
    required this.phone,
    this.name = '',
    this.priorityStatus = PriorityStatus.none,
    this.priorityReason,
    this.companions = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  factory CustomerMemory.fromMap(Map<String, dynamic> map) {
    return CustomerMemory(
      id: (map['id'] ?? '').toString(),
      ownerId: (map['owner_id'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      priorityStatus:
          PriorityStatus.fromString(map['priority_status'] as String?),
      priorityReason: map['priority_reason'] as String?,
      companions: _parseCompanions(map['companions']),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'owner_id': ownerId,
        'phone': phone,
        'name': name,
        'priority_status': priorityStatus.name,
        'priority_reason': priorityReason,
        'companions': companions,
      };

  CustomerMemory copyWith({
    String? name,
    PriorityStatus? priorityStatus,
    String? priorityReason,
    List<String>? companions,
  }) {
    return CustomerMemory(
      id: id,
      ownerId: ownerId,
      phone: phone,
      name: name ?? this.name,
      priorityStatus: priorityStatus ?? this.priorityStatus,
      priorityReason: priorityReason ?? this.priorityReason,
      companions: companions ?? this.companions,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  static List<String> _parseCompanions(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }
}
