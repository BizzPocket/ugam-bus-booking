import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'bus_type.dart';
import 'seat_layout.dart';

/// A bus booked for a specific tour.
///
/// Buses are NOT a global inventory — they exist only as children of a Tour.
/// The agent enters details when the bus owner provides them.
class Bus {
  final String id;
  final String tourId;
  final String name; // "Bus 1", "Bus 2", …
  final String busNumber; // GJ05HU7162
  final String driverName;
  final String driverPhone;
  final String? ownerName;
  final String? ownerPhone;
  final bool isAC;
  final String busType;
  final int totalSeatsLegacy; // legacy field — prefer layout.totalSeats
  final String? notes;
  final BusLayout? layout;
  final DateTime createdAt;
  final DateTime updatedAt;

  Bus({
    String? id,
    required this.tourId,
    required this.name,
    required this.busNumber,
    required this.driverName,
    this.driverPhone = '',
    this.ownerName,
    this.ownerPhone,
    this.isAC = false,
    this.busType = 'Semi-Sleeper',
    this.totalSeatsLegacy = 0,
    this.notes,
    this.layout,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Parsed bus type enum. The underlying `busType` string is kept on the
  /// Appwrite document for forward compatibility with arbitrary type names
  /// the agent may have used previously (e.g. "Semi-Sleeper").
  BusType get busTypeEnum {
    final lower = busType.toLowerCase();
    if (lower.contains('seater')) return BusType.seater;
    if (lower.contains('mixed')) return BusType.mixed;
    return BusType.sleeper;
  }

  /// Total seats — prefers the visual layout, falls back to the legacy count.
  int get totalSeats => layout?.totalSeats ?? totalSeatsLegacy;

  /// All seat IDs from the layout.
  List<String> get allSeatIds => layout?.allSeatIds ?? [];

  /// Seat counts by prefix (e.g. {"DL": 8, "DU": 8, "SL": 4, "SU": 4, "ST": 6}).
  Map<String, int> get seatCounts => layout?.seatCounts ?? {};

  // ── Appwrite serialization ────────────────────────────────

  Map<String, dynamic> toAppwrite() {
    return {
      'tourId': tourId,
      'name': name,
      'busNumber': busNumber,
      'driverName': driverName,
      'driverPhone': driverPhone,
      'ownerName': ownerName,
      'ownerPhone': ownerPhone,
      'isAC': isAC,
      'busType': busType,
      'totalSeats': totalSeatsLegacy,
      'notes': notes,
      'layout': layout != null ? jsonEncode(layout!.toMap()) : null,
    };
  }

  factory Bus.fromAppwrite(Map<String, dynamic> map) {
    return Bus(
      id: ((map[r'$id'] ?? map['id']) as String?) ?? const Uuid().v4(),
      tourId: map['tourId'] as String? ?? '',
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? map['name'] as String
          : 'Bus',
      busNumber: map['busNumber'] as String? ?? '',
      driverName: map['driverName'] as String? ?? '',
      driverPhone: map['driverPhone'] as String? ?? '',
      ownerName: map['ownerName'] as String?,
      ownerPhone: map['ownerPhone'] as String?,
      isAC: map['isAC'] as bool? ?? false,
      busType: map['busType'] as String? ?? 'Semi-Sleeper',
      totalSeatsLegacy: map['totalSeats'] as int? ?? 0,
      notes: map['notes'] as String?,
      layout: _parseLayout(map['layout']),
      createdAt: _parseDate(map[r'$createdAt'] ?? map['createdAt']),
      updatedAt: _parseDate(map[r'$updatedAt'] ?? map['updatedAt']),
    );
  }

  static BusLayout? _parseLayout(dynamic value) {
    if (value == null) return null;
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return BusLayout.fromMap(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        return null;
      }
    }
    if (value is Map) {
      return BusLayout.fromMap(Map<String, dynamic>.from(value));
    }
    return null;
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  Bus copyWith({
    String? name,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? ownerName,
    String? ownerPhone,
    bool? isAC,
    String? busType,
    int? totalSeatsLegacy,
    String? notes,
    BusLayout? layout,
  }) {
    return Bus(
      id: id,
      tourId: tourId,
      name: name ?? this.name,
      busNumber: busNumber ?? this.busNumber,
      driverName: driverName ?? this.driverName,
      driverPhone: driverPhone ?? this.driverPhone,
      ownerName: ownerName ?? this.ownerName,
      ownerPhone: ownerPhone ?? this.ownerPhone,
      isAC: isAC ?? this.isAC,
      busType: busType ?? this.busType,
      totalSeatsLegacy: totalSeatsLegacy ?? this.totalSeatsLegacy,
      notes: notes ?? this.notes,
      layout: layout ?? this.layout,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Bus && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
