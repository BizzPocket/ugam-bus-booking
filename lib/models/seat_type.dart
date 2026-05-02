enum SeatType { singleSofa, doubleSofa }

extension SeatTypeExtension on SeatType {
  String get displayName {
    switch (this) {
      case SeatType.singleSofa:
        return 'Single Sofa';
      case SeatType.doubleSofa:
        return 'Double Sofa';
    }
  }
}