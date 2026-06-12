import '../design/group_color.dart';
import '../models/tour.dart';

/// Builds the one canonical [GroupColorResolver] for a [tour] from its
/// [PassengerGroup] palette indices, so every seat chart — inline and the
/// shared full-screen view — rings a given group with the same colour.
///
/// This replaces the per-screen copies of the same id→colorIndex map build.
GroupColorResolver tourGroupColors(Tour tour) {
  return GroupColorResolver({for (final g in tour.groups) g.id: g.colorIndex});
}
