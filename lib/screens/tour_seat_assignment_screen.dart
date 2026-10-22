import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'fullscreen_chart_screen.dart';
import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../components/seat_tile_memo.dart';
import '../design/ugam.dart';
import '../controllers/pickup_controller.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/trip_type.dart';
import '../services/chart_footer_store.dart';
import '../services/seat_chart_pdf.dart';
import '../services/seat_move_flow.dart';
import '../services/seat_swap_guard.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_drop_engine.dart';
import '../utils/seat_fit.dart';
import '../utils/seat_leg_capacity.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/cached_data_banner.dart';
import '../widgets/chart_expand_button.dart';
import '../widgets/occupant_action_sheet.dart';
import '../widgets/chart_footer_sheet.dart';
import '../widgets/edit_request_sheet.dart';
import 'add_return_ticket_sheet.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'requests_screen.dart';

part 'tour_seat_assignment/tap_flow.dart';
part 'tour_seat_assignment/relocate_flow.dart';
part 'tour_seat_assignment/drag_drop.dart';
part 'tour_seat_assignment/sheets_and_pills.dart';
part 'tour_seat_assignment/seat_grid.dart';
part 'tour_seat_assignment/assignment_dock.dart';
part 'tour_seat_assignment/empty_states.dart';

/// Tour-scoped seat assignment workspace.
///
/// Ugam rebuild:
///   * Top bar — circle back button + title + Fleet circle on the right.
///   * Horizontal bus pills (Ugam style — accent active, cardElev inactive)
///     with assigned/capacity badge.
///   * `UgamTabPills` deck toggle when an upper deck exists.
///   * Seat grid wrapped in `UgamCard.plain` (22 px radius). Tile colours
///     come from `UgamColors.of(context)`.
///   * Floating `_AssignmentDock` pinned to the bottom — collapsed by default
///     (grab handle + one-line active-passenger summary + horizontal queue
///     strip + Lock/Download action) so the whole chart stays visible; drag
///     the handle up to OVERLAY the chart with the full passenger detail.
///     The "Lock tour" pill appears when `tour.allSeatsAssigned &&
///     tour.handlerId != null`.
///
/// Sacred business logic preserved:
///   * `_pendingLines`, `_berthsForFreeCell`, `_onSeatTapped`, `_findCell`.
///     (Draining is now `seat_fit.dart`'s shared helper, and locking lives on
///     the Notify screen's `_lockTour`.) (Handler assignment is now
///     per-bus — picked on the Manage Buses screen — so the old tour-wide
///     handler toggle has been removed from this screen.)
class TourSeatAssignmentScreen extends StatefulWidget {
  final String tourId;

  /// Optional. When set, the screen lands on this specific passenger so
  /// the agent can start tapping seats immediately. Passed through from
  /// the "Assign Seats →" button on the Requests screen.
  final String? initialPassengerId;

  /// Optional. When set, the chart opens pre-selected to this bus (deep-link
  /// from the overview bus cards / a seating exception). Falls back to the
  /// first bus when null or unknown. A seated [initialPassengerId] still wins
  /// the bus it sits on once the agent interacts; this only seeds the FIRST
  /// paint.
  final String? initialBusId;

  /// When true the screen renders as a body only — no Scaffold/SafeArea/own
  /// header — so it can be embedded as the "Assign" mode inside the unified
  /// [SeatsScreen]. Standalone (false) keeps the full screen chrome.
  final bool embedded;

  /// Embedded only: the [SeatsScreen] shell header hosts the "clear all
  /// assigned seats" action. The body pushes the current clear callback (or
  /// null when nothing is assigned on the selected bus) into this sink so the
  /// header can surface it.
  final ValueNotifier<VoidCallback?>? clearActionSink;

  const TourSeatAssignmentScreen({
    super.key,
    required this.tourId,
    this.initialPassengerId,
    this.initialBusId,
    this.embedded = false,
    this.clearActionSink,
  });

  @override
  State<TourSeatAssignmentScreen> createState() =>
      _TourSeatAssignmentScreenState();
}

