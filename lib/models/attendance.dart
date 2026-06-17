import 'package:uuid/uuid.dart';

/// Which leg of a tour an attendance mark belongs to.
enum AttendanceLeg {
  go,
  ret;

  /// Storage key — must stay stable; DB column uses these strings.
  String get storageKey => name;

  static AttendanceLeg fromString(String? value) {
    if (value == null) return AttendanceLeg.go;
    return AttendanceLeg.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AttendanceLeg.go,
    );
  }
}

/// Whether a passenger boarded a specific bus on a given leg.
///
/// Defaults to [present] = true (everyone assumed boarded); the handler
/// flips passengers who were left behind. One row per passenger/bus/leg.
class Attendance {
  final String id;
  final String tourId;
  final String busId;
  final String passengerId;
  final AttendanceLeg leg;
  final bool present;
  final String? markedBy;
  final DateTime markedAt;
  final DateTime createdAt;

  Attendance({
    String? id,
    required this.tourId,
    required this.busId,
    required this.passengerId,
    this.leg = AttendanceLeg.go,
    this.present = true,
    this.markedBy,
    DateTime? markedAt,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       markedAt = markedAt ?? DateTime.now(),
       createdAt = createdAt ?? DateTime.now();

  // ── Postgres serialization ────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'bus_id': busId,
      'passenger_id': passengerId,
      'leg': leg.storageKey,
      'present': present,
      'marked_by': markedBy,
      'marked_at': markedAt.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Attendance.fromMap(Map<String, dynamic> map) {
    return Attendance(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      busId: (map['bus_id'] ?? '').toString(),
      passengerId: (map['passenger_id'] ?? '').toString(),
      leg: AttendanceLeg.fromString(map['leg'] as String?),
      present: map['present'] as bool? ?? true,
      markedBy: map['marked_by'] as String?,
      markedAt: _parseDate(map['marked_at']),
      createdAt: _parseDate(map['created_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  Attendance copyWith({bool? present, String? markedBy}) {
    return Attendance(
      id: id,
      tourId: tourId,
      busId: busId,
      passengerId: passengerId,
      leg: leg,
      present: present ?? this.present,
      markedBy: markedBy ?? this.markedBy,
      markedAt: DateTime.now(),
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Attendance && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
