import 'package:flutter/material.dart';

import '../design/group_color.dart';
import '../design/ugam.dart';
import '../utils/pickup_grouping.dart';

/// A section header above a run of roster rows sharing one pickup location.
///
/// Each named location gets its own stable colour (the same golden-angle
/// [groupColorForId] generator the group dots use), re-tuned to a text-legible
/// lightness for the active theme so the hue reads on both the light and
/// near-black grounds. The catch-all "no pickup" bucket reads in muted ink with
/// the caller-supplied [unassignedLabel].
class PickupSectionHeader extends StatelessWidget {
  final String? locationId;
  final String? locationName;
  final int count;

  /// Label for the no-pickup bucket (the caller localizes it).
  final String unassignedLabel;
  final UgamColorSet c;

  const PickupSectionHeader({
    super.key,
    required this.locationId,
    required this.locationName,
    required this.count,
    required this.unassignedLabel,
    required this.c,
  });

  bool get _unassigned => locationName == null || locationName!.trim().isEmpty;

  Color _tint(BuildContext context) {
    if (_unassigned) return c.ink2;
    final hsl = HSLColor.fromColor(
      groupColorForId(locationId ?? locationName!),
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Text-weight lightness: darker on the light ground, brighter on the dark
    // ground, so a saturated per-location hue stays legible either way.
    return hsl
        .withLightness(isDark ? 0.72 : 0.42)
        .withSaturation(0.72)
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    final tint = _tint(context);
    final label = _unassigned ? unassignedLabel : locationName!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.md,
        UgamSpacing.md,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Flexible(
            child: Text(
              label,
              style: UgamText.titleS.copyWith(
                color: tint,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text('· $count', style: UgamText.caption.copyWith(color: c.ink3)),
        ],
      ),
    );
  }
}

/// Renders pickup-grouped roster [groups] as a header + card per section, with
/// [rowBuilder] drawing each item's row.
///
/// When NO item carries a pickup location (an older tour with no pickup data),
/// the headers are skipped and the whole roster falls back to a single flat
/// card — the pre-grouping look. Section order is whatever [groupByPickup]
/// produced (its `rankOf` serial when the caller supplies one, else A→Z; the
/// no-pickup bucket last either way).
class PickupGroupedList<T> extends StatelessWidget {
  final List<PickupGroup<T>> groups;
  final Widget Function(T item) rowBuilder;

  /// Label for the no-pickup bucket header (the caller localizes it).
  final String unassignedLabel;
  final UgamColorSet c;

  const PickupGroupedList({
    super.key,
    required this.groups,
    required this.rowBuilder,
    required this.unassignedLabel,
    required this.c,
  });

  Widget _card(List<T> items) => UgamCard.plain(
    padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
    child: Column(children: [for (final it in items) rowBuilder(it)]),
  );

  @override
  Widget build(BuildContext context) {
    final hasNamed = groups.any((g) => !g.isUnassigned);
    if (!hasNamed) {
      return _card(groups.expand((g) => g.items).toList());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) const SizedBox(height: UgamSpacing.sm),
          PickupSectionHeader(
            locationId: groups[i].locationId,
            locationName: groups[i].locationName,
            count: groups[i].items.length,
            unassignedLabel: unassignedLabel,
            c: c,
          ),
          _card(groups[i].items),
        ],
      ],
    );
  }
}
