/// A single seat assignment: ties a passenger to a specific seat on a specific bus.
///
/// Example: `SeatAssignment(busId: "bus_abc", seatId: "DL3")`
///
/// [locked] marks a berth the agent placed/confirmed by hand. A seating-engine
/// re-generate must never move a locked assignment. It is NOT part of identity:
/// equality/hashCode key off (busId, seatId) only, so occupancy lookups
/// (`assignedSeats.contains(target)`) keep working regardless of lock state.
class SeatAssignment {
  final String busId;
  final String seatId;
  final bool locked;

  const SeatAssignment({
    required this.busId,
    required this.seatId,
    this.locked = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'busId': busId,
      'seatId': seatId,
      if (locked) 'locked': true,
    };
  }

  factory SeatAssignment.fromMap(Map<String, dynamic> map) {
    return SeatAssignment(
      busId: map['busId'] as String,
      seatId: map['seatId'] as String,
      locked: map['locked'] as bool? ?? false,
    );
  }

  SeatAssignment copyWith({bool? locked}) {
    return SeatAssignment(
      busId: busId,
      seatId: seatId,
      locked: locked ?? this.locked,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeatAssignment && other.busId == busId && other.seatId == seatId;

  @override
  int get hashCode => Object.hash(busId, seatId);

  @override
  String toString() => 'SeatAssignment($busId:$seatId${locked ? ' locked' : ''})';
}
