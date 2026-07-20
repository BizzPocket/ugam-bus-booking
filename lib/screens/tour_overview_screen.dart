import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/components/ugam_capacity_meter.dart';
import '../design/components/ugam_free_by_type.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/seat_type.dart';
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import '../utils/tour_capacity.dart';
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

  Future<void> _fill() async {
    if (_filling) return;
    // First fill on a tour runs immediately. Every RE-generate (seats already
    // placed) asks first — a re-run discards the current arrangement and
    // re-assigns everyone, so it should never fire on a stray tap.
    final tour = _ctrl.getTour(widget.tourId);
    if ((tour?.totalSeatsAssigned ?? 0) > 0) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('tour_overview.regenerate_confirm_title'),
        message: tr('tour_overview.regenerate_confirm_body'),
        confirmLabel: tr('tour_overview.cta_regenerate'),
        cancelLabel: tr('app.action.cancel'),
        confirmIcon: Icons.auto_awesome_rounded,
      );
      if (!ok) return;
    }
    if (!mounted) return;
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
            final total = tour.totalBusSeats;
            // TWO snapshots, each answering a DIFFERENT question so no surface
            // lies:
            //  * [actual] — real [assignedSeats], the SAME seats the grid shows
            //    — drives every "how full?" fill surface: the seats-placed
            //    headline, each bus row's meter, and the "full" dot. This is why
            //    a bus can never read "full" while its grid still has empty
            //    seats — they read the identical placements.
            //  * [cap] — the engine's would-fill plan ([SeatingEngine.propose])
            //    — drives ONLY the capacity-shortfall / "needs decision" banner,
            //    which asks "can everyone fit?", not "who is placed?".
            // Both are leg-aware: a berth shared by two opposite one-way riders
            // is ONE physical seat, split into honest GO/RET loads per leg.
            final actual = total > 0 ? computeActualCapacity(tour) : null;
            final cap = total > 0 ? computeTourCapacity(tour) : null;

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
                .where((e) => e.type == SeatingExceptionType.overflowWaitlist)
                .length;
            // Pre-fill shortfall is ENGINE truth, not the leg-agnostic
            // `demandBerths − total`. The raw subtraction overstated the gap
            // because it ignored leg-sharing (two opposite one-way riders
            // reuse one berth), so it claimed "6 short" while the engine can
            // actually seat all but 3. Routing through [computeTourCapacity]
            // makes "may not fit" agree with the same plan the chart and the
            // Requests banner use — over-demand surfaces as needsDecision,
            // never a phantom number. See [TourCapacity.freeByType].
            final shortfall = cap?.needsDecision ?? 0;
            final showCapacity = overflowCount > 0 || shortfall > 0;

            return ListView(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.sm,
                UgamSpacing.gutter,
                UgamSpacing.sm,
              ),
              physics: const BouncingScrollPhysics(),
              children: [
                // One compact summary: seats-placed + the bus requirements
                // (what to book), on the 8pt grid — replaces the two tall
                // stat/requirements cards.
                _SummaryCard(
                  actual: actual,
                  total: total,
                  singles: reqSingles,
                  doubles: reqDoubles,
                  seaters: reqSeaters,
                  onEditRequests: _onEditRequests,
                  c: c,
                ),
                if (showCapacity) ...[
                  const SizedBox(height: UgamSpacing.sm),
                  _CapacityBanner(
                    overflowCount: overflowCount,
                    demandBerths: demandBerths,
                    capacityBerths: total,
                    shortfall: shortfall,
                    onAddBus: _onAddBus,
                    onReview: overflowCount > 0 ? _onExceptionsTap : null,
                    onEditRequests: _onEditRequests,
                    c: c,
                  ),
                ],
                // Collapse to ONE warm attention surface: the capacity
                // banner already carries a "review waitlist" action into
                // the same exceptions route, so the decision chip only
                // appears when the banner is NOT shown — never both warm
                // blocks at once.
                if (exceptions.isNotEmpty && !showCapacity) ...[
                  const SizedBox(height: UgamSpacing.sm),
                  _DecisionChip(
                    count: exceptions.length,
                    onTap: _onExceptionsTap,
                    c: c,
                  ),
                ],
                const SizedBox(height: UgamSpacing.md),
                // Buses are slim list rows inside ONE card (hairline
                // dividers between), so several fit without the old
                // card-per-bus gaps.
                if (tour.buses.isEmpty)
                  _NoBuses(c: c)
                else
                  Container(
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(UgamRadius.card),
                      border: Border.all(color: c.border),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < tour.buses.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: c.border,
                              indent: UgamSpacing.md,
                              endIndent: UgamSpacing.md,
                            ),
                          _BusRow(
                            bus: tour.buses[i],
                            busCap: actual?.byBus[tour.buses[i].id],
                            freeByType: actual?.freeByType[tour.buses[i].id],
                            hasExceptions: exceptions.isNotEmpty,
                            onTap: () => _onBusTap(tour.buses[i]),
                            c: c,
                          ),
                        ],
                      ],
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
          // Thumb-zone stack: the ONE primary focal action is the
          // full-width champagne UgamCTA "Edit seats by hand"; auto-fill /
          // re-generate drops below it as a quiet full-width ghost
          // UgamButton so solid gold stays rationed to a single element.
          // Standalone (no onEditByHand) collapses to the lone auto-fill
          // CTA as the screen's primary.
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
                        label: tr('tour_overview.cta_edit_by_hand'),
                        leadingIcon: Icons.edit_rounded,
                        onPressed: hasBuses ? onEdit : null,
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      UgamButton(
                        label: fillLabel,
                        icon: Icons.auto_awesome_rounded,
                        kind: UgamButtonKind.ghost,
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
    return UgamScaffold(
      body: SafeArea(bottom: false, child: content),
    );
  }
}

