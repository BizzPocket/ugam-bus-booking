import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ctrl.ensureTourReadyForSeating(widget.tourId);
    });
  }

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
    // NESTED push (not `Get.to`, which lands on the ROOT navigator and covers
    // the dock) so reaching Requests from the seats cockpit behaves exactly
    // like reaching it from the tour Overview tool row
    // (tour_detail_screen.dart:2132). Same destination, same chrome.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RequestsScreen(initialTourId: widget.tourId),
      ),
    );
  }

  void _onAddBus() {
    // Nested for the same reason — mirrors tour_detail_screen.dart:1959.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ManageBusesScreen(tourId: widget.tourId),
      ),
    );
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
              // Three genuinely different reasons the tour isn't here, and
              // they used to collapse into one flat "Tour not found." — which
              // on a cold start (the roster is still in flight) is a lie that
              // reads as a broken screen.
              if (_ctrl.isLoading.value) return const _OverviewSkeleton();
              if (_ctrl.hasError.value) {
                return UgamEmpty.error(
                  onRetry: _ctrl.refreshTours,
                  message: _ctrl.errorMessage.value,
                );
              }
              // Genuinely absent (deleted / wrong id). Still offer the one
              // recovery path there is rather than a dead end.
              return UgamEmpty(
                icon: Icons.search_off_rounded,
                title: tr('tour_overview.tour_not_found'),
                cta: UgamCTA(
                  label: tr('app.action.refresh'),
                  leadingIcon: Icons.refresh_rounded,
                  onPressed: _ctrl.refreshTours,
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
            // Both memoized on the controller: these sit inside an Obx that
            // rebuilds on every seat tap and realtime event, and [cap] runs the
            // full seating engine.
            final actual = total > 0 ? _ctrl.actualCapacityFor(tour) : null;
            final cap = total > 0 ? _ctrl.capacityFor(tour) : null;

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
            // The engine can only place riders onto a real seat GRID — see the
            // early return in [SeatingEngine] for a bus with no layout. While
            // the layout jsonb is still in flight (cold start omits it to save
            // 2G bytes) it therefore places NOBODY, and every rider lands in
            // needsDecision. Rendering that reads as "79 wanted, only 74 fit,
            // ~54 won't make it" on a tour that is in fact almost perfectly
            // seated. Withhold the verdict until the grids are actually here;
            // the seats-placed numbers above stay honest throughout because
            // they fall back to the legacy seat count.
            final layoutsReady = _ctrl.layoutsLoadedFor(widget.tourId);
            final showCapacity =
                layoutsReady && (overflowCount > 0 || shortfall > 0);

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
                  // An empty state that names the problem and hands over the
                  // fix. It used to be title-only, on the one screen whose
                  // entire job is impossible until a bus exists.
                  UgamEmpty(
                    icon: Icons.directions_bus_outlined,
                    title: tr('tour_overview.no_buses'),
                    cta: UgamCTA(
                      label: tr('tour_overview.add_a_bus'),
                      leadingIcon: Icons.add_rounded,
                      onPressed: _onAddBus,
                    ),
                  )
                else ...[
                  // Names the block the card below is. Natural case (no
                  // .toUpperCase()): the eyebrow read comes from micro's
                  // weight + tracking, which survives Gujarati and Hindi,
                  // where uppercasing is a no-op.
                  Row(
                    children: [
                      Text(
                        tr('tour_detail.tab_buses'),
                        style: UgamText.micro.copyWith(color: c.ink3),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      UgamReqChip(
                        label: '${tour.buses.length}',
                        variant: UgamChipVariant.neutral,
                      ),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  // Shared card chrome. `padding: zero` is load-bearing —
                  // UgamCard.plain defaults to `gutter` all round, and the rows
                  // below carry their own `md` padding + full-bleed dividers.
                  UgamCard.plain(
                    padding: EdgeInsets.zero,
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
          // Thumb-zone stack. The ONE primary focal action stays the full-width
          // champagne UgamCTA "Edit seats by hand"; auto-fill / re-generate is
          // the subordinate. Standalone (no onEditByHand) collapses to the lone
          // auto-fill CTA as the screen's primary.
          //
          // The secondary used to be `expand: true`, and that is what made the
          // pair unreadable: TWO full-width slabs of the same width and nearly
          // the same height, one filled and one not. The eye compares footprint
          // before it compares fill, so they read as peers — while the ghost's
          // actual weight is that of a text link. Neither won.
          //
          // Fixed by committing to the subordination rather than faking parity:
          // the ghost keeps its kind (its `ink2` label is already AA on the
          // page — 6.20:1 Daylight / 6.83:1 Midnight) and drops to CONTENT
          // width, centred, so all four cues now point the same way instead of
          // two of them cancelling out: solid champagne vs transparent, 52 vs
          // 48.1 pt tall, titleS vs bodyStrong, 347 vs 263.7 pt wide (measured,
          // gu @375). No second champagne element — the accent-rationing law
          // forbids one, and a tonal/neutral slab would have ADDED weight to
          // the thing that needs less of it.
          //
          // Honest limit: at the 1.3x text scale app.dart permits, the label
          // grows and the width cue narrows to 324.3 vs 347. The fill, height
          // and type cues are unaffected, so the hierarchy degrades gracefully
          // rather than reverting — but the width is not doing the work there.
          //
          // It is also the safer geometry. These two actions are not peers in
          // kind: "Edit by hand" opens a workspace and is always reversible,
          // while re-generate DISCARDS the current arrangement and re-seats
          // everyone (hence the confirm in [_fill]). Handing a destructive
          // mutation the full width of the thumb zone, directly under the
          // button the agent taps most, is a mis-tap waiting to happen. At
          // content width it is still a 48.1 pt-tall, 263.7 pt-wide target —
          // far past the 44 pt floor — carrying 70% of the CTA's hit area.
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
                      // IntrinsicWidth is LOAD-BEARING, not decoration.
                      // `expand: false` alone does nothing here: UgamButton's
                      // inner Container sets `alignment: Alignment.center`,
                      // which wraps its child in an Align, and an Align with no
                      // size factors takes `constraints.biggest` whenever the
                      // incoming constraints are bounded. Dropping `expand`
                      // measured 347 px — byte-identical to the full-width
                      // version. IntrinsicWidth hands the button a TIGHT width
                      // (its own max intrinsic, clamped to what the row has), so
                      // it finally renders at content width. Verified by
                      // measurement, not by reading the flag.
                      //
                      // AnimatedSize because `loading` swaps the label for a
                      // 20 px spinner: at content width that is a real width
                      // change, and an unanimated one would snap the button to
                      // a stub the instant the agent taps it.
                      AnimatedSize(
                        duration: UgamMotion.tab,
                        curve: UgamMotion.easeOut,
                        child: IntrinsicWidth(
                          child: UgamButton(
                            label: fillLabel,
                            icon: Icons.auto_awesome_rounded,
                            kind: UgamButtonKind.ghost,
                            loading: _filling,
                            onPressed: hasBuses ? _fill : null,
                          ),
                        ),
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

// ─── First-load placeholder ──────────────────────────────────────────────

/// Shaped like the cockpit it stands in for — the summary card, the buses
/// eyebrow, then the buses card — so the load lands as a fill change rather
/// than a spinner popping into a new layout. Gutters match the real
/// [ListView] above it, so nothing shifts sideways when the data arrives.
class _OverviewSkeleton extends StatelessWidget {
  const _OverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 150, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            UgamSkeleton(height: 14, width: 64, radius: 6),
            SizedBox(width: UgamSpacing.sm),
            UgamSkeleton(height: 14, width: 22, radius: 6),
          ],
        ),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 196, radius: UgamRadius.card),
      ],
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

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Seats placed — eyebrow, then the shared two-leg meter. The meter
          // owns the count ("placed / cap"), the per-leg GO/RET split, the
          // "{n} free" label and the bar — no percentage, no merged fraction,
          // and every figure a whole seat.
          //
          // ONE branch, not two. The `else` here used to hand-roll a literal
          // "0 / $total" — and `actual` is null EXACTLY when `total == 0`, so
          // that string was always, unavoidably, "0 / 0": a fraction with a
          // zero denominator, printed directly under a "SEATS PLACED" eyebrow,
          // above a "no buses yet" empty state. The meter now owns the
          // zero-capacity case as an explicit third state ("no seat plan yet"),
          // so routing the null snapshot through it deletes the contradiction
          // instead of duplicating a worse version of it here.
          Text(
            tr('tour_overview.seats_placed'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamCapacityMeter.tourCounts(
            capacity: actual?.capacity ?? total,
            goOccupied: actual?.goOccupied ?? 0,
            retOccupied: actual?.retOccupied ?? 0,
          ),
          const SizedBox(height: UgamSpacing.md),
          Container(height: 1, color: c.border),
          // Bus requirements — eyebrow + Edit, then the chips + total.
          //
          // "Edit" is the only inline door from the seats cockpit to the
          // Requests editor and it was a ~34 px target: the previous pass got
          // there by folding the surrounding whitespace into the link's own
          // padding, then stopped short of 44 rather than resize the card
          // without being asked. The row is now a real 44 px band — the
          // vertical space it used to pad with is simply inside the band, so
          // the card grows ~12 px, on a screen that had void below it anyway.
          // The left padding on the link widens the box further into the gap
          // beside it, at no visual cost.
          //
          // The label is also no longer champagne: tokens.dart reserves the
          // accent for "this is yours" and names links explicitly as NOT that.
          // Weight carries the affordance instead.
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Text(
                  tr('tour_overview.bus_requirements'),
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onEditRequests,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.only(left: UgamSpacing.lg),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('app.action.edit'),
                            style: UgamText.caption.copyWith(
                              color: c.ink2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: c.ink2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Two lines, no ellipsis: these are system labels ("સિંગલ સોફા ·
          // ડબલ સોફા · સીટર"), which run past a single 375 pt line in
          // Gujarati. Truncating a requirements list to "3 સિંગલ સો…" loses
          // the very numbers the agent came here to read.
          Text(
            chips,
            style: UgamText.caption.copyWith(color: c.ink),
            maxLines: 2,
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('tour_overview.total_to_book', namedArgs: {'n': '$units'}),
            style: UgamText.micro.copyWith(color: c.ink3),
            maxLines: 2,
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
        // The single entry to the seating-conflict resolver was a 38 px
        // target. `minHeight: 44` floors it; `centerLeft` is MANDATORY beside
        // it — without an alignment the Row would top-align inside the taller
        // box, and `center` would re-centre it horizontally too (the parent is
        // a full-width ListView). Matches charts_screen.dart:463.
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.tight,
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
              style: UgamText.bodyStrong.copyWith(color: c.warm),
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

    // The shared card, tinted warm — NOT a hand-rolled Container. The tone
    // resolves to the same warmFill + warm hairline this used to spell out by
    // hand, and composing the component means the banner picks up the app's
    // elevation instead of sitting flat on the page like a wireframe block.
    return UgamCard.plain(
      tone: UgamCardTone.warm,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                // DECORATIVE badge (nothing taps it) -> px, not tap. Radius 10
                // was off the UgamRadius scale entirely; `input` (14) is what
                // every other icon chip in the tours cluster uses
                // (tour_detail_screen.dart:643, :2256).
                width: UgamScale.px(context, 34),
                height: UgamScale.px(context, 34),
                decoration: BoxDecoration(
                  color: c.warm.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(UgamRadius.input),
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
                    const SizedBox(height: UgamSpacing.xs),
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
    // ROSE ON ROSE DOES NOT WORK. These two buttons used to be warm@20% /
    // warm@10% fills carrying a `c.warm` label, sitting on a `warmFill` card —
    // rose ink on a rose wash on a rose ground. Measured on the current tokens
    // (warm-tone card ground: #F8E2EC Daylight / #322126 Midnight):
    //
    //                            Daylight   Midnight   needs
    //   primary label            3.50       4.56       4.5
    //   secondary label          4.00       5.54       4.5
    //   primary fill vs card     1.30       1.47       3.0
    //   secondary fill vs card   1.14       1.21       3.0
    //   hairline warm@40 vs card 1.74       2.24       3.0
    //
    // Only the two Midnight labels cleared anything; both buttons dissolved
    // into the card in BOTH themes, so the remedies the banner exists to offer
    // were invisible as controls. The fix separates the pair by WEIGHT instead
    // of by 10 points of alpha:
    //
    //  * primary  — solid, full-strength `c.warm` with `c.onAction` ink.
    //               label 5.60 / 8.38, fill vs card 4.56 / 6.71.
    //  * secondary— keeps the tonal wash but takes a full-strength `c.ink`
    //               label (13.39 / 11.37) and a full-strength `c.warm` border
    //               (4.56 / 6.71 vs the card, 4.00 / 5.54 vs its own fill).
    //               No alpha on a warm fill can clear 3:1 against warmFill —
    //               the boundary has to come from the border. Do not retry it.
    //
    // Still WARM, deliberately not danger: "not enough seats" is an actionable
    // warning, and this app rations red for things that need intervention.
    //
    // `c.onAction` is the ink on BOTH themes' solid fill with no brightness
    // branch: it is white in Daylight and the #12100E ground in Midnight, which
    // is exactly the flip `warm` needs (a mid-tone rose in light, a pale rose in
    // dark). It beats `c.onAccent` in Midnight too (8.38 vs 8.20).
    final Color bg = filled ? c.warm : c.warm.withValues(alpha: 0.10);
    final Color fg = filled ? c.onAction : c.ink;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // The comment above says this mirrors UgamButton's tonal geometry at
        // "50-h" but the code wrote 48, so these two were the only buttons in
        // the app 2 px short of every other one. `tap` (never `px` — this is a
        // finger target) corrects the value AND puts it on the scale factor,
        // so it tracks the text inside it on a small phone: 50 at 390 pt,
        // floored at the 44 pt minimum below that.
        height: UgamScale.tap(context, 50),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          // No border on the solid one — its own fill already draws the edge at
          // 4.56 / 6.71 against the card, and a warm hairline on a warm slab is
          // just an invisible line. The bordered-vs-borderless difference is
          // part of what now separates the two silhouettes.
          border: filled ? null : Border.all(color: c.warm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            // `sm`, matching the icon->label gap UgamButton uses at
            // ugam_button.dart:132 — the component this row mirrors.
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.captionStrong.copyWith(color: fg),
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

// ─── Empty state ──────────────────────────────────────────────────────────
//
// The "no buses yet" state is now the shared [UgamEmpty] (see the build method
// above), matching tour_detail_screen.dart:1422-1435 — the same tour's Buses
// tab. The old hand-rolled `_NoBuses` (40 px icon, body/ink2 label) rendered
// the same condition as a visibly different, plainer empty state.
