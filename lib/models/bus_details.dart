import 'package:uuid/uuid.dart';

class BusDetails {
  final String id;
  final String? tourId;
  final String busNumber;
  final String driverName;
  final String driverPhone;
  final String? ownerName;
  final String? ownerPhone;
  final bool isAC;
  final String busType;
  final int totalSeats;
  final String? notes;

  BusDetails({
    String? id,
    this.tourId,
    required this.busNumber,
    required this.driverName,
    required this.driverPhone,
    this.ownerName,
    this.ownerPhone,
    this.isAC = true,
    this.busType = 'Semi-Sleeper',
    required this.totalSeats,
    this.notes,
  }) : id = id ?? const Uuid().v4();

  // ── Appwrite serialization (camelCase, no id) ─────────────
  Map<String, dynamic> toAppwrite(String tourId) {
    return {
      'tourId': tourId,
      'busNumber': busNumber,
      'driverName': driverName,
      'driverPhone': driverPhone,
      'ownerName': ownerName,
      'ownerPhone': ownerPhone,
      'isAC': isAC,
      'busType': busType,
      'totalSeats': totalSeats,
      'notes': notes,
    };
  }

  factory BusDetails.fromAppwrite(Map<String, dynamic> map) {
    return BusDetails(
      id: ((map[r'$id'] ?? map['id']) as String?) ?? const Uuid().v4(),
      tourId: map['tourId'] as String?,
      busNumber: map['busNumber'] as String,
      driverName: map['driverName'] as String,
      driverPhone: map['driverPhone'] as String,
      ownerName: map['ownerName'] as String?,
      ownerPhone: map['ownerPhone'] as String?,
      isAC: map['isAC'] as bool? ?? true,
      busType: map['busType'] as String? ?? 'Semi-Sleeper',
      totalSeats: map['totalSeats'] as int? ?? 0,
      notes: map['notes'] as String?,
    );
  }

  BusDetails copyWith({
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? ownerName,
    String? ownerPhone,
    bool? isAC,
    String? busType,
    int? totalSeats,
    String? notes,
  }) {
    return BusDetails(
      id: id,
      tourId: tourId,
      busNumber: busNumber ?? this.busNumber,
      driverName: driverName ?? this.driverName,
      driverPhone: driverPhone ?? this.driverPhone,
      ownerName: ownerName ?? this.ownerName,
      ownerPhone: ownerPhone ?? this.ownerPhone,
      isAC: isAC ?? this.isAC,
      busType: busType ?? this.busType,
      totalSeats: totalSeats ?? this.totalSeats,
      notes: notes ?? this.notes,
    );
  }
}