/// Height the collapsed assignment dock reserves at the bottom of the screen.
/// The seat-chart scroll view pads its bottom by this much (+ the safe area)
/// so the chart legend is never hidden behind the floating dock. Sized for the
/// compact two-zone dock: grab handle + the "Now seating" card + a single
/// horizontal "Up next" chip strip + the primary action. Shorter than the old
/// stacked vertical list, so more of the chart shows.
///
/// Worst-case composition at scale factor 1.0 (i.e. every optional row shown —
/// an active passenger AND a >6-deep queue AND the primary action). Keep this
/// arithmetic in sync when a row is added to or removed from [_AssignmentDock]:
///
///   grab handle          44   (xxl + 4 bar + xxl — a real 44 drag/tap zone)
///   "Now seating" block  78   (4 + label 12 + 4 + card 58)
///   queue block         168   (8 + header 44 + 6 + strip 48 + 4 + button 50 + 8)
///   trailing gap          4   (xs; the safe-area inset is added separately)
///   ------------------------
///   total               294  -> 300 with a little slack
///
/// The reservation is multiplied by [UgamScale.px] at the use site, because
/// every one of those rows follows the app scale.
const double _kCollapsedDockHeight = 300;

class _TourSeatAssignmentScreenState extends State<TourSeatAssignmentScreen> {
  String? _selectedBusId;
  String? _selectedPassengerId;

  /// The seat being long-press-dragged on the chart (the source seat id), and
  /// whether SOME drag is currently in flight. Non-null only mid-drag; while a
  /// drag is active every other tile lights up per [_dropHighlightFor] so the
  /// agent sees legal targets before releasing.
  String? _dragFromSeatId;
  bool _dragActive = false;

  /// The pending (unseated) rider being dragged from the dock, or null. While
  /// set, [_dropHighlightFor] lights up the seats where THEY fit (instead of the
  /// seat→seat move highlight), and [_dragActive] is on so the grid paints them.
  String? _pendingDragId;

  /// Active cross-bus "relocate" hand-off. Set when the agent picks a
  /// destination bus from the move flow: the chart switches to that bus and the
  /// [mover] is held "in hand" with their source seat ([fromBusId]/[fromSeatId])
  /// remembered, so the next seat tap MOVES (tap a free seat) or SWAPS (tap an
  /// occupied seat) them across — driven by hand instead of the auto
  /// swap-assistant. Null when no relocate is in progress.
  ({Passenger mover, String fromBusId, String fromSeatId})? _relocate;

  /// Whether the bottom assignment dock is expanded to its full-detail state.
  /// Collapsed by default so the whole seat chart is visible; the agent drags
  /// the handle up (or taps it) only when they want the active passenger's
  /// full request breakdown. The expanded sheet OVERLAYS the chart, so opening
  /// it never squeezes the grid.
  bool _dockExpanded = false;

