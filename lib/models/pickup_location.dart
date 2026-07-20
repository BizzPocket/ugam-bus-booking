/// A single global pickup point customers may OPTIONALLY choose when they book.
///
/// The list is admin-managed in Settings and shared across EVERY tour (not
/// per-tour). Only the [id] + [name] are snapshotted onto a booking request, so
/// renaming or retiring a point later never rewrites a historical request.
///
/// Backed by the `pickup_locations` table (migration 031). [sortOrder] controls
/// the manual admin ordering; [isActive] hides a retired point from the customer
/// picker while keeping it available for the admin manager.
///
/// [code] is the admin-facing short keyword (e.g. "ST" for Surat) shown on
/// organiser surfaces only; customers still see the full [name].
class PickupLocation {
  final String id;
  final String name;
  final String? code;
  final int sortOrder;
  final bool isActive;

  const PickupLocation({
    required this.id,
    required this.name,
    this.code,
    this.sortOrder = 0,
    this.isActive = true,
  });

  factory PickupLocation.fromMap(Map<String, dynamic> map) => PickupLocation(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        code: map['code'] as String?,
        sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
        isActive: (map['is_active'] as bool?) ?? true,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'code': code,
        'sort_order': sortOrder,
        'is_active': isActive,
      };

  PickupLocation copyWith({
    String? id,
    String? name,
    String? code,
    int? sortOrder,
    bool? isActive,
  }) =>
      PickupLocation(
        id: id ?? this.id,
        name: name ?? this.name,
        code: code ?? this.code,
        sortOrder: sortOrder ?? this.sortOrder,
        isActive: isActive ?? this.isActive,
      );
}
