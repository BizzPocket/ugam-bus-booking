/// What kind of seats a bus carries.
///
/// - [sleeper]: every seat is a sleeper berth (split lower/upper).
/// - [seater]: every seat is a seater (single deck only).
/// - [mixed]: some sleeper berths + some seater seats on the same bus.
enum BusType {
  sleeper,
  seater,
  mixed;

  String get displayName {
    switch (this) {
      case BusType.sleeper:
        return 'Sleeper';
      case BusType.seater:
        return 'Seater';
      case BusType.mixed:
        return 'Mixed';
    }
  }

  /// Whether this bus has an upper deck.
  bool get hasUpperDeck => this != BusType.seater;

  /// Whether the agent needs to enter a sleeper/seater split.
  bool get needsSplit => this == BusType.mixed;

  static BusType fromString(String? value) {
    if (value == null) return BusType.sleeper;
    return BusType.values.firstWhere(
      (t) => t.name == value.toLowerCase(),
      orElse: () => BusType.sleeper,
    );
  }
}
