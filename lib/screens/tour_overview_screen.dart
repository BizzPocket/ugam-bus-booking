import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import 'manage_buses_screen.dart';
import 'requests_screen.dart';

/// SLICE 1 of the smart-seat UI: a per-tour cockpit for the "Fill bus"
/// auto-assignment flow. It is ALWAYS embedded as the SUMMARY surface inside
/// the unified [SeatsScreen]; the SeatsScreen shell owns the head bar + tour
/// workspace, so this widget renders body-only and has no standalone header.
///
/// Layout (top → bottom):
///   * A big PLACED / TOTAL seats stat (tabular figures), with a warm
///     "N need your decision" chip when the last generated plan left
///     exceptions. The chip's tap target is reserved for the future
///     exception-list route.
///   * A vertical scrolling list of bus cards: name + type, an
///     assigned/total fill ratio, a thin progress bar, and a status dot
///     (good = full & clean, warm = has issues / unplaced). Tapping a
///     card opens the manual grid pre-selected to that bus.
///   * A sticky bottom CTA: the prominent "Edit seats by hand" → manual
///     grid, with auto-fill ("Fill bus" → "Re-generate plan" once any
///     seats are placed) as a secondary action that calls
///     [TourController.fillTour], shows an inline progress spinner, then
///     lets the reactive `tours` list repaint the new state.
///
/// All colour comes from [UgamColors.of] — nothing hardcoded — and the
/// screen is dark-first per the locked design DNA.
class TourOverviewScreen extends StatefulWidget {
  final String tourId;

  /// When true the screen renders as a body only — no Scaffold, no SafeArea,
  /// no own header — so it can be embedded as the SUMMARY surface inside the
  /// unified [SeatsScreen]. Standalone (false) keeps the full screen chrome.
  final bool embedded;

  /// Embedded only: drops the agent into the manual seat workbench (the grid).
  /// When set, a prominent "Edit seats by hand" CTA is shown above the
  /// auto-fill action. Null (standalone) hides it.
  final VoidCallback? onEditByHand;

  /// Embedded only: a bus card was tapped — open the grid pre-selected to that
  /// bus. When null (standalone) the card routes to the legacy per-bus detail.
  final ValueChanged<String>? onBusTap;

  const TourOverviewScreen({
    super.key,
    required this.tourId,
    this.embedded = false,
    this.onEditByHand,
    this.onBusTap,
  });

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

  /// Quick link into the requests list (pre-selected to this tour) where the
  /// agent can edit/shrink/waitlist any request — the cockpit itself is
  /// read-only, so this is the door to changing what was asked for.
  void _onEditRequests() {
    Get.to(() => RequestsScreen(initialTourId: widget.tourId));
  }

  void _onAddBus() {
    Get.to(() => ManageBusesScreen(tourId: widget.tourId));
  }

