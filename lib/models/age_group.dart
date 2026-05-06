/// Age group for passengers — used at handler-pick time and for any
/// future pricing tiers.
enum AgeGroup {
  child,
  adult,
  senior;

  String get displayName {
    switch (this) {
      case AgeGroup.child:
        return 'Child';
      case AgeGroup.adult:
        return 'Adult';
      case AgeGroup.senior:
        return 'Senior';
    }
  }

  static AgeGroup fromString(String? value) {
    if (value == null) return AgeGroup.adult;
    return AgeGroup.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgeGroup.adult,
    );
  }
}
