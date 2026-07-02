import 'trip_type.dart';

/// A single seat assignment: ties a passenger to a specific seat on a specific bus.
///
/// Example: `SeatAssignment(busId: "bus_abc", seatId: "DL3")`
///
/// [locked] marks a berth the agent placed/confirmed by hand. A seating-engine
/// re-generate must never move a locked assignment. [leg] records which tour leg
/// this specific berth is held for. NEITHER is part of identity: equality/hashCode
/// key off (busId, seatId) only, so occupancy lookups
/// (`assignedSeats.contains(target)`) keep working regardless of lock or leg.
class SeatAssignment {
  final String busId;
  final String seatId;
  final bool locked;

  /// The trip leg this specific seat is held for (GO-only / RET-only /
  /// round-trip). null = not recorded (legacy) so readers fall back to the
  /// passenger-level leg. NOT part of identity.
  final TripType? leg;

  const SeatAssignment({
    required this.busId,
    required this.seatId,
    this.locked = false,
    this.leg,
  });

  Map<String, dynamic> toMap() {
    return {
      'busId': busId,
      'seatId': seatId,
      if (locked) 'locked': true,
      if (leg != null) 'leg': leg!.storageKey,
    };
  }

  factory SeatAssignment.fromMap(Map<String, dynamic> map) {
    return SeatAssignment(
      busId: map['busId'] as String,
      seatId: map['seatId'] as String,
      locked: map['locked'] as bool? ?? false,
      leg: map['leg'] != null ? TripType.fromString(map['leg'] as String) : null,
    );
  }

  SeatAssignment copyWith({bool? locked, TripType? leg}) {
    return SeatAssignment(
      busId: busId,
      seatId: seatId,
      locked: locked ?? this.locked,
      leg: leg ?? this.leg,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeatAssignment && other.busId == busId && other.seatId == seatId;

  @override
  int get hashCode => Object.hash(busId, seatId);

  @override
  String toString() =>
      'SeatAssignment($busId:$seatId${locked ? ' locked' : ''}'
      '${leg != null ? ' ${leg!.storageKey}' : ''})';
}