// ─── Summary card (seats placed + bus requirements) ──────────────────────

/// One compact card on the 8pt grid: the seats-placed progress on top, a
/// hairline divider, then what the agent still has to book (single/double/
/// seater counts + total). Replaces the two tall stat + requirements cards.
class _SummaryCard extends StatelessWidget {
  /// ACTUAL-assignment snapshot driving the seats-placed meter — the SAME real
  /// seats the grid shows, so "placed" means placed, not "the plan would place".
  /// Null only when the tour has no buses yet (total == 0) — then the meter row
  /// collapses to a plain "0 / total".
  final ActualCapacity? actual;
  final int total;
  final int singles;
  final int doubles;
  final int seaters;
  final VoidCallback onEditRequests;
  final UgamColorSet c;

  const _SummaryCard({
    required this.actual,
    required this.total,
    required this.singles,
    required this.doubles,
    required this.seaters,
    required this.onEditRequests,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final units = singles + doubles + seaters;
    final chips = <String>[
      '$singles ${tr('tour_overview.single_sofa')}',
      '$doubles ${tr('tour_overview.double_sofa')}',
      if (seaters > 0) '$seaters ${tr('tour_overview.seater')}',
    ].join('  ·  ');

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Seats placed — eyebrow, then the shared two-leg meter. The meter
          // owns the count ("placed / cap"), the per-leg GO/RET split, the
          // "{n} free" label and the bar — no percentage, no merged fraction,
          // and every figure a whole seat. Falls back to a plain "0 / 0" when
          // the tour has no buses yet (cap == null).
          Text(
            tr('tour_overview.seats_placed'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          if (actual != null)
            UgamCapacityMeter.tourCounts(
              capacity: actual!.capacity,
              goOccupied: actual!.goOccupied,
              retOccupied: actual!.retOccupied,
            )
          else
            Text(
              '0 / $total',
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink),
              ),
            ),
          const SizedBox(height: UgamSpacing.md),
          Container(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          // Bus requirements — eyebrow + Edit, then the chips + total.
          Row(
            children: [
              Text(
                tr('tour_overview.bus_requirements'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onEditRequests,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('app.action.edit'),
                      style: UgamText.micro.copyWith(color: c.accent),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: c.accent,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            chips,
            style: UgamText.caption.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            tr('tour_overview.total_to_book', namedArgs: {'n': '$units'}),
            style: UgamText.micro.copyWith(color: c.ink3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
        ? tr(
            'tour_overview.capacity_overflow_title',
            namedArgs: {'n': '$overflowCount'},
          )
        : tr('tour_overview.capacity_short_title');
    final message = overflowed
        ? tr('tour_overview.capacity_overflow_message')
        : tr(
            'tour_overview.capacity_short_message',
            namedArgs: {
              'demand': '$demandBerths',
              'berthWord': _berthWord(demandBerths),
              'capacity': '$capacityBerths',
              'shortfall': '$shortfall',
            },
          );

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
                child: Icon(Icons.event_busy_rounded, size: 18, color: c.warm),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: UgamText.titleS.copyWith(color: c.ink)),
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
    // Both banner actions are now WARM TONAL — mirroring [UgamButton]'s tonal
    // geometry (50-h, input radius, fill + hairline border) but tinted warm so
    // the attention surface stays a single warm signal. The "primary" remedy
    // ([filled]) reads a touch stronger via a denser warm fill; the secondary
    // shares the same warm-tonal shape so the pair looks like one component
    // family instead of a solid-slab + outline mix.
    final bg = filled
        ? c.warm.withValues(alpha: 0.20)
        : c.warm.withValues(alpha: 0.10);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          border: Border.all(color: c.warm.withValues(alpha: 0.40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.warm),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(
                  color: c.warm,
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
    // Leg-aware fullness from the engine slice: a bus is full only when its
    // busier leg leaves no berth free. Falls back to "not full" when the slice
    // is missing so the dot reads warm rather than falsely clean.
    final full = total > 0 && (busCap?.free ?? total) == 0;
    final clean = full && !hasExceptions;
    final tone = clean ? c.good : c.warm;

    // Free-by-type breakdown from ACTUAL seats: one pill per seat type this bus
    // still has openings on — so "4 ખાલી" berths reads as real seats (a Double
    // Sofa is ONE tile worth two berths). Ordered single · double · seater;
    // types with nothing free are skipped, so a full bus shows no line (the
    // meter already says "full"). Cyan → / violet ← badges carry the one-way
    // surplus; the leg caption shows only when some type has a one-way opening.
    final fbt = freeByType;
    final typePills = <(String, SeatTypeFree)>[
      if (fbt != null)
        for (final st in const [
          SeatType.singleSofa,
          SeatType.doubleSofa,
          SeatType.seater,
        ])
          if ((fbt[st]?.total ?? 0) > 0) (st.displayName, fbt[st]!),
    ];
    final anyOneWay = typePills.any((p) => p.$2.hasOneWay);

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
                      style: UgamText.bodyStrong.copyWith(
                        color: c.ink,
                        fontSize: 14,
                      ),
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
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: tone,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, size: 16, color: c.ink3),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            // Shared per-bus meter owns the leg-split count + "{n} free" + bar.
            UgamCapacityMeter.bus(
              busCap ??
                  BusCapacity(
                    busId: bus.id,
                    capacity: total,
                    goOccupied: 0,
                    retOccupied: 0,
                  ),
            ),
            // Compact free-by-type line beneath the meter (actual seats).
            if (typePills.isNotEmpty) ...[
              const SizedBox(height: UgamSpacing.sm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (label, free) in typePills)
                    UgamTypeFreePill(c: c, label: label, free: free),
                ],
              ),
              if (anyOneWay) ...[
                const SizedBox(height: 6),
                const UgamLegCaption(),
              ],
            ],
          ],
        ),
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
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
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
