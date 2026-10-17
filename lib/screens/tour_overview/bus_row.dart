part of '../tour_overview_screen.dart';

// ─── Bus row ─────────────────────────────────────────────────────────────

/// A slim, tappable bus row inside the shared buses card: name · type, a
/// status dot, and the shared two-leg capacity meter (`Go x/n · Ret y/n` over a
/// thin bar). The dot colour is the status (good = full & clean, warm = unplaced
/// or needs review), so no separate status line is needed — keeps several buses
/// visible at once.
class _BusRow extends StatelessWidget {
  final Bus bus;

  /// This bus's ACTUAL leg-aware occupancy slice, keyed by bus id. Null only when
  /// the tour has no capacity snapshot yet — the row then degrades to an empty
  /// meter.
  final BusCapacity? busCap;

  /// This bus's GENUINELY-empty tiles by seat type (from real assignments) —
  /// drives the compact free-by-type line under the meter. Null when there's no
  /// snapshot; an entry per seat type the bus has (zero rows are skipped in the
  /// UI).
  final Map<SeatType, SeatTypeFree>? freeByType;

  /// True when the last generated plan has unresolved exceptions on this tour
  /// — flags any not-yet-full bus warm while issues remain.
  final bool hasExceptions;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _BusRow({
    required this.bus,
    required this.busCap,
    required this.freeByType,
    required this.hasExceptions,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final total = bus.totalSeats;
    // Berths this bus can actually sell — the snapshot's figure when there is
    // one, the bus's own count otherwise. Zero means the seat layout never
    // landed, which is the SAME third state the meter now names: not full, not
    // empty, no plan. Nothing below may say "full" while this holds.
    final capBerths = busCap?.capacity ?? total;
    final noPlan = capBerths <= 0;
    // Leg-aware fullness from the engine slice: a bus is full only when its
    // busier leg leaves no berth free. Falls back to "not full" when the slice
    // is missing so the dot reads warm rather than falsely clean.
    final full = !noPlan && (busCap?.free ?? capBerths) == 0;
    final clean = full && !hasExceptions;
    final tone = clean ? c.good : c.warm;

    // Free seats as typed berth glyphs (actual seats): the meter's ambiguous
    // "{n} free" berth text is suppressed and this shows what's actually open —
    // a single-berth vs double-berth icon so "double = 2 berths" reads at a
    // glance, with leg colour for any one-way surplus. A bus with nothing free
    // shows a plain "full" instead.
    final fbt = freeByType;
    final hasFree = fbt != null && fbt.values.any((f) => f.total > 0);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.directions_bus_filled_rounded,
                  size: 16,
                  color: c.ink3,
                ),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: UgamText.bodyStrong.copyWith(color: c.ink),
                      children: [
                        TextSpan(text: bus.name),
                        TextSpan(
                          text: '  ·  ${bus.busType}',
                          style: UgamText.caption.copyWith(color: c.ink3),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                // 6 px, the size UgamStatusDot renders
                // (ugam_status_dot.dart:35-36), so this bus row's status
                // indicator matches every other status indicator in the app.
                // Deliberately NOT the component itself — UgamStatusDot always
                // emits a label, and this row shows the state by colour alone.
                // See the agent report: swapping it in would mean `label: ''`.
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: tone,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Icon(Icons.chevron_right_rounded, size: 16, color: c.ink3),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            // Per-bus meter shows just "placed/cap" over the bar — the free
            // indicator moves below as typed seat icons (showFreeLabel: false).
            UgamCapacityMeter.bus(
              busCap ??
                  BusCapacity(
                    busId: bus.id,
                    capacity: total,
                    goOccupied: 0,
                    retOccupied: 0,
                  ),
              showFreeLabel: false,
            ),
            // Free seats: typed berth glyphs when any are open, else a plain
            // "full". Only when a capacity snapshot exists (fbt != null) AND
            // the bus has a seat plan — the `else` below is an unconditional
            // "full", so on a layout-less bus (no types, therefore no free
            // types) it printed the exact claim the meter above just stopped
            // making. The meter's own no-plan line already speaks for this row.
            if (fbt != null && !noPlan) ...[
              const SizedBox(height: UgamSpacing.sm),
              if (hasFree)
                UgamFreeSeats(freeByType: fbt, c: c)
              else
                Text(
                  tr('capacity.full'),
                  style: UgamText.tabular(
                    UgamText.caption.copyWith(color: c.ink3),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
