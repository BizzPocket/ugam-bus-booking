import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';

/// SLICE 1 of the smart-seat UI: a per-tour cockpit for the "Fill bus"
/// auto-assignment flow.
///
/// Layout (top → bottom):
///   * Header — circle back button + tour title.
///   * A big PLACED / TOTAL seats stat (tabular figures), with a warm
///     "N need your decision" chip when the last generated plan left
///     exceptions. The chip's tap target is reserved for the future
///     exception-list route.
///   * A vertical scrolling list of bus cards: name + type, an
///     assigned/total fill ratio, a thin progress bar, and a status dot
///     (good = full & clean, warm = has issues / unplaced). Tapping a
///     card is reserved for the future per-bus seat-detail route.
///   * A sticky bottom pill CTA: "Fill bus" (→ "Re-generate plan" once
///     any seats are placed) that calls [TourController.fillTour], shows
///     an inline progress spinner, then lets the reactive `tours` list
///     repaint the new state.
///
/// All colour comes from [UgamColors.of] — nothing hardcoded — and the
/// screen is dark-first per the locked design DNA.
class TourOverviewScreen extends StatefulWidget {
  final String tourId;

  const TourOverviewScreen({super.key, required this.tourId});

  @override
  State<TourOverviewScreen> createState() => _TourOverviewScreenState();
}

class _TourOverviewScreenState extends State<TourOverviewScreen> {
  /// Inline progress flag for the bottom CTA while [TourController.fillTour]
  /// runs. Kept local (not in the controller) so it only affects this screen.
  bool _filling = false;

  TourController get _ctrl => Get.find<TourController>();

  /// Assigned berths per bus across every passenger. A whole double sofa
  /// (two assignment entries on one seatId) correctly counts as 2 berths
  /// because we count entries, not distinct seats.
  Map<String, int> _assignedBerthsByBus(Tour tour) {
    final out = <String, int>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        out[a.busId] = (out[a.busId] ?? 0) + 1;
      }
    }
    return out;
  }

  Future<void> _fill() async {
    if (_filling) return;
    setState(() => _filling = true);
    try {
      await _ctrl.fillTour(widget.tourId);
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  void _onExceptionsTap() {
    Get.toNamed(
      AppRoutes.seatingExceptions,
      arguments: {'tourId': widget.tourId},
    );
  }

  void _onBusTap(Bus bus) {
    // TODO(seat-ui): wire to the per-bus seat-detail route in a later slice.
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(title: _ctrl.getTour(widget.tourId)?.title ?? '', c: c),
            Expanded(
              child: Obx(() {
                final tour = _ctrl.getTour(widget.tourId);
                if (tour == null) {
                  return Center(
                    child: Text(
                      'Tour not found.',
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  );
                }

                final exceptions = _ctrl.exceptionsForTour(tour.id);
                final assignedByBus = _assignedBerthsByBus(tour);
                final placed = tour.totalSeatsAssigned;
                final total = tour.totalBusSeats;

                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _SeatStat(
                      placed: placed,
                      total: total,
                      c: c,
                    ),
                    if (exceptions.isNotEmpty) ...[
                      const SizedBox(height: UgamSpacing.md),
                      _DecisionChip(
                        count: exceptions.length,
                        onTap: _onExceptionsTap,
                        c: c,
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.xl),
                    if (tour.buses.isEmpty)
                      _NoBuses(c: c)
                    else
                      ...tour.buses.map(
                        (bus) => Padding(
                          padding:
                              const EdgeInsets.only(bottom: UgamSpacing.md),
                          child: _BusCard(
                            bus: bus,
                            assigned: assignedByBus[bus.id] ?? 0,
                            hasExceptions: exceptions.isNotEmpty,
                            onTap: () => _onBusTap(bus),
                            c: c,
                          ),
                        ),
                      ),
                  ],
                );
              }),
            ),
            // Sticky bottom pill CTA in the thumb zone.
            Obx(() {
              final tour = _ctrl.getTour(widget.tourId);
              final placed = tour?.totalSeatsAssigned ?? 0;
              final hasBuses = (tour?.buses.isNotEmpty ?? false);
              return UgamStickyCTA(
                child: UgamCTA(
                  label: placed > 0 ? 'Re-generate plan' : 'Fill bus',
                  leadingIcon: Icons.auto_awesome_rounded,
                  loading: _filling,
                  onPressed: hasBuses ? _fill : null,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String title;
  final UgamColorSet c;

  const _Header({required this.title, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              title.isEmpty ? 'Seat plan' : title,
              style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Placed / total seat stat ────────────────────────────────────────────

class _SeatStat extends StatelessWidget {
  final int placed;
  final int total;
  final UgamColorSet c;

  const _SeatStat({
    required this.placed,
    required this.total,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final complete = total > 0 && placed >= total;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      radius: UgamRadius.stat,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: complete ? c.goodFill : c.accentFill,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(
              complete
                  ? Icons.event_seat_rounded
                  : Icons.grid_view_rounded,
              size: 20,
              color: complete ? c.good : c.accent,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SEATS PLACED',
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                const SizedBox(height: 4),
                RichText(
                  text: TextSpan(
                    style: UgamText.numXl.copyWith(color: c.ink),
                    children: [
                      TextSpan(text: '$placed'),
                      TextSpan(
                        text: ' / $total',
                        style: UgamText.tabular(
                          UgamText.body.copyWith(
                            color: c.ink2,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── "N need your decision" chip ─────────────────────────────────────────

class _DecisionChip extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _DecisionChip({
    required this.count,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: c.warmFill,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: c.warm),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              '$count need your decision',
              style: UgamText.bodyStrong.copyWith(color: c.warm, fontSize: 13),
            ),
            const SizedBox(width: UgamSpacing.xs),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.warm),
          ],
        ),
      ),
    );
  }
}

// ─── Bus card ────────────────────────────────────────────────────────────

class _BusCard extends StatelessWidget {
  final Bus bus;
  final int assigned;

  /// True when the last generated plan has unresolved exceptions on this
  /// tour. Exceptions are passenger/group-scoped, so we surface them at the
  /// bus level by flagging any not-yet-full bus warm while issues exist.
  final bool hasExceptions;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _BusCard({
    required this.bus,
    required this.assigned,
    required this.hasExceptions,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final total = bus.totalSeats;
    final full = total > 0 && assigned >= total;
    // good = full and the plan is clean; warm = not full, or the plan still
    // has exceptions the agent must resolve.
    final clean = full && !hasExceptions;
    final tone = clean ? UgamStatusTone.good : UgamStatusTone.warm;
    final barColor = clean ? c.good : c.warm;
    final ratio = total == 0 ? 0.0 : (assigned / total).clamp(0.0, 1.0);

    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.directions_bus_filled_rounded,
                  size: 18,
                  color: c.ink2,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bus.name,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bus.busType,
                      style: UgamText.caption.copyWith(color: c.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Text(
                '$assigned/$total',
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // Thin fill bar.
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            child: Stack(
              children: [
                Container(height: 6, color: c.cardElev),
                FractionallySizedBox(
                  widthFactor: ratio == 0 ? 0.001 : ratio,
                  child: Container(height: 6, color: barColor),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.sm + 2),
          UgamStatusDot(
            label: clean
                ? 'Full'
                : full
                    ? 'Needs review'
                    : 'Unplaced seats',
            tone: tone,
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────

class _NoBuses extends StatelessWidget {
  final UgamColorSet c;

  const _NoBuses({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_bus_outlined, size: 40, color: c.ink3),
            const SizedBox(height: UgamSpacing.md),
            Text(
              'No buses on this tour yet.',
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
