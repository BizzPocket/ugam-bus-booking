/// Which legs of a tour a passenger is travelling on.
///
/// Real-world cases this captures:
/// - [roundTrip]: most passengers — both outbound and return legs.
/// - [outboundOnly]: passenger joins the outbound trip but stays longer
///   at the destination and doesn't take the return bus.
/// - [returnOnly]: passenger is already at the destination and boards
///   only the return bus back to the source city.
///
/// Same physical seat can hold two different passengers across legs —
/// e.g., one outbound-only and one return-only share seat 7.
enum TripType {
  roundTrip,
  outboundOnly,
  returnOnly;

  bool get usesOutbound =>
      this == TripType.roundTrip || this == TripType.outboundOnly;

  bool get usesReturn =>
      this == TripType.roundTrip || this == TripType.returnOnly;

  bool get isOneWay => this != TripType.roundTrip;

  /// Storage key — must stay stable; DB column uses these strings.
  String get storageKey => name;

  static TripType fromString(String? value) {
    if (value == null) return TripType.roundTrip;
    return TripType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TripType.roundTrip,
    );
  }
}