  /// Tapping a bus card opens the manual seat grid pre-selected to that bus.
  /// Embedded inside [SeatsScreen] this switches to the workbench in-place
  /// (via [onBusTap]); standalone it routes to the same unified grid.
  void _onBusTap(Bus bus) {
    final cb = widget.onBusTap;
    if (cb != null) {
      cb(bus.id);
      return;
    }
    Get.toNamed(
      AppRoutes.seatAssignment,
      arguments: {'tourId': widget.tourId, 'busId': bus.id},
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final content = Column(
          children: [
            Expanded(
              child: Obx(() {
                final tour = _ctrl.getTour(widget.tourId);
                if (tour == null) {
                  return Center(
                    child: Text(
                      tr('tour_overview.tour_not_found'),
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  );
                }

                final exceptions = _ctrl.exceptionsForTour(tour.id);
                final assignedByBus = _assignedBerthsByBus(tour);
                final placed = tour.totalSeatsAssigned;
                final total = tour.totalBusSeats;

                // Demand summary: how many of each seat type the passengers
                // requested, so the agent knows what to book. A Double Sofa
                // counts as ONE unit (one tile), NOT its two berths.
                var reqSingles = 0, reqDoubles = 0, reqSeaters = 0;
                // Capacity check runs in BERTHS — the engine's unit: a double
                // sofa line costs 2 berths, single sofa & seater 1 each, and
                // totalBusSeats is already in berths. Only ACTIVE (non-
                // waitlisted) requests compete for seats, so held ones are
                // excluded from demand.
                var demandBerths = 0;
                for (final p in tour.passengers) {
                  final held = p.isWaitlisted;
                  for (final line in p.requestLines) {
                    switch (line.seatType) {
                      case SeatType.singleSofa:
                        reqSingles += line.qty;
                      case SeatType.doubleSofa:
                        reqDoubles += line.qty;
                      case SeatType.seater:
                        reqSeaters += line.qty;
                    }
                    if (!held) {
                      demandBerths +=
                          line.qty * (line.seatType == SeatType.doubleSofa ? 2 : 1);
                    }
                  }
                }

                // Did the LAST generated plan actually overflow anyone? That
                // count is authoritative (post-fill); the pre-fill shortfall is
                // an estimate shown before the agent ever taps Fill.
                final overflowCount = exceptions
                    .where((e) =>
                        e.type == SeatingExceptionType.overflowWaitlist)
                    .length;
                final shortfall = demandBerths - total;
                final showCapacity =
                    overflowCount > 0 || (total > 0 && shortfall > 0);

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
                    if (showCapacity) ...[
                      const SizedBox(height: UgamSpacing.md),
                      _CapacityBanner(
                        overflowCount: overflowCount,
                        demandBerths: demandBerths,
                        capacityBerths: total,
                        shortfall: shortfall,
                        onAddBus: _onAddBus,
                        onReview:
                            overflowCount > 0 ? _onExceptionsTap : null,
                        onEditRequests: _onEditRequests,
                        c: c,
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.md),
                    _RequirementsCard(
                      singles: reqSingles,
                      doubles: reqDoubles,
                      seaters: reqSeaters,
                      onTap: _onEditRequests,
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
            // Sticky bottom CTAs in the thumb zone. The summary's PRIMARY,
            // prominent action is "Edit seats by hand" → the manual grid;
            // auto-fill drops to a secondary neutral button beneath it. When
            // standalone (no onEditByHand) only the auto-fill CTA is shown.
            Obx(() {
              final tour = _ctrl.getTour(widget.tourId);
              final placed = tour?.totalSeatsAssigned ?? 0;
              final hasBuses = (tour?.buses.isNotEmpty ?? false);
              final fillLabel = placed > 0
                  ? tr('tour_overview.regenerate_plan')
                  : tr('tour_overview.fill_bus');
              final onEdit = widget.onEditByHand;
              return UgamStickyCTA(
                child: onEdit == null
                    ? UgamCTA(
                        label: fillLabel,
                        leadingIcon: Icons.auto_awesome_rounded,
                        loading: _filling,
                        onPressed: hasBuses ? _fill : null,
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UgamCTA(
                            label: tr('seats.edit_by_hand'),
                            leadingIcon: Icons.touch_app_rounded,
                            onPressed: hasBuses ? onEdit : null,
                          ),
                          const SizedBox(height: UgamSpacing.sm),
                          UgamButton(
                            label: fillLabel,
                            icon: Icons.auto_awesome_rounded,
                            kind: UgamButtonKind.neutral,
                            expand: true,
                            loading: _filling,
                            onPressed: hasBuses ? _fill : null,
                          ),
                        ],
                      ),
              );
            }),
          ],
        );

    // Embedded: body only — the SeatsScreen shell owns the Scaffold/header.
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(bottom: false, child: content),
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
                  tr('tour_overview.seats_placed'),
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

/// Demand summary for the active tour: how many Single Sofas, Double Sofas
/// (counted as ONE unit each, not two berths), and Seaters the passengers
/// have requested — what the agent books buses against.
class _RequirementsCard extends StatelessWidget {
  final int singles;
  final int doubles;
  final int seaters;

  /// Tapping the card opens the requests list so the agent can edit what was
  /// asked for. Null leaves the card inert.
  final VoidCallback? onTap;
  final UgamColorSet c;

  const _RequirementsCard({
    required this.singles,
    required this.doubles,
    required this.seaters,
    required this.c,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final total = singles + doubles + seaters;
    final items = <(String, int)>[
      (tr('tour_overview.single_sofa'), singles),
      (tr('tour_overview.double_sofa'), doubles),
      if (seaters > 0) (tr('tour_overview.seater'), seaters),
    ];
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tr('tour_overview.bus_requirements'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
              const Spacer(),
              if (onTap != null) ...[
                Text(
                  tr('app.action.edit'),
                  style: UgamText.micro.copyWith(color: c.accent),
                ),
                Icon(Icons.chevron_right_rounded, size: 14, color: c.accent),
              ],
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              for (final it in items)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${it.$2}',
                        style: UgamText.tabular(
                          UgamText.titleL
                              .copyWith(color: c.ink, fontSize: 26),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        it.$1,
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Container(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.sm + 2),
          Text(
            tr('tour_overview.total_to_book', namedArgs: {'n': '$total'}),
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ],
      ),
      ),
    );
  }
}

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
              tr('tour_overview.need_decision', namedArgs: {'n': '$count'}),
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

// ─── Capacity / overflow banner ──────────────────────────────────────────

/// Warm, action-bearing banner shown when demand can't fit the buses.
///
/// BEFORE the agent taps Fill it shows the pre-fill berth shortfall (an
/// estimate from requested-vs-available berths). AFTER a Fill that overflowed
/// it shows the authoritative count of passengers the engine could not seat.
/// Either way it offers the two real remedies — add capacity, or change /
/// waitlist requests — so the agent is never stranded on a read-only screen.
class _CapacityBanner extends StatelessWidget {
  final int overflowCount;
  final int demandBerths;
  final int capacityBerths;
  final int shortfall;
  final VoidCallback onAddBus;

  /// Set only once a plan has actually overflowed — jumps to the waitlist
  /// decisions. Null before the first overflowing Fill.
  final VoidCallback? onReview;
  final VoidCallback onEditRequests;
  final UgamColorSet c;

  const _CapacityBanner({
    required this.overflowCount,
    required this.demandBerths,
    required this.capacityBerths,
    required this.shortfall,
    required this.onAddBus,
    required this.onReview,
    required this.onEditRequests,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final overflowed = overflowCount > 0;
    final title = overflowed
        ? tr('tour_overview.capacity_overflow_title',
            namedArgs: {'n': '$overflowCount'})
        : tr('tour_overview.capacity_short_title');
    final message = overflowed
        ? tr('tour_overview.capacity_overflow_message')
        : tr('tour_overview.capacity_short_message', namedArgs: {
            'demand': '$demandBerths',
            'berthWord': _berthWord(demandBerths),
            'capacity': '$capacityBerths',
            'shortfall': '$shortfall',
          });

    final secondaryLabel = overflowed
        ? tr('tour_overview.review_waitlist')
        : tr('tour_overview.edit_requests');
    final secondaryTap = overflowed ? onReview : onEditRequests;

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.warm.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.warm.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child:
                    Icon(Icons.event_busy_rounded, size: 18, color: c.warm),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      message,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              Expanded(
                child: _BannerAction(
                  label: tr('tour_overview.add_a_bus'),
                  icon: Icons.add_rounded,
                  filled: true,
                  onTap: onAddBus,
                  c: c,
                ),
              ),
              if (secondaryTap != null) ...[
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: _BannerAction(
                    label: secondaryLabel,
                    icon: overflowed
                        ? Icons.error_outline_rounded
                        : Icons.edit_note_rounded,
                    filled: false,
                    onTap: secondaryTap,
                    c: c,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _berthWord(int n) =>
      n == 1 ? tr('tour_overview.berth') : tr('tour_overview.berths');
}

class _BannerAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _BannerAction({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled ? c.onAccent : c.warm;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? c.warm : Colors.transparent,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: filled ? null : Border.all(color: c.warm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
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
                ? tr('tour_overview.status_full')
                : full
                    ? tr('tour_overview.status_needs_review')
                    : tr('tour_overview.status_unplaced'),
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
              tr('tour_overview.no_buses'),
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
