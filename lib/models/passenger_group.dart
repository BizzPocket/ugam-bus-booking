import 'package:uuid/uuid.dart';

/// A named group of passengers (separate bookings) that must ride the SAME bus.
///
/// Created by the agent. Seats from ONE booking are already a single unit (one
/// [Passenger] row); a [PassengerGroup] links DIFFERENT passenger rows
/// (e.g. "A & C") so the seating engine keeps them on one bus and a move can
/// cascade to the whole group.
class PassengerGroup {
  final String id;
  final String tourId;
  final String label;

  /// Index into the UI palette used to colour this group's ring on seat tiles.
  final int colorIndex;

  final DateTime createdAt;

  PassengerGroup({
    String? id,
    required this.tourId,
    required this.label,
    this.colorIndex = 0,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'label': label,
      'color_index': colorIndex,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory PassengerGroup.fromMap(Map<String, dynamic> map) {
    return PassengerGroup(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      label: (map['label'] ?? '').toString(),
      colorIndex: (map['color_index'] as num?)?.toInt() ?? 0,
      createdAt: _parseDate(map['created_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  PassengerGroup copyWith({String? label, int? colorIndex}) {
    return PassengerGroup(
      id: id,
      tourId: tourId,
      label: label ?? this.label,
      colorIndex: colorIndex ?? this.colorIndex,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PassengerGroup && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
