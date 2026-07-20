import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../utils/tour_capacity.dart';
import '../group_color.dart';
import '../text_styles.dart';
import '../tokens.dart';

/// One "Single Sofa · 2 → 1" free-seat pill in a by-type breakdown row.
///
/// The primary number is the ROUND-TRIP-free count of this seat type (green when
/// seats remain, muted when none); a going-only or return-only surplus rides
/// alongside it as a cyan `→ N` / violet `← N` leg badge, so the agent sees at a
/// glance which legs each open seat can still take.
///
/// Shared by the Requests-screen capacity banner and the tour-Summary bus rows
/// so a "Double 1 → 2" reads identically wherever free capacity is shown. The
/// caller supplies the already-localized type [label] and the [SeatTypeFree]
/// slice; the pill never re-derives capacity.
class UgamTypeFreePill extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  final SeatTypeFree free;
  const UgamTypeFreePill({
    super.key,
    required this.c,
    required this.label,
    required this.free,
  });

  @override
  Widget build(BuildContext context) {
    final roundTone = free.round > 0 ? c.good : c.ink3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: UgamText.micro.copyWith(color: c.ink2, fontSize: 10),
          ),
          const SizedBox(width: 5),
          // Round-trip-free — the seats sellable as a fresh both-legs booking.
          Text(
            '${free.round}',
            style: UgamText.tabular(
              UgamText.micro.copyWith(
                color: roundTone,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
          // Going-only surplus (a return rider holds the seat coming back): a
          // GO-cyan badge with a forward arrow → an outbound-only rider fits.
          if (free.goOnly > 0)
            _LegBadge(
              tint: kOneWayTint,
              icon: Icons.arrow_forward_rounded,
              count: free.goOnly,
            ),
          // Return-only surplus (an outbound rider holds it going): a RET-violet
          // badge with a back arrow ← a return-only rider fits.
          if (free.retOnly > 0)
            _LegBadge(
              tint: kReturnTint,
              icon: Icons.arrow_back_rounded,
              count: free.retOnly,
            ),
        ],
      ),
    );
  }
}

/// A small leg-tinted "→ 2" badge inside a [UgamTypeFreePill]: the arrow gives
/// the direction (forward = going, back = returning), the colour reinforces it
/// (GO cyan / RET violet — the same tints the seat chart uses for one-way seats).
class _LegBadge extends StatelessWidget {
  final Color tint;
  final IconData icon;
  final int count;
  const _LegBadge({required this.tint, required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: tint),
          const SizedBox(width: 1),
          Text(
            '$count',
            style: UgamText.tabular(
              UgamText.micro.copyWith(
                color: tint,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour key for the by-type leg badges: a cyan "Go only" swatch + a violet
/// "Return only" swatch, reusing the shared seat-legend wording. Render it only
/// when some type has a one-way-only opening, so it never clutters the common
/// round-trip case. Uses the same GO-cyan / RET-violet tints as the seat chart.
class UgamLegCaption extends StatelessWidget {
  const UgamLegCaption({super.key});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    Widget key(Color tint, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            ),
            const SizedBox(width: 3),
            Text(label,
                style: UgamText.micro.copyWith(color: c.ink3, fontSize: 9)),
          ],
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        key(kOneWayTint, tr('seat_legend.go')),
        const SizedBox(width: 8),
        key(kReturnTint, tr('seat_legend.ret')),
      ],
    );
  }
}
