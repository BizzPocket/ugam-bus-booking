import 'package:easy_localization/easy_localization.dart';

/// The three physical seat types found in Gujarat sleeper/seater buses.
///
/// Position (Upper / Lower) is stored separately — see [SeatPosition].
/// Seaters have no upper/lower distinction; their position is always `null`.
enum SeatType {
  singleSofa,
  doubleSofa,
  seater;

  String get displayName {
    switch (this) {
      case SeatType.singleSofa:
        return tr('enums.seat_type.single_sofa');
      case SeatType.doubleSofa:
        return tr('enums.seat_type.double_sofa');
      case SeatType.seater:
        return tr('enums.seat_type.seater');
    }
  }

  /// Physical berths one unit of this seat type occupies: a Double Sofa is an
  /// upper+lower PAIR (2 berths), every other type is a single berth (1). This
  /// is the one place the "a double sofa is worth two seats" rule lives — seat
  /// totals, capacity accounting ([Passenger.seatBerths]) and group sizing all
  /// route through it so they can't diverge.
  int get berthsPerUnit => this == SeatType.doubleSofa ? 2 : 1;

  /// Parse from stored string.
  static SeatType fromString(String value) {
    return SeatType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SeatType.seater,
    );
  }
}

/// Upper or lower berth position for sleeper seats.
///
/// [SeatType.seater] always has `null` position.
enum SeatPosition {
  upper,
  lower;

  String get suffix {
    switch (this) {
      case SeatPosition.upper:
        return 'U';
      case SeatPosition.lower:
        return 'L';
    }
  }

  String get displayName {
    switch (this) {
      case SeatPosition.upper:
        return tr('enums.seat_position.upper');
      case SeatPosition.lower:
        return tr('enums.seat_position.lower');
    }
  }

  static SeatPosition? fromString(String? value) {
    if (value == null) return null;
    return SeatPosition.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SeatPosition.lower,
    );
  }
}

/// Generate the seat ID prefix from a type + position combination.
///
/// - SingleSofa + Upper → "SU"
/// - SingleSofa + Lower → "SL"
/// - DoubleSofa + Upper → "DU"
/// - DoubleSofa + Lower → "DL"
/// - Seater + null → "ST"  (uses "ST" to avoid collision with SingleSofa "S*")
String seatIdPrefix(SeatType type, SeatPosition? position) {
  switch (type) {
    case SeatType.singleSofa:
      return 'S${position?.suffix ?? 'L'}';
    case SeatType.doubleSofa:
      return 'D${position?.suffix ?? 'L'}';
    case SeatType.seater:
      return 'ST';
  }
}

/// Human-readable label like "Double Sofa Lower" or "Seater".
String seatTypeLabel(SeatType type, SeatPosition? position) {
  if (position == null) return type.displayName;
  return '${type.displayName} ${position.displayName}';
}