  @override
  void initState() {
    super.initState();
    _selectedPassengerId = widget.initialPassengerId;
    _selectedBusId = widget.initialBusId;
    // Warm the global pickup list so the seat-picker rows and the "now seating"
    // card can label each rider's boarding point (code, else name snapshot).
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
    // Cold start omits bus layout jsonb — pull it before the agent seats anyone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.ensureTourReadyForSeating(widget.tourId);
    });
  }

  /// [setState] for the flow extensions in `tour_seat_assignment/` — an
  /// extension is not a [State] subclass, so it may not call the protected
  /// member directly. Plain pass-through.
  void _update(VoidCallback fn) => setState(fn);

  TourController get _ctrl => Get.find<TourController>();

  Tour? get _tour => _ctrl.getTour(widget.tourId);

  // Cached selection for the SeatsScreen-hosted clear action (embedded mode).
  // The body refreshes these every build; [_clearCachedBus] is a stable
  // instance tear-off, so pushing it into [clearActionSink] only notifies the
  // header on a clearable<->empty flip, not every frame.
  Tour? _hdrTour;
  Bus? _hdrBus;
  int _hdrCount = 0;

  void _clearCachedBus() {
    final t = _hdrTour, b = _hdrBus;
    if (t == null || b == null || _hdrCount == 0) return;
    _confirmClearBus(t, b, _hdrCount);
  }

  /// Confirm + unassign every seat on [bus]. Passengers keep their requests, so
  /// they drop straight back into the pending dock.
  Future<void> _confirmClearBus(Tour tour, Bus bus, int seatCount) async {
    final ok = await _confirmSheet(
      context,
      title: tr('seat_assignment.clear_bus.title'),
      message: tr(
        'seat_assignment.clear_bus.body',
        namedArgs: {'count': '$seatCount', 'bus': bus.name},
      ),
      confirmLabel: tr('seat_assignment.clear_bus.confirm'),
      destructive: true,
    );
    if (!ok) return;
    try {
      await _ctrl.unassignBus(tour.id, bus.id);
      AppSnackBar.success(
        tr('seat_assignment.clear_bus.done', namedArgs: {'bus': bus.name}),
      );
    } catch (_) {
      // unassignBus already surfaced the error.
    }
  }

  Bus? _selectedBus(Tour tour) {
    if (tour.buses.isEmpty) return null;
    final id = _selectedBusId;
    final match = id == null
        ? null
        : tour.buses.where((b) => b.id == id).firstOrNull;
    return match ?? tour.buses.first;
  }

  Passenger? _selectedPassenger(Tour tour) {
    if (tour.passengers.isEmpty) return null;
    final id = _selectedPassengerId;
    if (id != null) {
      final match = tour.passengers.where((p) => p.id == id).firstOrNull;
      if (match != null) return match;
    }
    // Default to the first un- or partially-assigned passenger.
    return tour.passengers.where((p) => !p.isFullyAssigned).firstOrNull ??
        tour.passengers.first;
  }

  /// Selects [passengerId] and, when that passenger already holds a seat,
  /// switches the visible bus to the one they're seated on. So tapping a name
  /// in the picker — e.g. while choosing the handler after every seat is
  /// placed — jumps the chart straight to the bus where that person actually
  /// sits, instead of leaving the agent on whatever bus was showing.
  void _selectPassenger(Tour tour, String passengerId) {
    String? busId;
    for (final p in tour.passengers) {
      if (p.id == passengerId) {
        if (p.assignedSeats.isNotEmpty) busId = p.assignedSeats.first.busId;
        break;
      }
    }
    setState(() {
      _selectedPassengerId = passengerId;
      if (busId != null) _selectedBusId = busId;
    });
  }

  // ── Edit seats: Forward / Reserved flags ────────────────────────────────

  /// Edit-mode tap on a seat → a small sheet with two switches: "Forward /
  /// premium seat" ([TourController.setSeatForward]) and "Hold / reserved"
  /// ([TourController.setSeatReserved]). The chart repaints reactively once the
  /// controller mutates the bus layout.
  void _showSeatFlagsSheet(SeatCell cell, Bus bus) {
    final seatId = cell.seatId;
    if (seatId == null) return;
    UgamSheet.show<void>(
      context,
      showClose: false,
      builder: (_) => _SeatFlagsSheet(
        seatId: seatId,
        typeLabel: cell.typeLabel,
        busName: bus.name,
        forward: cell.forward,
        reserved: cell.reserved,
        onForward: (v) =>
            _ctrl.setSeatForward(widget.tourId, bus.id, seatId, v),
        onReserved: (v) =>
            _ctrl.setSeatReserved(widget.tourId, bus.id, seatId, v),
      ),
    );
  }

  /// Lock & notify is ONE path: [NotifyScreen]. This workbench button no longer
  /// locks or sends inline — it routes to the canonical lock+notify home, which
  /// owns the lock gate, the lock confirm, and the auto seat-allocation send.
  void _openLockAndNotify(Tour tour) {
    Get.to(() => NotifyScreen(tourId: tour.id));
  }

  /// Whether an A4 chart PDF is currently being generated. Drives the
  /// "Creating chart…" indicator and blocks re-entry while a share sheet
  /// is being prepared.
  bool _generatingChart = false;

  /// Feature 1: load the saved footer, let the agent edit it, persist it,
  /// then build the all-buses A4 PDF and open the native share/print sheet.
  Future<void> _downloadChart(Tour tour) async {
    if (_generatingChart) return;

    final saved = await ChartFooterStore.load(tour.id);
    if (!mounted) return;

    final options = await showChartFooterSheet(
      context,
      initial: saved,
      tour: tour,
    );
    if (options == null) return;
    if (!mounted) return;

    await ChartFooterStore.save(tour.id, options.footer);
    if (!mounted) return;

    setState(() => _generatingChart = true);
    AppSnackBar.info(tr('chart.generating'));
    try {
      await SeatChartPdf.shareTourChartA4(
        tour: tour,
        footer: options.footer,
        leg: options.leg,
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('chart.error'));
    } finally {
      if (mounted) setState(() => _generatingChart = false);
    }
  }

  // ── Seat-grid widget memo (performance) ─────────────────────────────────
  // The whole workbench lives in one Obx + this State's setState, so chrome
  // that never touches the chart — opening/closing the dock, the "generating
  // chart" flag — used to rebuild every seat tile (19-74 of them, each running
  // resolveSeatRender). Returning the IDENTICAL [_SeatGrid] instance lets
  // Flutter skip the whole subtree. The key is every input the grid (and the
  // callbacks it holds) reads: the Tour/Bus INSTANCES (the controller replaces
  // them on every change — models are immutable, and `==` on them is by id, so
  // identity is compared), the active passenger, every drag/relocate field the
  // highlight callbacks consult at call time, the viewport height, and the
  // locale (tr() inside the grid holds no Localizations dependency).
  /// Per-seat tile memo: when ONE seat changes, only that tile rebuilds.
  final _tileMemo = SeatTileMemo();

  /// Seat tap against the LIVE tour + selected bus (see [_SeatGrid.onTap]).
  void _onLiveSeatTapped(SeatCell cell) {
    final tour = _tour;
    if (tour == null) return;
    final bus = _selectedBus(tour);
    if (bus == null) return;
    _onSeatTapped(cell, bus, tour);
  }

  _SeatGrid? _gridMemo;
  List<Object?>? _gridMemoKey;

  Widget _memoSeatGrid({
    required Tour tour,
    required Bus bus,
    required String? passengerId,
    required double viewportHeight,
    required _SeatGrid Function() build,
  }) {
    final key = <Object?>[
      tour,
      bus,
      passengerId,
      viewportHeight,
      _dragActive,
      _dragFromSeatId,
      _pendingDragId,
      _relocate,
      Localizations.maybeLocaleOf(context),
    ];
    final prev = _gridMemoKey;
    final memo = _gridMemo;
    if (memo != null && prev != null && _sameGridKey(prev, key)) return memo;
    final fresh = build();
    _gridMemo = fresh;
    _gridMemoKey = key;
    return fresh;
  }

  static bool _sameGridKey(List<Object?> a, List<Object?> b) {
    // Tour + Bus by identity (their == is id-only); the rest by value.
    if (!identical(a[0], b[0]) || !identical(a[1], b[1])) return false;
    if (!identical(a[7], b[7])) return false; // _relocate record instance
    for (var i = 2; i < a.length; i++) {
      if (i == 7) continue;
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // The header doesn't depend on any reactive state — hoist it above the
    // Obx so realtime tour updates don't repaint it.
    final content = Column(
      children: [
        if (!widget.embedded)
          UgamAppBar(
            title: tr('tour_seat_assignment.title'),
            actions: [
              UgamAppBarAction(
                icon: Icons.directions_bus_filled_rounded,
                tooltip: tr('tour_seat_assignment.tooltip_manage_buses'),
                onTap: () =>
                    Get.to(() => ManageBusesScreen(tourId: widget.tourId)),
              ),
            ],
          ),
        // The chart is the surface where believing stale data actually costs
        // something — two devices seating riders into the same berth. Sits
        // above the bus pills so it is read before any seat is tapped; renders
        // nothing when the graph is live.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: CachedDataBanner(),
        ),
        Expanded(
          child: Obx(() {
            final tour = _tour;
            if (tour == null) {
              return Center(
                child: Text(
                  tr('tour_seat_assignment.tour_not_found'),
                  style: UgamText.body.copyWith(color: c.ink2),
                ),
              );
            }
            if (tour.buses.isEmpty) {
              return _NoBuses(tourId: widget.tourId);
            }
            if (tour.passengers.isEmpty) {
              return _NoPassengers(tourId: widget.tourId);
            }

            final bus = _selectedBus(tour)!;
            final passenger = _selectedPassenger(tour);
            // One pass over all passengers builds the lookup for every
            // bus at once.
            final assignmentsByBus = _assignmentsByBus(tour);
            final assignmentMap =
                assignmentsByBus[bus.id] ?? const <String, List<String>>{};

            // Embedded: hand the clear-all-seats action up to the SeatsScreen
            // header for the currently selected bus. Deferred to post-frame so
            // notifying the header is never a build-phase markNeedsBuild; the
            // tear-off keeps it a no-op unless clearable<->empty flips.
            if (widget.embedded && widget.clearActionSink != null) {
              _hdrTour = tour;
              _hdrBus = bus;
              _hdrCount = assignmentMap.length;
              final next = assignmentMap.isEmpty ? null : _clearCachedBus;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.clearActionSink!.value = next;
              });
            }

            // Content-based lock gate, matching the Notify-tab gate: a tour
            // is lockable once every seat is assigned, a handler is picked,
            // and it has passengers — regardless of the exact status label
            // (and never re-lockable once locked/completed). Previously this
            // required `status == assigning`, which the stalled status
            // machine never reached, so this CTA was permanently dead.
            final canLock =
                tour.status != TourStatus.locked &&
                tour.status != TourStatus.completed &&
                tour.passengers.isNotEmpty &&
                tour.allSeatsAssigned &&
                tour.handlerId != null;

            // Chart download is lock-agnostic — the PDF is built purely from
            // buses + passengers + assignedSeats — so allow it BEFORE lock too:
            // the organiser can review or share the chart before committing to
            // lock. Rendered as a secondary action beside Lock / Pick-handler,
            // and as the sole primary when nothing else occupies that slot
            // (e.g. post-lock, or mid-assignment).
            final canDownload =
                tour.buses.isNotEmpty && tour.passengers.isNotEmpty;

            final pending = tour.passengers
                .where(
                  (p) =>
                      !p.isFullyAssigned && !p.isWaitlisted && !p.journeyDone,
                )
                .toList();

            final allAssigned = tour.allSeatsAssigned;
            return Stack(
              children: [
                Column(
                  children: [
                    // Bus selector — now the sole occupant of this row (the
                    // old "edit seats" chip that used to sit beside it, and
                    // stole the width that clipped the second pill's capacity
                    // badge, is gone; seat Premium/Held flags now live in the
                    // seat's own tap menu — occupied via the occupant sheet,
                    // empty via long-press).
                    _BusPills(
                      buses: tour.buses,
                      selectedBusId: bus.id,
                      // Leg-aware: a berth shared by two opposite one-way
                      // riders is ONE physical seat. Counting raw entries
                      // made the badge read "38/37" past capacity.
                      seatsAssignedFor: tour.occupiedBerthsFor,
                      onTapBus: (id) {
                        setState(() {
                          _selectedBusId = id;
                        });
                      },
                      c: c,
                    ),
                    // The selected bus's registration, under the strip rather
                    // than inside a pill: the pills live in a fixed 44pt tap
                    // strip that already clipped a capacity badge once, so a
                    // plate wedged in there would be the next thing to go. This
                    // is the seating surface — the agent placing riders needs
                    // to know WHICH physical coach they are filling, and until
                    // now nothing on this screen said.
                    if (bus.busNumber.trim().isNotEmpty) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.gutter,
                        ),
                        child: Text(
                          bus.busNumber.trim(),
                          // Meta ink, never the accent: a plate identifies the
                          // vehicle, it does not mark anything as yours.
                          style: UgamText.tabular(
                            UgamText.caption,
                          ).copyWith(color: c.ink2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.md),
                    // Per-leg (GO / RETURN) occupancy meter for the SELECTED bus
                    // — a fill bar per leg so the agent reads how full each leg
                    // is straight from the layout (the tab badge only shows a
                    // single whole-seat count). Built from ACTUAL assignments so
                    // it tracks the grid, not the engine plan.
                    Builder(
                      builder: (_) {
                        final busCap = _ctrl
                            .actualCapacityFor(tour)
                            .byBus[bus.id];
                        if (busCap == null || busCap.capacity <= 0) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(
                            UgamSpacing.gutter,
                            0,
                            UgamSpacing.gutter,
                            UgamSpacing.md,
                          ),
                          child: UgamCapacityMeter.tourCounts(
                            capacity: busCap.capacity,
                            goOccupied: busCap.goOccupied,
                            retOccupied: busCap.retOccupied,
                          ),
                        );
                      },
                    ),
                    // Relocate banner eases in/out (fade + slight slide from the
                    // top) as relocate mode turns on/off. Always-mounted switcher
                    // that collapses to a zero-size SizedBox when inactive, so the
                    // steady-state Column layout is identical to the bare `if`.
                    AnimatedSwitcher(
                      duration: UgamMotion.sheet,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeOutCubic,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SizeTransition(
                            sizeFactor: animation,
                            // `axisAlignment: -1.0` is deprecated. On the
                            // default vertical axis the framework mapped that
                            // to `AlignmentDirectional(-1.0, axisAlignment)`,
                            // so topStart is the exact equivalent — the banner
                            // still grows DOWNWARD from its top edge instead of
                            // splitting open from the middle. Directional (not
                            // `Alignment.topLeft`) so the horizontal term stays
                            // RTL-correct, matching what the old property did.
                            alignment: AlignmentDirectional.topStart,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, -0.15),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          ),
                        );
                      },
                      child: _relocate != null
                          ? Padding(
                              key: const ValueKey('relocate-banner'),
                              padding: const EdgeInsets.fromLTRB(
                                UgamSpacing.gutter,
                                0,
                                UgamSpacing.gutter,
                                UgamSpacing.md,
                              ),
                              child: _RelocateBanner(
                                moverName: _relocate!.mover.displayName,
                                busName: bus.name,
                                onCancel: _cancelRelocate,
                                c: c,
                              ),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('relocate-empty'),
                            ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (ctx, constraints) {
                          return SingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(
                              UgamSpacing.gutter,
                              0,
                              UgamSpacing.gutter,
                              // Clear the floating assignment dock so the chart
                              // legend is never hidden behind it. The dock's
                              // real height is intrinsic and follows the app
                              // text/chrome scale, so the reservation has to
                              // track the same factor — a flat 244 over-reserves
                              // on small phones and under-reserves at large text
                              // (the legend then hides behind the dock).
                              UgamScale.px(context, _kCollapsedDockHeight) +
                                  MediaQuery.of(context).padding.bottom,
                            ),
                            physics: const BouncingScrollPhysics(),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _memoSeatGrid(
                                  tour: tour,
                                  bus: bus,
                                  passengerId: passenger?.id,
                                  viewportHeight: constraints.maxHeight,
                                  build: () => _SeatGrid(
                                    // The visible scroll-area height — the pinch-
                                    // zoom box is bounded to it so the constrained
                                    // InteractiveViewer has finite height inside
                                    // this unbounded scroll view, and the chart
                                    // fits in view with pinch for detail.
                                    viewportHeight: constraints.maxHeight,
                                    layout: bus.layout,
                                    tour: tour,
                                    assignmentMap: assignmentMap,
                                    currentPassengerId: passenger?.id,
                                    // Resolved at TAP time, not captured:
                                    // memoized tiles outlive this build, and
                                    // must act on the live tour/bus.
                                    onTap: _onLiveSeatTapped,
                                    tileMemo: _tileMemo,
                                    busName: bus.name,
                                    // Drag-to-move is always live now that the
                                    // edit-flags mode is gone.
                                    enableDrag: true,
                                    dragActive: _dragActive,
                                    canDragSeat: (cell) =>
                                        _canDragSeat(tour, bus, cell),
                                    dropHighlightFor: (cell) =>
                                        _dropHighlightFor(tour, bus, cell),
                                    dragLabelFor: (cell) =>
                                        _dragLabelFor(tour, bus, cell),
                                    onSeatDragStarted: (cell) => setState(() {
                                      _dragFromSeatId = cell.seatId;
                                      _dragActive = true;
                                    }),
                                    onSeatDragEnded: () => setState(() {
                                      _dragFromSeatId = null;
                                      _dragActive = false;
                                    }),
                                    onSeatDraggedToSeat:
                                        (fromSeatId, toSeatId) =>
                                            _handleSeatDrop(
                                              tour,
                                              bus,
                                              fromSeatId,
                                              toSeatId,
                                            ),
                                    onPendingRiderDroppedToSeat:
                                        (passengerId, seatId) =>
                                            _handlePendingDropToSeat(
                                              tour,
                                              bus,
                                              passengerId,
                                              seatId,
                                            ),
                                    // Long-press an EMPTY seat → its Hold/Premium
                                    // flag sheet. (Booked-seat long-press stays a
                                    // drag; booked seats reach the flag sheet from
                                    // the occupant tap menu instead.)
                                    onSeatLongPressForFlags: (seatId) {
                                      final cell = _findCell(
                                        tour,
                                        bus.id,
                                        seatId,
                                      );
                                      if (cell != null) {
                                        _showSeatFlagsSheet(cell, bus);
                                      }
                                    },
                                  ),
                                ),
                                // Canonical seat-colour key — the same legend
                                // every other role sees, so admins read
                                // GO/RET/priority/held/paid colours the same way.
                                const SizedBox(height: UgamSpacing.md),
                                UgamSeatChartLegend(c: c),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                // ─── Floating assignment dock ──────────────────────────────
                // Pinned to the bottom and OVERLAYS the chart, so opening the
                // full passenger detail grows the sheet UPWARD over the grid
                // instead of squeezing it. Collapsed by default → whole chart
                // visible. When every seat is filled `passenger` is null, so
                // the dock shows only its "all assigned · Lock & notify"
                // done-state (no duplicate "all seats assigned" card).
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _AssignmentDock(
                    c: c,
                    tour: tour,
                    passenger: (passenger != null && !allAssigned)
                        ? passenger
                        : null,
                    pendingLines: passenger != null
                        ? _pendingLines(passenger)
                        : const [],
                    handlerId: tour.handlerId,
                    onManageBuses: () =>
                        Get.to(() => ManageBusesScreen(tourId: widget.tourId)),
                    pending: pending,
                    activeId: passenger?.id,
                    onTapPassenger: (id) => _selectPassenger(tour, id),
                    // Dragging a dock chip onto a seat: flag the pending drag so
                    // the grid lights up the seats this rider fits, then clear it.
                    onPendingDragStarted: (id) => setState(() {
                      _pendingDragId = id;
                      _dragActive = true;
                    }),
                    onPendingDragEnded: () => setState(() {
                      _pendingDragId = null;
                      _dragActive = false;
                    }),
                    onLockTour: canLock ? () => _openLockAndNotify(tour) : null,
                    onDownloadChart: canDownload
                        ? () => _downloadChart(tour)
                        : null,
                    expanded: _dockExpanded,
                    onToggleExpanded: () =>
                        setState(() => _dockExpanded = !_dockExpanded),
                    onSetExpanded: (v) {
                      if (_dockExpanded != v) {
                        setState(() => _dockExpanded = v);
                      }
                    },
                  ),
                ),
              ],
            );
          }),
        ),
      ],
    );

    // Embedded: body only — the SeatsScreen shell owns the Scaffold/header.
    if (widget.embedded) return content;
    return UgamScaffold(body: SafeArea(bottom: false, child: content));
  }
}
