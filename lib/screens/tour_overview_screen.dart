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
import '../models/tour_status.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'tour_seat_assignment_screen.dart';
import 'requests_screen.dart';

part 'tour_overview/overview_cards.dart';
part 'tour_overview/bus_row.dart';

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
        // It throws away every placed seat — say so with the danger button.
        destructive: true,
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
    // (the Requests row of tour_detail's `_ActionsGrid`). Same destination,
    // same chrome.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RequestsScreen(initialTourId: widget.tourId),
      ),
    );
  }

  void _onAddBus() {
    // Nested for the same reason — mirrors tour_detail's `_runKind`
    // (`_NextActionKind.addBus`).
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
          child: _buildBody(c),
        ),
        // Sticky bottom CTAs in the thumb zone. The summary's PRIMARY,
        // prominent action is "Edit seats by hand" → the manual grid;
        // auto-fill drops to a secondary neutral button beneath it. When
        // standalone (no onEditByHand) only the auto-fill CTA is shown.
        _buildStickyCtas(),
      ],
    );

    // Embedded: body only — the SeatsScreen shell owns the Scaffold/header.
    if (widget.embedded) return content;
    return UgamScaffold(
      body: SafeArea(bottom: false, child: content),
    );
  }

  Widget _buildBody(UgamColorSet c) {
    return Obx(() {
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
                  for (final (i, bus) in tour.buses.indexed) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: c.border,
                        indent: UgamSpacing.md,
                        endIndent: UgamSpacing.md,
                      ),
                    _BusRow(
                      bus: bus,
                      busCap: actual?.byBus[bus.id],
                      freeByType: actual?.freeByType[bus.id],
                      hasExceptions: exceptions.isNotEmpty,
                      onTap: () => _onBusTap(bus),
                      c: c,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    });
  }

  Widget _buildStickyCtas() {
    return Obx(() {
      final tour = _ctrl.getTour(widget.tourId);
      final placed = tour?.totalSeatsAssigned ?? 0;
      final hasBuses = (tour?.buses.isNotEmpty ?? false);
      final fillLabel = placed > 0
          ? tr('tour_overview.regenerate_plan')
          : tr('tour_overview.fill_bus');
      final onEdit = widget.onEditByHand;
      // Phase-appropriate primary. Once seats are placed, re-generate is a
      // DESTRUCTIVE action (it discards every seat) and must never be the
      // screen's one solid button: on a locked/completed tour the next job
      // is telling riders their seats, otherwise it is working the chart.
      final locked = tour != null &&
          (tour.status == TourStatus.locked ||
              tour.status == TourStatus.completed);
      void openNotify() => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NotifyScreen(tourId: widget.tourId),
            ),
          );
      void openChart() => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  TourSeatAssignmentScreen(tourId: widget.tourId),
            ),
          );
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
      Widget ghost(String label, IconData icon, VoidCallback? onTap,
              {bool busy = false}) =>
          AnimatedSize(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            child: IntrinsicWidth(
              child: UgamButton(
                label: label,
                icon: icon,
                kind: UgamButtonKind.ghost,
                loading: busy,
                onPressed: onTap,
              ),
            ),
          );
      final regenerateGhost = ghost(
        fillLabel,
        Icons.auto_awesome_rounded,
        hasBuses ? _fill : null,
        busy: _filling,
      );
      if (placed > 0 && (onEdit == null || locked)) {
        return UgamStickyCTA(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              locked
                  ? UgamCTA(
                      label: tr('tour_overview.cta_notify'),
                      leadingIcon: Icons.campaign_rounded,
                      onPressed: openNotify,
                    )
                  : UgamCTA(
                      label: tr('tour_overview.cta_edit_by_hand'),
                      leadingIcon: Icons.edit_rounded,
                      onPressed: hasBuses ? openChart : null,
                    ),
              const SizedBox(height: UgamSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (locked) ...[
                    Flexible(
                      child: ghost(
                        tr('tour_overview.cta_edit_by_hand'),
                        Icons.edit_rounded,
                        hasBuses ? (onEdit ?? openChart) : null,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                  ],
                  Flexible(child: regenerateGhost),
                ],
              ),
            ],
          ),
        );
      }
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
                  // Content-width ghost — see [ghost] for why it is wrapped.
                  regenerateGhost,
                ],
              ),
      );
    });
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────
//
// The "no buses yet" state is now the shared [UgamEmpty] (see the build method
// above), matching the empty state in tour_detail/buses_tab.dart — the same
// tour's Buses tab. The old hand-rolled `_NoBuses` (40 px icon, body/ink2 label) rendered
// the same condition as a visibly different, plainer empty state.
