import 'package:easy_localization/easy_localization.dart';

/// Age group for passengers — used at handler-pick time and for any
/// future pricing tiers.
enum AgeGroup {
  child,
  adult,
  senior;

  String get displayName => switch (this) {
        AgeGroup.child => tr('enums.age_group.child'),
        AgeGroup.adult => tr('enums.age_group.adult'),
        AgeGroup.senior => tr('enums.age_group.senior'),
      };

  static AgeGroup fromString(String? value) {
    if (value == null) return AgeGroup.adult;
    return AgeGroup.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgeGroup.adult,
    );
  }
}
