/// A single seat assignment: ties a passenger to a specific seat on a specific bus.
///
/// Example: `SeatAssignment(busId: "bus_abc", seatId: "DL3")`
class SeatAssignment {
  final String busId;
  final String seatId;

  const SeatAssignment({required this.busId, required this.seatId});

  Map<String, dynamic> toMap() {
    return {'busId': busId, 'seatId': seatId};
  }

  factory SeatAssignment.fromMap(Map<String, dynamic> map) {
    return SeatAssignment(
      busId: map['busId'] as String,
      seatId: map['seatId'] as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeatAssignment && other.busId == busId && other.seatId == seatId;

  @override
  int get hashCode => Object.hash(busId, seatId);

  @override
  String toString() => 'SeatAssignment($busId:$seatId)';
}
