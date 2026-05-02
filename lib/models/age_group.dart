enum AgeGroup { elder, young, other }

extension AgeGroupExtension on AgeGroup {
  String get displayName {
    switch (this) {
      case AgeGroup.elder:
        return 'Elder';
      case AgeGroup.young:
        return 'Young';
      case AgeGroup.other:
        return 'Other';
    }
  }
}