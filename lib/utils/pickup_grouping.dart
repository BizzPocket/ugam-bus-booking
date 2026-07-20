// Groups a roster into ordered pickup-location sections for the handler's
// call-first views (List + Attendance). A handler boards people one pickup
// point at a time, so the roster reads better grouped under pickup headers
// than as one flat list.
//
// Pickup data comes from the per-passenger snapshot (`pickupLocationId` +
// `pickupLocationName`); the handler manifest carries no global pickup list,
// so grouping keys off the NAME the customer saw at booking.

/// A run of items sharing one pickup location.
///
/// [locationId] / [locationName] are both null for the catch-all bucket of
/// items that have no pickup location. For a named group, [locationId] is the
/// first-seen id (a stable colour key) and [locationName] is the first-seen
/// original-cased name (the header label).
class PickupGroup<T> {
  final String? locationId;
  final String? locationName;
  final List<T> items;

  const PickupGroup({
    required this.locationId,
    required this.locationName,
    required this.items,
  });

  /// The no-pickup bucket — items whose pickup name was null or blank.
  bool get isUnassigned => locationName == null || locationName!.trim().isEmpty;
}

/// Splits [items] into pickup-location sections.
///
/// - Named pickups are sorted case-insensitively A→Z by name; the unassigned
///   bucket (name null or blank) is ALWAYS last.
/// - Two snapshots with the same name — even in different letter case — merge
///   into one group; the first-seen id + original-cased name are kept.
/// - Order WITHIN each group preserves input order, so a name-sorted or
///   seat-ordered input keeps that order inside its section.
List<PickupGroup<T>> groupByPickup<T>(
  Iterable<T> items, {
  required String? Function(T) idOf,
  required String? Function(T) nameOf,
}) {
  final named = <String, _GroupBuilder<T>>{};
  final unassigned = <T>[];

  for (final item in items) {
    final name = nameOf(item)?.trim() ?? '';
    if (name.isEmpty) {
      unassigned.add(item);
      continue;
    }
    final key = name.toLowerCase();
    named
        .putIfAbsent(key, () => _GroupBuilder<T>(id: idOf(item), name: name))
        .items
        .add(item);
  }

  final ordered = named.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  final groups = <PickupGroup<T>>[
    for (final b in ordered)
      PickupGroup<T>(locationId: b.id, locationName: b.name, items: b.items),
    if (unassigned.isNotEmpty)
      PickupGroup<T>(locationId: null, locationName: null, items: unassigned),
  ];
  return groups;
}

/// Mutable accumulator used while walking the roster; frozen into a
/// [PickupGroup] once every item has been placed.
class _GroupBuilder<T> {
  final String? id;
  final String name;
  final List<T> items = <T>[];

  _GroupBuilder({required this.id, required this.name});
}
