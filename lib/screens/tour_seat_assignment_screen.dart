import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'fullscreen_chart_screen.dart';
import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
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
import '../services/seat_swap_guard.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_drop_engine.dart';
import '../utils/seat_fit.dart';
import '../utils/seat_leg_capacity.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
import '../widgets/occupant_action_sheet.dart';
import '../widgets/chart_footer_sheet.dart';
import '../widgets/edit_request_sheet.dart';
import 'add_return_ticket_sheet.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'requests_screen.dart';

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
///   * `_pendingLines`, `_berthsForFreeCell`, `_onSeatTapped`,
///     `_drainPending`, `_findCell`, `_lockTour`. (Handler assignment is now
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
    if (id != null) {
      final match = tour.buses.where((b) => b.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    return tour.buses.first;
  }

  Passenger? _selectedPassenger(Tour tour) {
    if (tour.passengers.isEmpty) return null;
    final id = _selectedPassengerId;
    if (id != null) {
      final match = tour.passengers.where((p) => p.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    // Default to the first un- or partially-assigned passenger.
    final partial = tour.passengers.where((p) => !p.isFullyAssigned).toList();
    if (partial.isNotEmpty) return partial.first;
    return tour.passengers.first;
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

  /// All seats assigned to anyone, indexed by bus then seat.
  ///
  /// One pass over `tour.passengers × assignedSeats` produces the maps
  /// for every bus on the tour at once — far cheaper than the previous
  /// per-bus filter, which `build()` invoked N+1 times (once for the
  /// selected bus, plus once per pill in `_BusStrip`'s
  /// `seatsAssignedFor` callback). A `doubleSofa` cell may carry up to
  /// two passenger IDs when the agent has split the sofa between two
  /// unrelated singles; insertion order is preserved so the first
  /// occupant renders on the left half of a split tile.
  Map<String, Map<String, List<String>>> _assignmentsByBus(Tour tour) {
    final out = <String, Map<String, List<String>>>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        ((out[a.busId] ??= <String, List<String>>{})[a.seatId] ??= <String>[])
            .add(p.id);
      }
    }
    return out;
  }

  /// Backwards-compatible single-bus accessor for code paths (e.g. the
  /// tap handler) that don't have a precomputed `assignmentsByBus`
  /// handy.
  Map<String, List<String>> _assignmentMap(Tour tour, String busId) {
    final map = <String, List<String>>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == busId) {
          (map[a.seatId] ??= <String>[]).add(p.id);
        }
      }
    }
    return map;
  }

  /// Pending request lines for the passenger after subtracting what's
  /// already been assigned.
  ///
  /// The draining math (which held berth satisfies which request line,
  /// cross-fill, own-cell double completion, leg-aware reuse) now lives in the
  /// shared, pure [computePendingLines] so the manual screen matches the auto
  /// seating engine BY CONSTRUCTION. This wrapper just adapts the passenger /
  /// tour models into the module's value inputs and maps the module's
  /// aggregated `remaining` back onto the original per-line `_PendingLine`s so
  /// the displayed `X/Y` progress (which needs each line's `totalRequested`)
  /// stays exact.
  List<_PendingLine> _pendingLines(Passenger passenger, {Tour? tour}) {
    // One `_PendingLine` per ORIGINAL request line (preserves order + the
    // per-line totalRequested the progress label renders). `remaining` starts
    // full and is reduced below from the module's verdict.
    final lines = [
      for (final line in passenger.requestLines)
        _PendingLine(
          seatType: line.seatType,
          position: line.position,
          remaining: line.qty,
          totalRequested: line.qty,
        ),
    ];

    final t = tour ?? _tour;
    if (t == null) return lines;

    final result = computePendingLines(
      requestLines: [
        for (final line in passenger.requestLines)
          PendingLineInput(
            seatType: line.seatType,
            position: line.position,
            qty: line.qty,
          ),
      ],
      heldBerths: [
        for (final a in passenger.assignedSeats)
          HeldBerth(busId: a.busId, seatId: a.seatId),
      ],
      ctx: _seatFitContext(t),
      // The own-cell double-completion case the manual screen historically
      // MISSED: a passenger holding ONE berth of a Double Sofa whose partner
      // berth is still leg-free, with a matching pending doubleSofa line. The
      // module decides it and asks here whether the partner berth is actually
      // claimable; we answer with the SAME per-leg rule the engine uses.
      canClaimPartnerBerth: (claim) =>
          _canClaimPartnerBerth(t, passenger, claim),
    );

    // Map the aggregated `remaining` (keyed by seatType+position) back onto the
    // original lines, in order. Each original line keeps its totalRequested;
    // its `remaining` is whatever the module still leaves unsatisfied for that
    // (type, position) bucket, distributed across matching lines first-come.
    final leftover = <(SeatType, SeatPosition?), int>{};
    for (final r in result.remaining) {
      leftover[(r.seatType, r.position)] =
          (leftover[(r.seatType, r.position)] ?? 0) + r.qty;
    }
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final key = (l.seatType, l.position);
      final pool = leftover[key] ?? 0;
      final keep = pool >= l.totalRequested ? l.totalRequested : pool;
      leftover[key] = pool - keep;
      lines[i] = _PendingLine(
        seatType: l.seatType,
        position: l.position,
        remaining: keep,
        totalRequested: l.totalRequested,
      );
    }
    return lines;
  }

  /// Pure cell-lookup adapter the shared [computePendingLines] /
  /// [berthsForFreeCell] use to resolve a cell's type + position from
  /// (busId, seatId) against the tour layout.
  SeatFitContext _seatFitContext(Tour tour) => SeatFitContext(
    cellTypeAt: (busId, seatId) => _findCell(tour, busId, seatId)?.seatType,
    cellPositionAt: (busId, seatId) => _findCell(tour, busId, seatId)?.position,
  );

  /// Answers the module's own-cell double-completion question with the SAME
  /// per-leg model the auto engine uses: the partner berth of [claim]'s Double
  /// Sofa is claimable when there is still leg room for ONE MORE berth on
  /// [passenger]'s trip after accounting for everyone ALREADY on that cell —
  /// including [passenger]'s OWN already-held berth (which, like the engine's
  /// locked berth, has already consumed a per-leg slot before the partner is
  /// claimed). The engine answers this against its plan state; here we read the
  /// live tour.
  bool _canClaimPartnerBerth(
    Tour tour,
    Passenger passenger,
    PendingClaim claim,
  ) {
    final holders = <SeatLegHolder>[
      for (final p in tour.passengers)
        for (final n in [
          p.assignedSeats
              .where((a) => a.busId == claim.busId && a.seatId == claim.seatId)
              .length,
        ])
          if (n > 0) (trip: p.legForSeat(claim.seatId, busId: claim.busId), berths: n),
    ];
    return seatHasLegRoom(
      // The rider's REAL leg, not the raw stored column — which defaults to
      // round-trip and would claim a one-way rider needs both legs of their own
      // sofa. Same rule the occupant side above and [_berthsForCell] use.
      activeTrip: passenger.effectiveTripType,
      need: 1,
      cap: 2,
      occupants: holders,
    );
  }

  SeatCell? _findCell(Tour tour, String busId, String seatId) {
    final bus = tour.buses.where((b) => b.id == busId).firstOrNull;
    final layout = bus?.layout;
    if (layout == null) return null;
    for (final c in layout.grid) {
      if (c.seatId == seatId) return c;
    }
    return null;
  }

  /// How many berths to claim when this passenger taps an unoccupied
  /// cell. Returns 0 when the cell's type doesn't match anything pending.
  ///
  /// Routes through the shared, pure [berthsForFreeCell] so the type/position
  /// matching matrix AND the per-leg capacity gate are the SAME single rule the
  /// auto engine and the occupied-cell path use. A genuinely free cell has no
  /// occupants, so the leg gate is trivially satisfied; the unified rule means
  /// "what the tap offers" and "what placement accepts" can no longer diverge
  /// (symptoms B & C).
  int _berthsForFreeCell(Passenger passenger, SeatCell cell, {Tour? tour}) {
    return _berthsForCell(passenger, cell, const <SeatLegHolder>[], tour: tour);
  }

  /// Shared core for both the free-cell tap ([_berthsForFreeCell], empty
  /// [occupants]) and the share-onto-occupied path ([_seatHereBerths], real
  /// holders). Drains the passenger's pending lines, then asks the shared
  /// module how many berths the (free or occupied) [cell] can take.
  int _berthsForCell(
    Passenger passenger,
    SeatCell cell,
    List<SeatLegHolder> occupants, {
    Tour? tour,
  }) {
    final cellType = cell.seatType;
    if (cellType == null) return 0; // empty / aisle cell — nothing to claim
    final remaining = [
      for (final l in _pendingLines(passenger, tour: tour))
        if (l.remaining > 0)
          PendingLineInput(
            seatType: l.seatType,
            position: l.position,
            qty: l.remaining,
          ),
    ];
    return berthsForFreeCell(
      remaining: remaining,
      cellType: cellType,
      cellPosition: cell.position,
      // Gate on the per-LINE derived leg, not the coarse stored [tripType]
      // (which defaults to roundTrip). A pure return-only rider whose stored
      // field was never stamped was wrongly treated as needing BOTH legs, so
      // the leg gate refused a GO-occupied but RET-free seat — the exact
      // "can't place my return-only passenger" case. Matches how occupant legs
      // are already resolved per-seat in [_seatHereBerths].
      activeTrip: passenger.derivedTripType,
      cap: cellType == SeatType.doubleSofa ? 2 : 1,
      occupants: occupants,
    );
  }

  void _onSeatTapped(SeatCell cell, Bus bus, Tour tour) {
    HapticFeedback.selectionClick();
    if (cell.isEmpty || cell.seatId == null) return;

    // Relocate mode → the tapped seat is the TARGET for the in-hand mover: a
    // free seat moves them here (after confirm), an occupied seat opens the
    // occupant menu with a "seat [mover] here" swap.
    if (_relocate != null) {
      _onRelocateSeatTapped(cell, bus, tour);
      return;
    }

    final assignmentMap = _assignmentMap(tour, bus.id);
    final owners = assignmentMap[cell.seatId] ?? const <String>[];

    // Occupied seat. Tap-to-place FIRST: with a pending rider in hand who has
    // leg-free room to SHARE this seat (e.g. a return-only rider onto a seat
    // held GO-only), seat them directly with a share-confirm — the same one-tap
    // flow as a free seat, instead of making the agent dig it out of the
    // occupant sheet. This is the missing gesture for placing a one-leg rider
    // onto a leg-free seat. If they don't fit, fall through to the sheet.
    if (owners.isNotEmpty) {
      final activeId = _selectedPassengerId;
      if (activeId != null) {
        final active =
            tour.passengers.firstWhereOrNull((p) => p.id == activeId);
        if (active != null &&
            !active.isFullyAssigned &&
            !active.isWaitlisted &&
            !owners.contains(active.id)) {
          final occupants = _resolveOccupants(tour, owners);
          final berths = _seatHereBerths(tour, bus, cell, active, occupants);
          if (berths > 0 && occupants.isNotEmpty) {
            _seatHere(active, bus, tour, cell, occupants.first, berths);
            return;
          }
        }
      }

      // No pending rider fits here → open the shared occupant action sheet
      // (manage anyone sitting here: call / move / swap / move-to-another-bus /
      // free, with a person toggle for a shared sofa). When a passenger is
      // mid-placement and the seat can be shared, the sheet also offers "seat
      // [name] here" (and swap-in when the leg is full).
      _openOccupantSheet(
        cell,
        bus,
        tour,
        owners,
        active: _selectedPassenger(tour),
      );
      return;
    }

    // Free seat. When a passenger is ALREADY selected (chip / dock / deep-link)
    // and this cell fits them, place them immediately — no picker. The picker
    // only appears when nobody is selected (or the selected passenger doesn't
    // fit this cell but others would), so seat-first assignment still works.
    final activeId = _selectedPassengerId;
    if (activeId != null) {
      final active = tour.passengers.firstWhereOrNull((p) => p.id == activeId);
      if (active != null && !active.isFullyAssigned && !active.isWaitlisted) {
        final berths = _berthsForFreeCell(active, cell, tour: tour);
        if (berths > 0) {
          _placeBerths(active, bus, tour, cell, berths);
          return;
        }
      }
    }

    // Nobody selected (or the selected passenger doesn't fit) → show the picker
    // of pending passengers who can sit here, so the agent assigns seat-first.
    _openSeatPicker(cell, bus, tour);
  }

  /// A PENDING rider was DRAGGED from the dock onto [seatId]. Places them the
  /// same way a tap would: a free cell takes them directly; a leg-free occupied
  /// cell shares them in (a return-only rider onto a GO-held seat); otherwise a
  /// toast explains there is no room. The hard berth cap in [_placeBerths] still
  /// guards over-allocation, so this can never seat more than requested.
  void _handlePendingDropToSeat(
    Tour tour,
    Bus bus,
    String passengerId,
    String seatId,
  ) {
    final passenger =
        tour.passengers.firstWhereOrNull((p) => p.id == passengerId);
    final cell = _findCell(tour, bus.id, seatId);
    if (passenger == null || cell == null) return;
    if (passenger.isFullyAssigned || passenger.isWaitlisted) return;

    // Keep the dropped rider as the active selection so the chart context (and
    // any follow-up placement of their remaining berths) stays on them.
    _selectPassenger(tour, passengerId);

    final owners = _assignmentMap(tour, bus.id)[seatId] ?? const <String>[];

    // Free seat → place directly.
    if (owners.isEmpty) {
      final berths = _berthsForFreeCell(passenger, cell, tour: tour);
      if (berths > 0) {
        _placeBerths(passenger, bus, tour, cell, berths);
      } else {
        AppSnackBar.warning(
          tr('tour_seat_assignment.picker_none', namedArgs: {'seat': seatId}),
        );
      }
      return;
    }

    // Occupied seat → share into the leg-free room if there is any.
    if (owners.contains(passengerId)) return; // already sitting here
    final occupants = _resolveOccupants(tour, owners);
    final berths = _seatHereBerths(tour, bus, cell, passenger, occupants);
    if (berths > 0 && occupants.isNotEmpty) {
      _seatHere(passenger, bus, tour, cell, occupants.first, berths);
    } else {
      AppSnackBar.warning(
        tr('tour_seat_assignment.picker_none', namedArgs: {'seat': seatId}),
      );
    }
  }

  /// Tap an empty seat → list the pending passengers who can take it (their
  /// request still has a matching, unplaced line). Picking one seats them here.
  void _openSeatPicker(SeatCell cell, Bus bus, Tour tour) {
    final activeId = _selectedPassengerId;
    final candidates =
        tour.passengers
            .where(
              (p) =>
                  !p.isFullyAssigned &&
                  !p.isWaitlisted &&
                  _berthsForFreeCell(p, cell, tour: tour) > 0,
            )
            .toList()
          // Surface the currently-selected passenger first.
          ..sort((a, b) {
            if (a.id == activeId) return -1;
            if (b.id == activeId) return 1;
            return 0;
          });

    if (candidates.isEmpty) {
      AppSnackBar.warning(
        tr(
          'tour_seat_assignment.picker_none',
          namedArgs: {'seat': cell.seatId ?? ''},
        ),
      );
      return;
    }

    UgamSheet.show<void>(
      context,
      title: tr(
        'tour_seat_assignment.picker_title',
        namedArgs: {'seat': cell.seatId ?? '', 'bus': bus.name},
      ),
      builder: (sheetCtx) => _SeatPassengerPicker(
        candidates: candidates,
        activeId: activeId,
        onPick: (p) {
          Navigator.of(sheetCtx).pop();
          _placeBerths(
            p,
            bus,
            tour,
            cell,
            _berthsForFreeCell(p, cell, tour: tour),
          );
        },
      ),
    );
  }

  /// Open the shared occupant action sheet for the people on [cell]. When
  /// [active] is a passenger mid-placement and the cell is a doubleSofa that can
  /// still take a half-share (one occupant + a matching pending line), surface
  /// the "seat [active] here" share action inside the sheet.
  /// The distinct [Passenger] models for the ids sitting on a seat, in owner
  /// order (deduped — a whole-double owner appears twice in [owners]).
  List<Passenger> _resolveOccupants(Tour tour, List<String> owners) {
    final byId = {for (final p in tour.passengers) p.id: p};
    final seen = <String>{};
    final occupants = <Passenger>[];
    for (final id in owners) {
      if (seen.add(id)) {
        final p = byId[id];
        if (p != null) occupants.add(p);
      }
    }
    return occupants;
  }

  void _openOccupantSheet(
    SeatCell cell,
    Bus bus,
    Tour tour,
    List<String> owners, {
    Passenger? active,
  }) {
    final occupants = _resolveOccupants(tour, owners);
    if (occupants.isEmpty) return;

    Passenger? placing;
    VoidCallback? onSeatHere;
    VoidCallback? onSwapIn;
    if (active != null && !owners.contains(active.id)) {
      final berths = _seatHereBerths(tour, bus, cell, active, occupants);
      if (berths > 0) {
        placing = active;
        onSeatHere = () =>
            _seatHere(active, bus, tour, cell, occupants.first, berths);
      } else {
        // No leg room to SHARE — but the active passenger may still belong here
        // if we bump the occupant who actually blocks their leg. Pick that one
        // occupant, then confirm the active rider fits once they're gone, so the
        // swap never overbooks the cell (and the other leg-share stays put).
        final conflict =
            _conflictingOccupant(active, occupants, cell.seatId!, bus.id);
        if (conflict != null) {
          final remaining =
              occupants.where((o) => o.id != conflict.id).toList();
          final berthsAfter =
              _seatHereBerths(tour, bus, cell, active, remaining);
          if (berthsAfter > 0) {
            placing = active;
            onSwapIn = () =>
                _swapInPlacing(active, bus, tour, cell, conflict, berthsAfter);
          }
        }
      }
    }

    OccupantActionSheet.show(
      context,
      occupants: occupants,
      tourId: tour.id,
      busId: bus.id,
      seatId: cell.seatId!,
      busName: bus.name,
      placing: placing,
      onSeatHere: onSeatHere,
      onSwapIn: onSwapIn,
      // "Move or swap" → pick a destination bus → hand back here so the agent
      // lands on that bus's chart and taps the exact target seat by hand.
      onRelocateToBus: _beginRelocate,
      // Return phase: cancel a return seat, then offer to rebook it in place.
      onCancelReturn: _cancelReturnSeatFlow,
      // Seat Hold/Premium flags for this seat — the tap-menu home for the old
      // edit-seats mode (empty seats reach the same sheet via long-press).
      onSeatFlags: () => _showSeatFlagsSheet(cell, bus),
    );
  }

  /// Cancel an occupant's return seat (freeing it), then offer to book a
  /// replacement return ticket straight into the just-freed seat. Only reachable
  /// once the tour is in its return phase (the sheet gates the entry point).
  Future<void> _cancelReturnSeatFlow(Passenger occ) async {
    final ok = await _confirmSheet(
      context,
      title: tr('tour_detail.cancel_return_confirm_title'),
      message: tr('tour_detail.cancel_return_confirm_body',
          namedArgs: {'name': occ.displayName}),
      confirmLabel: tr('tour_detail.cancel_return_cta'),
      destructive: true,
      confirmIcon: Icons.event_busy_rounded,
    );
    if (!ok) return;
    await _ctrl.cancelReturnSeat(widget.tourId, occ.id);
    if (!mounted) return;
    AppSnackBar.success(tr('tour_detail.cancel_return_done',
        namedArgs: {'name': occ.displayName}));

    final rebook = await _confirmSheet(
      context,
      title: tr('tour_detail.cancel_return_rebook_title'),
      message: tr('tour_detail.cancel_return_rebook_body'),
      confirmLabel: tr('tour_detail.add_return_ticket'),
      confirmIcon: Icons.event_seat_rounded,
    );
    if (!rebook || !mounted) return;
    final tour = _tour;
    if (tour != null) AddReturnTicketSheet.show(context, tour);
  }

  // ── Cross-bus relocate (tap-to-place hand-off) ──────────────────────────
  //
  // The move flow's destination picker calls [_beginRelocate] instead of the
  // auto swap-assistant: the chart switches to the chosen bus and the mover is
  // held "in hand". The next seat tap then MOVES them onto a free seat (after a
  // confirm) or SWAPS them with an occupant — using the cross-bus
  // [TourController.moveSeat] / [swapSeats] under the hood.

  /// Switch the chart to [destination] and enter relocate mode for [mover]
  /// (remembering the seat they currently sit on so the move/swap can be
  /// applied). Triggered from the occupant sheet's "move or swap" → bus picker.
  void _beginRelocate(
    Bus destination,
    Passenger mover,
    String sourceBusId,
    String fromSeatId,
  ) {
    setState(() {
      _selectedBusId = destination.id;
      _selectedPassengerId = mover.id;
      _relocate = (
        mover: mover,
        fromBusId: sourceBusId,
        fromSeatId: fromSeatId,
      );
    });
    AppSnackBar.info(
      tr(
        'tour_seat_assignment.relocate.started',
        namedArgs: {'name': mover.displayName, 'bus': destination.name},
      ),
    );
  }

  void _cancelRelocate() {
    if (_relocate == null) return;
    setState(() => _relocate = null);
  }

  /// A seat was tapped while a relocate is in progress. Route to a move (free
  /// seat) or a swap (occupied seat).
  void _onRelocateSeatTapped(SeatCell cell, Bus bus, Tour tour) {
    final reloc = _relocate;
    if (reloc == null) return;
    final mover =
        tour.passengers.firstWhereOrNull((p) => p.id == reloc.mover.id) ??
        reloc.mover;

    final owners =
        (_assignmentMap(tour, bus.id)[cell.seatId] ?? const <String>[])
            .toList();
    final others = owners.where((id) => id != mover.id).toList();

    // The mover's OWN seat (same-bus tap) — nothing to do.
    if (others.isEmpty && owners.isNotEmpty) return;

    if (others.isNotEmpty) {
      _relocateOntoOccupied(cell, bus, tour, mover, reloc, others);
    } else {
      _relocateOntoFree(cell, bus, tour, mover, reloc);
    }
  }

  /// Berths [mover] holds on their source cell — 2 for a whole double, else 1.
  int _relocateMoverBerths(
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    Passenger mover,
  ) {
    return mover.assignedSeats
        .where(
          (a) => a.busId == reloc.fromBusId && a.seatId == reloc.fromSeatId,
        )
        .length;
  }

  /// Move [mover] onto a FREE [cell] of [bus] after a confirm. Guards seat size
  /// so a whole-double mover can't be crammed onto a single-capacity cell.
  Future<void> _relocateOntoFree(
    SeatCell cell,
    Bus bus,
    Tour tour,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
  ) async {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final targetCap = cell.seatType == SeatType.doubleSofa ? 2 : 1;
    final moverBerths = _relocateMoverBerths(reloc, mover);
    // When the mover holds MORE berths on the source cell than the target can
    // take — e.g. two single-request berths cross-filled onto one Double Sofa,
    // now moving back to a Single Sofa (2 > 1) — PEEL a single berth onto the
    // target instead of refusing the move. The remaining berth(s) stay on the
    // source cell, so a second drag relocates them too. This mirrors
    // SeatMoveFlow.moveTo / the swap-sheet "take free" path, so drag and sheet
    // behave identically (previously the drag path alone rejected with a
    // "too small" warning, stranding split berths on a double).
    final berthsToMove = moverBerths > targetCap ? targetCap : null;

    // Dropping ONE single berth onto a FREE Double Sofa, and the passenger holds
    // another single elsewhere on this bus? Offer to pair BOTH singles onto the
    // double (a double seats two) or just this one. This choice dialog doubles
    // as the move confirmation.
    if (cell.seatType == SeatType.doubleSofa && moverBerths == 1) {
      final otherSeatId = _otherSingleSeatId(tour, bus, mover, reloc.fromSeatId);
      if (otherSeatId != null) {
        final both = await _askMoveBothOrOne(seatId: seatId, name: mover.displayName);
        if (both == null) return; // cancelled
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: reloc.fromBusId,
          fromSeatId: reloc.fromSeatId,
          toSeatId: seatId,
          toBusId: bus.id,
        );
        if (both) {
          await _ctrl.moveSeat(
            tourId: tour.id,
            passengerId: mover.id,
            busId: bus.id,
            fromSeatId: otherSeatId,
            toSeatId: seatId,
            toBusId: bus.id,
          );
        }
        if (!mounted) return;
        setState(() => _relocate = null);
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.relocate.moved',
            namedArgs: {'name': mover.displayName, 'seat': seatId},
          ),
        );
        return;
      }
    }

    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.relocate.move_confirm_title'),
      message: tr(
        'tour_seat_assignment.relocate.move_confirm_body',
        namedArgs: {'name': mover.displayName, 'seat': seatId, 'bus': bus.name},
      ),
      confirmLabel: tr('tour_seat_assignment.relocate.move_confirm_yes'),
    );
    if (!confirmed) return;

    await _ctrl.moveSeat(
      tourId: tour.id,
      passengerId: mover.id,
      busId: reloc.fromBusId,
      fromSeatId: reloc.fromSeatId,
      toSeatId: seatId,
      toBusId: bus.id,
      berths: berthsToMove,
    );
    if (!mounted) return;
    setState(() => _relocate = null);
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.relocate.moved',
        namedArgs: {'name': mover.displayName, 'seat': seatId},
      ),
    );
  }

  /// The seatId of ANOTHER single-sofa berth [mover] holds on [bus] (other than
  /// [fromSeatId]) — the pairing candidate when a single is dropped onto a free
  /// double. Null when the passenger has no second single on this bus.
  String? _otherSingleSeatId(
    Tour tour,
    Bus bus,
    Passenger mover,
    String fromSeatId,
  ) {
    for (final a in mover.assignedSeats) {
      if (a.busId != bus.id) continue;
      if (a.seatId == fromSeatId) continue;
      if (_findCell(tour, bus.id, a.seatId)?.seatType == SeatType.singleSofa) {
        return a.seatId;
      }
    }
    return null;
  }

  /// Ask whether to move BOTH of the passenger's singles onto the double, or
  /// just the dragged one. true = both, false = just this one, null = cancelled.
  Future<bool?> _askMoveBothOrOne({
    required String seatId,
    required String name,
  }) {
    final c = UgamColors.of(context);
    return UgamSheet.show<bool>(
      context,
      title: tr('tour_seat_assignment.relocate.pair_title'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              'tour_seat_assignment.relocate.pair_body',
              namedArgs: {'name': name, 'seat': seatId},
            ),
            style: UgamText.body.copyWith(color: c.ink2, height: 1.4),
          ),
          const SizedBox(height: UgamSpacing.xl),
          // Two stacked full-width tonal choices — neither is "the" primary, so
          // both stay tonal (gold stays rationed); the agent picks intent.
          UgamButton(
            kind: UgamButtonKind.tonal,
            label: tr('tour_seat_assignment.relocate.pair_both'),
            icon: Icons.group_add_rounded,
            expand: true,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamButton(
            kind: UgamButtonKind.tonal,
            label: tr('tour_seat_assignment.relocate.pair_one'),
            icon: Icons.person_rounded,
            expand: true,
            onPressed: () => Navigator.of(sheetCtx).pop(false),
          ),
        ],
      ),
    );
  }

  /// An occupied seat was tapped while relocating: open the full occupant menu
  /// (manage the occupant) with a "seat [mover] here" action that SWAPS the
  /// mover with the occupant (after a confirm).
  void _relocateOntoOccupied(
    SeatCell cell,
    Bus bus,
    Tour tour,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    List<String> ownerIds,
  ) {
    final byId = {for (final p in tour.passengers) p.id: p};
    final occupants = <Passenger>[
      for (final id in ownerIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (occupants.isEmpty) return;

    OccupantActionSheet.show(
      context,
      occupants: occupants,
      tourId: tour.id,
      busId: bus.id,
      seatId: cell.seatId!,
      busName: bus.name,
      // "Seat [mover] here" → swap the mover with this occupant.
      placing: mover,
      onSeatHere: () =>
          _relocateSwap(cell, bus, tour, mover, reloc, occupants.first),
    );
  }

  /// Swap [mover] (on their source seat) with [other] (on the tapped [cell]),
  /// across buses, after a confirm.
  Future<void> _relocateSwap(
    SeatCell cell,
    Bus bus,
    Tour tour,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    Passenger other,
  ) async {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.relocate.swap_confirm_title'),
      message: tr(
        'tour_seat_assignment.relocate.swap_confirm_body',
        namedArgs: {
          'mover': mover.displayName,
          'other': other.displayName,
          'seat': seatId,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.relocate.swap_confirm_yes'),
    );
    if (!confirmed) return;
    if (!mounted) return;

    await SeatSwapGuard.run(
      context,
      tourId: tour.id,
      busAId: reloc.fromBusId,
      passengerAId: mover.id,
      seatAId: reloc.fromSeatId,
      passengerBId: other.id,
      seatBId: seatId,
      busBId: bus.id,
    );
    if (!mounted) return;
    setState(() => _relocate = null);
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.relocate.swapped',
        namedArgs: {'mover': mover.displayName, 'other': other.displayName},
      ),
    );
  }

  /// Berths the mid-placement [active] passenger could take on an ALREADY-
  /// occupied [cell] — 0 when no compatible, leg-free room exists. Covers two
  /// cases through one rule:
  ///   * SAME-leg share of a Double Sofa (two singles split the two berths);
  ///   * leg-DISJOINT reuse — an outbound-only seat reused by a return-only
  ///     rider (or vice-versa), so the SAME sofa serves GO and RETURN.
  ///
  /// Capacity is tracked PER LEG: the cell holds [cap] berths on the GO leg and
  /// [cap] on the RETURN leg independently. A one-way occupant fills only its
  /// own leg, leaving the other leg free for an opposite-leg rider; a round-trip
  /// occupant fills BOTH legs and blocks any reuse.
  int _seatHereBerths(
    Tour tour,
    Bus bus,
    SeatCell cell,
    Passenger active,
    List<Passenger> occupants,
  ) {
    final seatId = cell.seatId;
    if (seatId == null) return 0;

    // Build the real per-leg holders on this cell, then defer to the SAME
    // shared rule the free-cell path uses. This unifies "share onto occupied"
    // and "place on free" into one type/position + per-leg gate (symptoms B/C).
    final holders = <SeatLegHolder>[
      for (final o in occupants)
        (
          // Per-SEAT leg (a.leg ?? tripType), NOT the coarse overall trip: a
          // rider who holds THIS seat on only one leg leaves the other leg free
          // to share. Reading o.tripType wrongly treated a mixed-leg rider
          // (stored roundTrip) as occupying BOTH legs and refused the share —
          // aligns this with seat_render, amountDueForSeat and the capacity
          // engine, which all resolve per-seat via legForSeat.
          trip: o.legForSeat(seatId, busId: bus.id),
          berths: o.assignedSeats
              .where((a) => a.busId == bus.id && a.seatId == seatId)
              .length,
        ),
    ];

    return _berthsForCell(active, cell, holders, tour: tour);
  }

  /// Confirm + seat [passenger] onto the already-occupied [cell] — either
  /// sharing a Double Sofa half or reusing the seat on the opposite leg from
  /// [other]. Places [berths] berths (1 for a half/single, 2 for a whole-double
  /// reuse).
  Future<void> _seatHere(
    Passenger passenger,
    Bus bus,
    Tour tour,
    SeatCell cell,
    Passenger other,
    int berths,
  ) async {
    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.share_confirm_title'),
      message: tr(
        'tour_seat_assignment.share_confirm_body',
        namedArgs: {
          'seat': cell.seatId!,
          'otherName': other.displayName,
          'currentName': passenger.displayName,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.share_confirm_yes'),
    );
    if (!confirmed) return;
    await _placeBerths(passenger, bus, tour, cell, berths);
  }

  /// True when trips [a] and [b] both ride the SAME physical leg — so they
  /// genuinely compete for one berth (vs a GO-only + RET-only pair that can
  /// share a single seat across disjoint legs).
  bool _tripsOverlap(TripType a, TripType b) =>
      (a.usesOutbound && b.usesOutbound) || (a.usesReturn && b.usesReturn);

  /// The single occupant whose leg collides with [active]'s — the one a swap
  /// must bump so [active] can take the berth. Returns null when the collision
  /// is ambiguous (two occupants both overlap, e.g. a round-trip rider onto a
  /// GO+RET leg-shared seat) so we never guess and overbook.
  Passenger? _conflictingOccupant(
    Passenger active,
    List<Passenger> occupants,
    String seatId,
    String busId,
  ) {
    final overlap = occupants
        .where((o) => _tripsOverlap(
            o.legForSeat(seatId, busId: busId), active.effectiveTripType))
        .toList();
    if (overlap.length == 1) return overlap.first;
    if (overlap.isEmpty && occupants.length == 1) return occupants.first;
    return null;
  }

  /// Swap [placing] INTO an occupied [cell] by freeing the leg-conflicting
  /// [occupant] (they return to the pending pool, ready to re-seat) and then
  /// seating [placing] on the [berths] that opens up. Used when the seat is full
  /// on [placing]'s leg so a plain share isn't possible — turning the old
  /// dead-end "no room on this leg" into an actionable swap.
  Future<void> _swapInPlacing(
    Passenger placing,
    Bus bus,
    Tour tour,
    SeatCell cell,
    Passenger occupant,
    int berths,
  ) async {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.swap_in_confirm_title'),
      message: tr(
        'tour_seat_assignment.swap_in_confirm_body',
        namedArgs: {
          'placing': placing.displayName,
          'occupant': occupant.displayName,
          'seat': seatId,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.swap_in_confirm_yes'),
    );
    if (!confirmed) return;

    // 1. Free the conflicting occupant's berth(s) on THIS seat only — they keep
    //    their request and drop back into the pending pool.
    final occNext = occupant.assignedSeats
        .where((a) => !(a.busId == bus.id && a.seatId == seatId))
        .toList();
    await _ctrl.assignSeats(tour.id, occupant.id, occNext);

    // 2. Seat the placing passenger on the freed berth(s).
    final freshTour = _ctrl.getTour(tour.id) ?? tour;
    await _placeBerths(placing, bus, freshTour, cell, berths);
  }

  /// Add [berths] berths of [cell] to [passenger], persist, then auto-advance
  /// to the next unassigned passenger when this one is fully seated.
  Future<void> _placeBerths(
    Passenger passenger,
    Bus bus,
    Tour tour,
    SeatCell cell,
    int berths,
  ) async {
    // Hard block over-allocation: a rider may never be assigned MORE berths than
    // requested. Every placement path (free-cell tap, seat-here share, swap-in,
    // seat picker) funnels through here, so this single guard caps them all —
    // e.g. a 2-berth double request can't grab a single + a whole double (3).
    final remaining = passenger.remainingBerths;
    if (berths > remaining) {
      AppSnackBar.warning(
        tr(
          'tour_seat_assignment.over_allocate_body',
          namedArgs: {
            'passengerName': passenger.displayName,
            'remaining': '$remaining',
          },
        ),
        title: tr('tour_seat_assignment.over_allocate_title'),
      );
      return;
    }

    final next = List<SeatAssignment>.from(passenger.assignedSeats);
    for (var i = 0; i < berths; i++) {
      next.add(SeatAssignment(busId: bus.id, seatId: cell.seatId!));
    }
    await _ctrl.assignSeats(tour.id, passenger.id, next);

    final updatedTour = _ctrl.getTour(tour.id);
    final updatedPassenger = updatedTour?.passengers.firstWhere(
      (p) => p.id == passenger.id,
      orElse: () => passenger,
    );

    if (updatedPassenger != null && updatedPassenger.isFullyAssigned) {
      AppSnackBar.success(
        tr(
          'tour_seat_assignment.snack_fully_assigned_body',
          namedArgs: {'passengerName': passenger.displayName},
        ),
        title: tr('tour_seat_assignment.snack_fully_assigned_title'),
      );
      HapticFeedback.lightImpact();

      final nextUnassigned = updatedTour!.passengers
          .where((p) => !p.isFullyAssigned && !p.journeyDone)
          .toList();
      if (nextUnassigned.isNotEmpty) {
        setState(() => _selectedPassengerId = nextUnassigned.first.id);
      } else if (updatedTour.handlerId != null) {
        AppSnackBar.success(
          tr('tour_seat_assignment.snack_all_done_body'),
          title: tr('tour_seat_assignment.snack_all_done_title'),
        );
      } else {
        AppSnackBar.warning(tr('tour_seat_assignment.snack_no_handler'));
      }
    } else {
      AppSnackBar.success(
        tr(
          'tour_seat_assignment.snack_seat_saved',
          namedArgs: {'seatId': cell.seatId!},
        ),
      );
      HapticFeedback.lightImpact();
    }
  }

  // ── Drag-to-move / swap / share / split ─────────────────────────────────
  //
  // The canonical [CombinedSeatGrid] owns the gesture; this screen feeds the
  // pure [decideSeatDrop] engine and dispatches its verdict. A seat is pickable
  // when it holds ONE occupant (a normal drag) OR TWO (a shared double that
  // moves as a unit). On release the engine returns move / split / swap / fill /
  // moveBoth / blocked, and the same call drives the live highlight — so what
  // the agent SEES is exactly what a drop will DO. Every drag stays SAME-BUS, so
  // groups are never split; the controller still routes through the group-safe
  // [moveSeat] / [swapSeats] / [moveSharedPair] paths.

  /// The occupants on [cell] of the selected bus, as engine [SeatOccupant]s.
  /// Empty for an empty/aisle cell; one entry for a sole occupant; two for a
  /// shared double (or a leg-disjoint reuse).
  List<SeatOccupant> _occupantsOn(
    Tour tour,
    Bus bus,
    SeatCell cell, {
    String? onlyOccupantId,
  }) {
    final seatId = cell.seatId;
    if (seatId == null) return const [];
    final ids = _assignmentMap(tour, bus.id)[seatId] ?? const <String>[];
    final seen = <String>{};
    final out = <SeatOccupant>[];
    for (final id in ids) {
      if (!seen.add(id)) continue;
      // DRAG-THE-PERSON: when a single sharer of a shared double was grabbed,
      // narrow the SOURCE occupants to just them so the engine's normal 1-berth
      // move / fill / swap path runs and the partner stays put.
      if (onlyOccupantId != null && id != onlyOccupantId) continue;
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p != null) out.add(_occupantFor(tour, bus, p, seatId));
    }
    return out;
  }

  /// Build the engine view of [p] on [seatId]: berths held here, how many WHOLE
  /// doubles they hold on this bus, and how many doubles they actually requested
  /// — the last two let the engine tell a SUBSTITUTE double (splittable) from a
  /// genuine one.
  SeatOccupant _occupantFor(Tour tour, Bus bus, Passenger p, String seatId) {
    final perCell = <String, int>{};
    for (final a in p.assignedSeats) {
      if (a.busId != bus.id) continue;
      perCell[a.seatId] = (perCell[a.seatId] ?? 0) + 1;
    }
    var wholeDoubles = 0;
    perCell.forEach((sid, n) {
      if (n < 2) return;
      if (_findCell(tour, bus.id, sid)?.seatType == SeatType.doubleSofa) {
        wholeDoubles++;
      }
    });
    final reqDoubles = p.requestLines
        .where((l) => l.seatType == SeatType.doubleSofa)
        .fold<int>(0, (s, l) => s + l.qty);
    return (
      passengerId: p.id,
      // Per-seat leg so the drag leg-share path (decideSeatDrop fill/fillPair)
      // reasons on the seat's real leg, not the coarse mixed-leg summary.
      trip: p.legForSeat(seatId, busId: bus.id),
      berthsHere: perCell[seatId] ?? 0,
      wholeDoublesHeld: wholeDoubles,
      requestedDoubleQty: reqDoubles,
    );
  }

  /// Run the drop engine for the in-flight drag onto [target].
  SeatDropDecision _decideDrop(
    Tour tour,
    Bus bus,
    SeatCell fromCell,
    SeatCell target, {
    String? grabbedOccupantId,
  }) {
    return decideSeatDrop(
      fromCell: (
        seatId: fromCell.seatId,
        seatType: fromCell.seatType,
        reserved: fromCell.reserved,
      ),
      targetCell: (
        seatId: target.seatId,
        seatType: target.seatType,
        reserved: target.reserved,
      ),
      fromOccupants: _occupantsOn(
        tour,
        bus,
        fromCell,
        onlyOccupantId: grabbedOccupantId,
      ),
      targetOccupants: _occupantsOn(tour, bus, target),
    );
  }

  /// Whether [cell] can be PICKED UP for a drag. A sole occupant always lifts; a
  /// TWO-occupant cell lifts as a unit when it is a real Double Sofa (a
  /// paired/whole double) OR a single seat reused across disjoint legs (one
  /// GO-only + one RET-only sharing one berth) — that leg-share relocates
  /// together onto a free seat. Any OTHER two-occupant non-double is managed
  /// per-person via the occupant sheet instead.
  bool _canDragSeat(Tour tour, Bus bus, SeatCell cell) {
    if (cell.reserved) {
      return false; // a held seat stays put — can't drag it off
    }
    final occs = _occupantsOn(tour, bus, cell);
    if (occs.isEmpty) return false;
    if (occs.length >= 2 &&
        cell.seatType != SeatType.doubleSofa &&
        !isLegDisjointPair(occs)) {
      return false;
    }
    return true;
  }

  /// Chip label that follows the finger — the occupant's name, or "A + B" for a
  /// shared double moving as a unit.
  String? _dragLabelFor(Tour tour, Bus bus, SeatCell cell) {
    final ids =
        (cell.seatId == null
                ? const <String>[]
                : _assignmentMap(tour, bus.id)[cell.seatId] ?? const <String>[])
            .toSet();
    if (ids.isEmpty) return null;
    final names = ids
        .map(
          (id) =>
              tour.passengers.firstWhereOrNull((p) => p.id == id)?.displayName,
        )
        .whereType<String>()
        .where((n) => n.isNotEmpty);
    return names.isEmpty ? null : names.join(' + ');
  }

  /// Live drop-target highlight for [target] against the in-flight drag. Mirrors
  /// the engine verdict used on release so the agent never sees a green ring on
  /// a drop that would be rejected.
  SeatDropHighlight _dropHighlightFor(Tour tour, Bus bus, SeatCell target) {
    // Dragging a PENDING rider from the dock → light up the seats they fit on.
    final pendingId = _pendingDragId;
    if (pendingId != null) {
      return _pendingDropHighlightFor(tour, bus, target, pendingId);
    }
    final fromSeatId = _dragFromSeatId;
    if (fromSeatId == null) return SeatDropHighlight.none;
    final targetSeatId = target.seatId;
    if (targetSeatId == null || target.isEmpty) return SeatDropHighlight.none;
    if (targetSeatId == fromSeatId) return SeatDropHighlight.none;

    final fromCell = _findCell(tour, bus.id, fromSeatId);
    if (fromCell == null) return SeatDropHighlight.none;

    final decision = _decideDrop(tour, bus, fromCell, target);
    if (decision.isValid) return SeatDropHighlight.valid;
    switch (decision.block) {
      case SeatDropBlock.self:
      case SeatDropBlock.neutral:
      case null:
        return SeatDropHighlight.none;
      case SeatDropBlock.held:
        // A reserved/held seat is PROTECTED, not merely a bad fit — paint the
        // distinct red lock so the agent can tell "can't touch this" from the
        // softer "doesn't fit here" dim.
        return SeatDropHighlight.blocked;
      default:
        return SeatDropHighlight.dim;
    }
  }

  /// Highlight for a seat while a PENDING rider is being dragged from the dock:
  /// green when the rider fits here (a free cell with room, or a leg-free
  /// occupied cell to share) AND it stays within their requested berths;
  /// otherwise no overlay. Mirrors the tap/drop placement rules.
  SeatDropHighlight _pendingDropHighlightFor(
    Tour tour,
    Bus bus,
    SeatCell target,
    String passengerId,
  ) {
    final targetSeatId = target.seatId;
    if (targetSeatId == null || target.isEmpty) return SeatDropHighlight.none;
    final passenger =
        tour.passengers.firstWhereOrNull((p) => p.id == passengerId);
    if (passenger == null ||
        passenger.isFullyAssigned ||
        passenger.isWaitlisted) {
      return SeatDropHighlight.none;
    }

    final owners = _assignmentMap(tour, bus.id)[targetSeatId] ?? const <String>[];
    if (owners.contains(passengerId)) return SeatDropHighlight.none;

    final berths = owners.isEmpty
        ? _berthsForFreeCell(passenger, target, tour: tour)
        : _seatHereBerths(
            tour, bus, target, passenger, _resolveOccupants(tour, owners));

    // Respect the hard berth cap — never invite a drop that would over-allocate.
    return (berths > 0 && berths <= passenger.remainingBerths)
        ? SeatDropHighlight.valid
        : SeatDropHighlight.none;
  }

  /// Toast explaining why a drop was rejected.
  void _toastBlocked(
    SeatDropBlock block,
    SeatCell fromCell,
    String toSeatId, {
    TripType? moverTrip,
  }) {
    switch (block) {
      case SeatDropBlock.self:
      case SeatDropBlock.neutral:
        return;
      case SeatDropBlock.classMismatch:
        AppSnackBar.warning(
          fromCell.seatType == SeatType.seater
              ? tr('tour_seat_assignment.drop.class_mismatch_seater')
              : tr('tour_seat_assignment.drop.class_mismatch_sleeper'),
          title: tr('tour_seat_assignment.drop.class_mismatch_title'),
        );
        return;
      case SeatDropBlock.tooSmall:
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.too_small_body',
            namedArgs: {
              'name':
                  _dragLabelFor(_tour!, _selectedBus(_tour!)!, fromCell) ?? '',
            },
          ),
          title: tr('tour_seat_assignment.drop.too_small_title'),
        );
        return;
      case SeatDropBlock.held:
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.held_body',
            namedArgs: {'seat': toSeatId},
          ),
          title: tr('tour_seat_assignment.drop.held_title'),
        );
        return;
      case SeatDropBlock.sharedTargetAmbiguous:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_body'),
          title: tr('tour_seat_assignment.drop.shared_title'),
        );
        return;
      case SeatDropBlock.noLegRoom:
        // Distinct from the ambiguity toast: the mover's LEG is full on the
        // target, not a size mismatch and not a one-finger-ambiguity. Name the
        // SPECIFIC leg when the rider is one-way so the agent knows exactly which
        // leg clashed (round-trip rides both, so it stays generic).
        final legKey = moverTrip == null
            ? 'tour_seat_assignment.drop.leg_both'
            : (moverTrip.usesOutbound && !moverTrip.usesReturn)
                ? 'tour_seat_assignment.drop.leg_go'
                : (moverTrip.usesReturn && !moverTrip.usesOutbound)
                    ? 'tour_seat_assignment.drop.leg_ret'
                    : 'tour_seat_assignment.drop.leg_both';
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.no_leg_room_body',
            namedArgs: {'seat': toSeatId, 'leg': tr(legKey)},
          ),
          title: tr('tour_seat_assignment.drop.no_leg_room_title'),
        );
        return;
      case SeatDropBlock.sharedNeedsFreeDouble:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_need_free_double'),
          title: tr('tour_seat_assignment.drop.shared_title'),
        );
        return;
    }
  }

  /// When a SINGLE berth is dragged onto a FREE Double Sofa, decide whether this
  /// should CONSOLIDATE the passenger's two cross-filled singles into the one
  /// double instead of a plain move. Returns the OTHER single seatId to fold in
  /// (so the source pair is `[fromSeatId, otherSeatId]`), or null when this is a
  /// plain move.
  ///
  /// Detected screen-side from the passenger's own state — no new engine action:
  ///   * [target] is a free Double Sofa,
  ///   * the mover holds EXACTLY one berth on [fromSeatId] (a single-berth move),
  ///   * the mover holds EXACTLY one OTHER single-sofa berth on this bus, and
  ///   * the mover has an outstanding `doubleSofa` request line (i.e. they were
  ///     satisfied via two cross-filled singles and now want the real double).
  String? _consolidationPartnerSeat(
    Tour tour,
    Bus bus,
    Passenger mover,
    SeatCell fromCell,
    SeatCell target,
  ) {
    final fromSeatId = fromCell.seatId;
    if (fromSeatId == null) return null;
    if (target.seatType != SeatType.doubleSofa) return null;
    // Free double only — a half-filled/occupied double is a fill/swap, not a
    // consolidation of the mover's own scattered singles.
    if (_occupantsOn(tour, bus, target).isNotEmpty) return null;

    final wantsDouble =
        mover.requestLines
            .where((l) => l.seatType == SeatType.doubleSofa)
            .fold<int>(0, (s, l) => s + l.qty) >
        0;
    if (!wantsDouble) return null;

    // Berths the mover holds per seat on THIS bus.
    final perSeat = <String, int>{};
    for (final a in mover.assignedSeats) {
      if (a.busId != bus.id) continue;
      perSeat[a.seatId] = (perSeat[a.seatId] ?? 0) + 1;
    }
    // The source must be a single-berth hold (a cross-filled single, not a
    // whole double the engine would have routed elsewhere).
    if ((perSeat[fromSeatId] ?? 0) != 1) return null;

    // Find exactly one OTHER single-sofa seat the mover also holds one berth on.
    String? partner;
    for (final entry in perSeat.entries) {
      if (entry.key == fromSeatId) continue;
      if (entry.value != 1) continue;
      final cell = _findCell(tour, bus.id, entry.key);
      if (cell?.seatType != SeatType.singleSofa) continue;
      if (partner != null) return null; // ambiguous — more than one candidate
      partner = entry.key;
    }
    return partner;
  }

  /// Resolve a released drag from [fromSeatId] onto [toSeatId] on [bus] by
  /// dispatching the engine verdict.
  Future<void> _handleSeatDrop(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId, {
    String? grabbedOccupantId,
  }) async {
    final fromCell = _findCell(tour, bus.id, fromSeatId);
    final targetCell = _findCell(tour, bus.id, toSeatId);
    if (fromCell == null || targetCell == null) return;
    final fromOccs = _occupantsOn(
      tour,
      bus,
      fromCell,
      onlyOccupantId: grabbedOccupantId,
    );
    if (fromOccs.isEmpty) return;

    final decision = _decideDrop(
      tour,
      bus,
      fromCell,
      targetCell,
      grabbedOccupantId: grabbedOccupantId,
    );
    final mover = tour.passengers.firstWhereOrNull(
      (p) => p.id == fromOccs.first.passengerId,
    );

    switch (decision.action) {
      case SeatDropAction.blocked:
        HapticFeedback.mediumImpact();
        _toastBlocked(
          decision.block!,
          fromCell,
          toSeatId,
          moverTrip: mover?.tripType,
        );
        return;

      case SeatDropAction.splitPairChoice:
        // A paired double dropped onto a single (free or single-occupant). Ask
        // WHICH of the two sharers peels onto the single; the other keeps the
        // double. The engine surfaces this as a VALID (green) target, so the
        // highlight matches what release does.
        await _promptSplitPairOntoSingle(tour, bus, fromCell, targetCell);
        return;

      case SeatDropAction.swapPair:
        // Two occupied doubles exchange their full contents (two couples swap
        // sofas). Both seats are cap-2, so the exchange is always seat-safe.
        await _ctrl.swapSeatContents(
          tourId: tour.id,
          busId: bus.id,
          seatAId: fromSeatId,
          seatBId: toSeatId,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.swapped_body',
            namedArgs: {
              'a': _dragLabelFor(tour, bus, fromCell) ?? fromSeatId,
              'b': _dragLabelFor(tour, bus, targetCell) ?? toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.swapped_title'),
        );
        return;

      case SeatDropAction.move:
        if (mover == null) return;
        // CONSOLIDATION: a single berth dragged onto a free Double Sofa while the
        // mover also holds another cross-filled single AND still wants a double →
        // fold BOTH singles into the one double instead of a plain move.
        final partnerSeat = _consolidationPartnerSeat(
          tour,
          bus,
          mover,
          fromCell,
          targetCell,
        );
        if (partnerSeat != null) {
          await _ctrl.consolidateOntoDouble(
            tourId: tour.id,
            passengerId: mover.id,
            busId: bus.id,
            targetSeatId: toSeatId,
            sourceSeatIds: [fromSeatId, partnerSeat],
          );
          AppSnackBar.success(
            tr(
              'tour_seat_assignment.drop.consolidated_body',
              namedArgs: {'name': mover.displayName, 'seat': toSeatId},
            ),
            title: tr('tour_seat_assignment.drop.consolidated_title'),
          );
          return;
        }
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.moved_body',
            namedArgs: {'name': mover.displayName, 'seat': toSeatId},
          ),
          title: tr('tour_seat_assignment.drop.moved_title'),
        );
        return;

      case SeatDropAction.splitToSingle:
        if (mover == null) return;
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
          berths: 1,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.split_body',
            namedArgs: {'name': mover.displayName, 'seat': toSeatId},
          ),
          title: tr('tour_seat_assignment.drop.split_title'),
        );
        return;

      case SeatDropAction.fill:
        if (mover == null) return;
        final occ = tour.passengers.firstWhereOrNull(
          (p) =>
              p.id ==
              _occupantsOn(tour, bus, targetCell).firstOrNull?.passengerId,
        );
        if (occ == null) return;
        if (!mounted) return;
        final confirmed = await _confirmSheet(
          context,
          title: tr('tour_seat_assignment.share_confirm_title'),
          message: tr(
            'tour_seat_assignment.share_confirm_body',
            namedArgs: {
              'seat': toSeatId,
              'otherName': occ.displayName,
              'currentName': mover.displayName,
            },
          ),
          confirmLabel: tr('tour_seat_assignment.share_confirm_yes'),
        );
        if (!confirmed) return;
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
          berths: 1,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.filled_body',
            namedArgs: {
              'a': mover.displayName,
              'b': occ.displayName,
              'seat': toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.filled_title'),
        );
        return;

      case SeatDropAction.swap:
        if (mover == null) return;
        final occ = tour.passengers.firstWhereOrNull(
          (p) => p.id == _occupantsOn(tour, bus, targetCell).first.passengerId,
        );
        if (occ == null) return;
        if (!mounted) return;
        await SeatSwapGuard.run(
          context,
          tourId: tour.id,
          busAId: bus.id,
          passengerAId: mover.id,
          seatAId: fromSeatId,
          passengerBId: occ.id,
          seatBId: toSeatId,
          busBId: bus.id,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.swapped_body',
            namedArgs: {'a': mover.displayName, 'b': occ.displayName},
          ),
          title: tr('tour_seat_assignment.drop.swapped_title'),
        );
        return;

      case SeatDropAction.moveBoth:
        await _ctrl.moveSharedPair(
          tourId: tour.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.moved_both_body',
            namedArgs: {
              'names': _dragLabelFor(tour, bus, fromCell) ?? '',
              'seat': toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.moved_both_title'),
        );
        return;

      case SeatDropAction.fillPairInto:
        // Merge the source occupant(s) into the leg-disjoint occupied double: move
        // each mover's OWN berths onto the target (its occupants stay put), so all
        // riders share one double across opposite legs. Moves the actual held
        // berth count per mover — 1 each for a GO+RET pair source, 2 for a WHOLE
        // one-leg double dragged onto an opposite-leg double (the leg-share the
        // agent expects, instead of a silent swap).
        for (final o in fromOccs) {
          await _ctrl.moveSeat(
            tourId: tour.id,
            passengerId: o.passengerId,
            busId: bus.id,
            fromSeatId: fromSeatId,
            toSeatId: toSeatId,
            toBusId: bus.id,
            berths: o.berthsHere,
          );
        }
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.moved_both_body',
            namedArgs: {
              'names': _dragLabelFor(tour, bus, fromCell) ?? '',
              'seat': toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.moved_both_title'),
        );
        return;
    }
  }

  /// A paired double was dropped on a single seat. Ask which of the two sharers
  /// moves onto [targetCell] (the other keeps the double), then seat the chosen
  /// one. A FREE single just takes the chosen passenger's berth; an OCCUPIED
  /// single swaps the chosen sharer with whoever sits there (so that occupant
  /// joins the remaining sharer on the double). A single reused across legs (two
  /// occupants) is too ambiguous to resolve with one tap → fall back to a toast.
  Future<void> _promptSplitPairOntoSingle(
    Tour tour,
    Bus bus,
    SeatCell fromCell,
    SeatCell targetCell,
  ) async {
    final fromSeatId = fromCell.seatId!;
    final toSeatId = targetCell.seatId!;
    final pair = _occupantsOn(tour, bus, fromCell);
    final candidates = pair
        .map(
          (o) => tour.passengers.firstWhereOrNull((p) => p.id == o.passengerId),
        )
        .whereType<Passenger>()
        .toList();
    if (candidates.length != 2) return;

    final targetOccs = _occupantsOn(tour, bus, targetCell);
    if (targetOccs.length >= 2) {
      _toastBlocked(SeatDropBlock.sharedNeedsFreeDouble, fromCell, toSeatId);
      return;
    }

    // "Both" is offered only when the two sharers travel on DISJOINT legs (one
    // outbound, one return) AND the target single is fully free — then both
    // riders leg-reuse the single seat and the whole double sofa is released.
    // Any leg overlap (or a round-trip rider) means they can't co-seat a single,
    // so the choice stays one-or-the-other.
    final bothFits =
        targetOccs.isEmpty && _legsDisjoint(candidates[0], candidates[1]);

    UgamSheet.show<void>(
      context,
      title: tr(
        'tour_seat_assignment.split_pair.title',
        namedArgs: {'seat': toSeatId},
      ),
      builder: (sheetCtx) => _SeatPassengerPicker(
        candidates: candidates,
        activeId: null,
        subtitle: tr('tour_seat_assignment.split_pair.subtitle'),
        bothLabel: bothFits
            ? tr('tour_seat_assignment.split_pair.both_label')
            : null,
        bothHint: bothFits
            ? tr(
                'tour_seat_assignment.split_pair.both_hint',
                namedArgs: {'seat': toSeatId},
              )
            : null,
        onPickBoth: bothFits
            ? () {
                Navigator.of(sheetCtx).pop();
                _seatBothSharersOnSingle(
                  tour,
                  bus,
                  fromSeatId,
                  toSeatId,
                  candidates[0],
                  candidates[1],
                );
              }
            : null,
        onPick: (chosen) {
          Navigator.of(sheetCtx).pop();
          _seatChosenSharerOnSingle(
            tour,
            bus,
            fromSeatId,
            toSeatId,
            chosen,
            targetOccs.firstOrNull,
          );
        },
      ),
    );
  }

  /// Whether [a] and [b] travel on non-overlapping legs — one uses the outbound
  /// leg without the return and the other the reverse. Only such a pair can
  /// share a single berth (leg-reuse); any round-trip rider uses both legs and
  /// therefore overlaps.
  bool _legsDisjoint(Passenger a, Passenger b) {
    final la = a.derivedTripType;
    final lb = b.derivedTripType;
    final outboundClash = la.usesOutbound && lb.usesOutbound;
    final returnClash = la.usesReturn && lb.usesReturn;
    return !outboundClash && !returnClash;
  }

  /// Move BOTH leg-disjoint sharers off the source double onto the single
  /// [toSeatId] (each keeps their leg, so they co-seat via leg-reuse) — this
  /// releases the entire double sofa. Only reached when the target single is
  /// free and the pair's legs don't overlap (see [_legsDisjoint]).
  Future<void> _seatBothSharersOnSingle(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId,
    Passenger a,
    Passenger b,
  ) async {
    await _ctrl.moveSharedPair(
      tourId: tour.id,
      busId: bus.id,
      fromSeatId: fromSeatId,
      toSeatId: toSeatId,
    );
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.split_pair.both_body',
        namedArgs: {
          'a': a.displayName,
          'b': b.displayName,
          'seat': toSeatId,
        },
      ),
      title: tr('tour_seat_assignment.split_pair.moved_title'),
    );
  }

  /// Seat [chosen] (one sharer of a paired double) onto the single [toSeatId].
  /// When the single is free, move their single berth over; when it already
  /// holds [occupant], swap the two so the displaced occupant takes the freed
  /// half of the double beside the remaining sharer.
  Future<void> _seatChosenSharerOnSingle(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId,
    Passenger chosen,
    SeatOccupant? occupant,
  ) async {
    if (occupant == null) {
      await _ctrl.moveSeat(
        tourId: tour.id,
        passengerId: chosen.id,
        busId: bus.id,
        fromSeatId: fromSeatId,
        toSeatId: toSeatId,
        toBusId: bus.id,
        berths: 1,
      );
      AppSnackBar.success(
        tr(
          'tour_seat_assignment.split_pair.moved_body',
          namedArgs: {'name': chosen.displayName, 'seat': toSeatId},
        ),
        title: tr('tour_seat_assignment.split_pair.moved_title'),
      );
      return;
    }

    final occ = tour.passengers.firstWhereOrNull(
      (p) => p.id == occupant.passengerId,
    );
    if (occ == null) return;
    if (!mounted) return;
    await SeatSwapGuard.run(
      context,
      tourId: tour.id,
      busAId: bus.id,
      passengerAId: chosen.id,
      seatAId: fromSeatId,
      passengerBId: occ.id,
      seatBId: toSeatId,
      busBId: bus.id,
    );
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.split_pair.swapped_body',
        namedArgs: {
          'a': chosen.displayName,
          'b': occ.displayName,
          'seat': toSeatId,
        },
      ),
      title: tr('tour_seat_assignment.drop.swapped_title'),
    );
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
                    const SizedBox(height: UgamSpacing.md),
                    // Per-leg (GO / RETURN) occupancy meter for the SELECTED bus
                    // — a fill bar per leg so the agent reads how full each leg
                    // is straight from the layout (the tab badge only shows a
                    // single whole-seat count). Built from ACTUAL assignments so
                    // it tracks the grid, not the engine plan.
                    Builder(
                      builder: (_) {
                        final busCap =
                            _ctrl.actualCapacityFor(tour).byBus[bus.id];
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
                            axisAlignment: -1.0,
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
                                _SeatGrid(
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
                                  onTap: (cell) =>
                                      _onSeatTapped(cell, bus, tour),
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
                                  onSeatDraggedToSeat: (fromSeatId, toSeatId) =>
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
                                    final cell = _findCell(tour, bus.id, seatId);
                                    if (cell != null) {
                                      _showSeatFlagsSheet(cell, bus);
                                    }
                                  },
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
    return UgamScaffold(
      body: SafeArea(bottom: false, child: content),
    );
  }
}

/// Mobile-native confirm — a bottom sheet with a prose body + a full-width
/// primary action (red when [destructive]) over a ghost Cancel. Replaces the
/// center [UgamDialog.confirm] so confirmations live in the thumb zone like
/// every other detail/confirm surface. Returns true only when the user taps the
/// primary action; swipe-down / tap-outside returns false.
Future<bool> _confirmSheet(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = false,
  IconData? confirmIcon,
}) async {
  final c = UgamColors.of(context);
  final result = await UgamSheet.show<bool>(
    context,
    title: title,
    showClose: false,
    builder: (sheetCtx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message != null) ...[
          Text(
            message,
            style: UgamText.body.copyWith(color: c.ink2, height: 1.4),
          ),
          const SizedBox(height: UgamSpacing.xl),
        ],
        // Destructive confirms get a full-width RED button (delete/cancel);
        // affirmative ones get the copper sticky CTA — the screen's one focal
        // action while the sheet is up.
        if (destructive)
          UgamButton(
            label: confirmLabel,
            icon: confirmIcon,
            kind: UgamButtonKind.danger,
            expand: true,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
          )
        else
          UgamCTA(
            label: confirmLabel,
            leadingIcon: confirmIcon,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
          ),
        const SizedBox(height: UgamSpacing.sm),
        UgamButton(
          label: cancelLabel ?? tr('app.action.cancel'),
          kind: UgamButtonKind.ghost,
          expand: true,
          onPressed: () => Navigator.of(sheetCtx).pop(false),
        ),
      ],
    ),
  );
  return result ?? false;
}

class _PendingLine {
  final SeatType seatType;
  final SeatPosition? position;
  final int remaining;
  final int totalRequested;

  const _PendingLine({
    required this.seatType,
    this.position,
    required this.remaining,
    required this.totalRequested,
  });

  _PendingLine copyDecremented() => _PendingLine(
    seatType: seatType,
    position: position,
    remaining: remaining > 0 ? remaining - 1 : 0,
    totalRequested: totalRequested,
  );

  String get label => seatTypeLabel(seatType, position);

  String get progress => '${totalRequested - remaining}/$totalRequested';
}

// ─── Seat passenger picker ───────────────────────────────────────────────

/// A compact pickup-point chip: the admin-facing short CODE (from
/// [PickupController]) when set, else the pickup NAME the booking snapshotted.
/// Renders nothing when the rider has no pickup; wrapped in [Obx] so the code
/// fills in once the global pickup list finishes loading.
class _PickupCodeChip extends StatelessWidget {
  final Passenger passenger;
  final EdgeInsetsGeometry padding;
  const _PickupCodeChip({
    required this.passenger,
    this.padding = const EdgeInsets.only(left: UgamSpacing.sm),
  });

  Widget _chip(String? label) {
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: UgamReqChip(label: label, variant: UgamChipVariant.neutral),
    );
  }

  String? _label(PickupController? pk) {
    final code = pk?.codeFor(passenger.pickupLocationId);
    if (code != null && code.isNotEmpty) return code;
    final name = passenger.pickupLocationName;
    return (name != null && name.isNotEmpty) ? name : null;
  }

  @override
  Widget build(BuildContext context) {
    final pk = Get.isRegistered<PickupController>()
        ? Get.find<PickupController>()
        : null;
    if (pk == null) return _chip(_label(null));
    return Obx(() => _chip(_label(pk)));
  }
}

/// Bottom-sheet list of pending passengers who can take a tapped EMPTY seat —
/// seat-first assignment. Each row shows the name + their outstanding request;
/// the currently-selected passenger (if any) is tagged at the top. The sheet
/// chrome (handle + seat/bus title) is supplied by [UgamSheet.show].
class _SeatPassengerPicker extends StatelessWidget {
  final List<Passenger> candidates;
  final String? activeId;
  final ValueChanged<Passenger> onPick;

  /// Optional override for the explanatory line above the list. Defaults to the
  /// seat-first "tap a passenger to seat them here" copy.
  final String? subtitle;

  /// Optional "move both" affordance, shown as a distinct row above the
  /// candidate list. Provided only when seating BOTH sharers on the target is
  /// valid (leg-disjoint pair onto a free single). [bothLabel]/[bothHint] are
  /// the row's title/subtitle; [onPickBoth] fires on tap.
  final String? bothLabel;
  final String? bothHint;
  final VoidCallback? onPickBoth;

  const _SeatPassengerPicker({
    required this.candidates,
    required this.activeId,
    required this.onPick,
    this.subtitle,
    this.bothLabel,
    this.bothHint,
    this.onPickBoth,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          subtitle ?? tr('tour_seat_assignment.picker_subtitle'),
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (onPickBoth != null) ...[
          _bothRow(c),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              itemCount: candidates.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: UgamSpacing.sm),
              itemBuilder: (_, i) => _row(c, candidates[i]),
            ),
          ),
        ),
      ],
    );
  }

  /// Distinct accent-tinted row that seats BOTH sharers on the target single
  /// (leg-reuse), freeing the double. Visually set apart from the one-or-other
  /// candidate rows below by the accent group icon and tinted fill.
  Widget _bothRow(UgamColorSet c) {
    return GestureDetector(
      onTap: onPickBoth,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.accentFill,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(color: c.accent, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.groups_rounded, size: 19, color: c.onAccent),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bothLabel ?? '',
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (bothHint != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      bothHint!,
                      style: UgamText.micro.copyWith(color: c.ink2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.xs),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.accent),
          ],
        ),
      ),
    );
  }

  Widget _row(UgamColorSet c, Passenger p) {
    final isActive = p.id == activeId;
    return UgamPersonRow(
      name: p.displayName,
      subtitle: p.requestSummary,
      initials: SeatChartTile.initials(p.displayName),
      selected: isActive,
      onTap: () => onPick(p),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PickupCodeChip(
            passenger: p,
            padding: const EdgeInsets.only(right: UgamSpacing.sm),
          ),
          if (isActive) ...[
            Icon(Icons.check_circle_rounded, size: 16, color: c.accent),
            const SizedBox(width: UgamSpacing.xs),
          ],
          Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
        ],
      ),
    );
  }
}

// ─── Bus pills ─────────────────────────────────────────────────────────

class _BusPills extends StatelessWidget {
  final List<Bus> buses;
  final String selectedBusId;
  final int Function(String) seatsAssignedFor;
  final ValueChanged<String> onTapBus;
  final UgamColorSet c;

  const _BusPills({
    required this.buses,
    required this.selectedBusId,
    required this.seatsAssignedFor,
    required this.onTapBus,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // tap() not px(): every pill is a tap target, so the strip follows the
      // app scale but never drops under the 44pt minimum.
      height: UgamScale.tap(context, 44),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
        itemCount: buses.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (ctx, i) {
          final bus = buses[i];
          final selected = bus.id == selectedBusId;
          final assigned = seatsAssignedFor(bus.id);
          final capacity = bus.totalSeats;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTapBus(bus.id);
            },
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selected ? c.accentFill : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: selected
                    ? Border.all(color: c.accent.withValues(alpha: 0.28))
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bus.name,
                    // caption IS 12 — this was `bodyStrong` forked down to 12.
                    style: UgamText.caption.copyWith(
                      color: selected ? c.accent : c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  // Was the third hand-rolled badge geometry in this file
                  // (6/2 padding + a forked 10.5pt). UgamReqChip is THE badge.
                  UgamReqChip(
                    label: '$assigned/$capacity',
                    variant: selected
                        ? UgamChipVariant.accent
                        : UgamChipVariant.neutral,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Relocate banner ─────────────────────────────────────────────────────

/// Slim accent banner shown while a cross-bus relocate is in progress: tells
/// the agent who is in hand and which bus they're placing on, with a Cancel.
class _RelocateBanner extends StatelessWidget {
  final String moverName;
  final String busName;
  final VoidCallback onCancel;
  final UgamColorSet c;

  const _RelocateBanner({
    required this.moverName,
    required this.busName,
    required this.onCancel,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Vertical padding drops sm+2 -> xs because the Cancel below now carries
      // its own 44pt box; keeping 10 on top of that would have grown the banner
      // twice over.
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app_rounded, size: 18, color: c.accent),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr(
                'tour_seat_assignment.relocate.banner',
                namedArgs: {'name': moverName, 'bus': busName},
              ),
              style: UgamText.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // This is the ONLY exit from cross-bus relocate mode, and it was a
          // ~20pt-tall bare label. The painted text is unchanged; it now sits
          // in a real 44x44 hit box (Center(widthFactor: 1) keeps the box
          // shrink-wrapped to the label's width so the banner does not
          // reflow horizontally).
          GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              child: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                  ),
                  child: Text(
                    tr('app.action.cancel'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Seat grid card ────────────────────────────────────────────────────

class _SeatGrid extends StatelessWidget {
  /// Visible scroll-area height. The in-place pinch-zoom box is bounded to it
  /// so the constrained [InteractiveViewer] (inside [UgamPinchZoom]) has finite
  /// height even though it lives in an unbounded vertical scroll view.
  final double viewportHeight;
  final BusLayout? layout;
  final Tour tour;
  final Map<String, List<String>> assignmentMap;
  final String? currentPassengerId;
  final ValueChanged<SeatCell> onTap;
  final String busName;

  // ── Drag-to-move hooks ────────────────────────────────────────────────────
  final bool enableDrag;
  final bool dragActive;
  final bool Function(SeatCell cell) canDragSeat;
  final SeatDropHighlight Function(SeatCell cell) dropHighlightFor;
  final String? Function(SeatCell cell) dragLabelFor;
  final void Function(SeatCell cell) onSeatDragStarted;
  final VoidCallback onSeatDragEnded;
  final void Function(String fromSeatId, String toSeatId) onSeatDraggedToSeat;

  /// A pending rider dragged from the dock was dropped on a seat.
  final void Function(String passengerId, String seatId)
      onPendingRiderDroppedToSeat;

  /// Long-press an EMPTY seat → open its Hold/Premium flag sheet. Booked seats
  /// keep long-press = drag; they reach the flag sheet via the occupant menu.
  final void Function(String seatId) onSeatLongPressForFlags;

  const _SeatGrid({
    required this.viewportHeight,
    required this.layout,
    required this.tour,
    required this.assignmentMap,
    required this.currentPassengerId,
    required this.onTap,
    required this.busName,
    required this.enableDrag,
    required this.dragActive,
    required this.canDragSeat,
    required this.dropHighlightFor,
    required this.dragLabelFor,
    required this.onSeatDragStarted,
    required this.onSeatDragEnded,
    required this.onSeatDraggedToSeat,
    required this.onPendingRiderDroppedToSeat,
    required this.onSeatLongPressForFlags,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null) {
      return const _NoLayout();
    }
    final c = UgamColors.of(context);

    // Resolve passenger ids → models once and build a stable group-colour
    // resolver from the tour's groups, so the shared canonical tile renders
    // names, group rings and GO/RET exactly like every other chart.
    final byId = {for (final p in tour.passengers) p.id: p};
    final resolver = tourGroupColors(tour);

    // Occupants per seat for the currently-shown bus, resolved with the exact
    // same logic the tileBuilder uses below — fed verbatim to the shared
    // full-screen chart so it reads identically to the inline chart.
    final occupantsBySeat = <String, List<Passenger>>{
      for (final e in assignmentMap.entries)
        e.key: e.value.map((id) => byId[id]).whereType<Passenger>().toList(),
    };
    final canExpand = l.totalCells > 0;

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Stack(
        children: [
          // In-place pinch-zoom for close inspection of a dense chart; the
          // full-screen expand button (below, outside the zoom layer) still
          // opens the shared fullscreen chart. The zoom wraps only the grid so
          // the expand affordance stays fixed and tappable. Bounded to the
          // visible scroll-area height so the constrained InteractiveViewer has
          // finite height inside this unbounded vertical scroll view; the chart
          // sits at the top so it reads exactly as before at scale 1.
          SizedBox(
            height: viewportHeight > 0 ? viewportHeight : null,
            child: UgamPinchZoom(
            child: Align(
            alignment: Alignment.topCenter,
            child: CombinedSeatGrid(
            layout: l,
            cellWidth: kSeatTileW,
            cellHeight: kSeatTileH,
            colGap: 8,
            rowGap: 8,
            driverLabel: tr('tour_seat_assignment.grid_label_driver'),
            // Reserve a header band so the top-left expand button clears SU1.
            reserveTopAction: canExpand,
            // Drag-to-move: a booked seat can be long-pressed onto another. The
            // grid owns the gesture; the screen owns move/swap (group-safe).
            enableDrag: enableDrag,
            dragActive: dragActive,
            canDragSeat: canDragSeat,
            dropHighlightFor: dropHighlightFor,
            dragLabelFor: dragLabelFor,
            reportRejectedDrops: true,
            onSeatDragStarted: onSeatDragStarted,
            onSeatDragEnded: onSeatDragEnded,
            onSeatDraggedToSeat: onSeatDraggedToSeat,
            onPendingRiderDroppedToSeat: onPendingRiderDroppedToSeat,
            onSeatLongPressForFlags: onSeatLongPressForFlags,
            tileBuilder: (ctx, cell) {
              final owners = assignmentMap[cell.seatId] ?? const <String>[];
              final occ = owners
                  .map((id) => byId[id])
                  .whereType<Passenger>()
                  .toList();
              final isMine =
                  currentPassengerId != null &&
                  owners.contains(currentPassengerId);
              final tile = SeatChartTile(
                cell: cell,
                occupants: occ,
                groupColors: resolver,
                // [occ] is berth-accurate (one entry per assignment), so a
                // half-taken double sofa renders split (filled + empty) instead
                // of reading as fully booked.
                markHalfDouble: true,
                onTapBooked: () => onTap(cell),
                onTapFree: () => onTap(cell),
              );
              return SizedBox(
                width: kSeatTileW,
                height: kSeatTileH,
                child: RepaintBoundary(
                  child: Stack(
                    children: [
                      tile,
                      // Selection ring marks the seats already held by
                      // the passenger currently being assigned. Kept always
                      // mounted (IgnorePointer + Positioned.fill = zero layout
                      // impact) so its opacity can ease in/out as [isMine]
                      // flips, instead of popping.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: isMine ? 1.0 : 0.0,
                            duration: UgamMotion.sheet,
                            curve: Curves.easeOutCubic,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.seat,
                                ),
                                border: Border.all(
                                  color: c.accent,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            ),
            ),
            ),
          ),
          // Expand to the shared full-screen chart — works in both standalone
          // and embedded modes. Top-left, since the driver indicator owns the
          // chart's top-right.
          if (canExpand)
            ChartExpandButton(
              onTap: () => FullscreenChartScreen.open(
                context,
                layout: l,
                occupantsBySeat: occupantsBySeat,
                groupColors: resolver,
                title: busName,
                driverLabel: tr('tour_seat_assignment.grid_label_driver'),
                // [occupantsBySeat] here is berth-accurate, so the expanded
                // chart can split a half-taken double too.
                markHalfDouble: true,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Passenger card ────────────────────────────────────────────────────
//
// Sits between the seat chart and the pending dock. Shows who the agent
// is currently assigning + their pending request lines + handler + edit
// buttons. Kept as a single dense card so the seat grid stays the focal
// surface.
class _PassengerCard extends StatelessWidget {
  final Tour tour;
  final Passenger passenger;
  final List<_PendingLine> pending;

  /// Tour-wide handler pointer — kept only to badge the handler in this card
  /// and to drive the "assign a handler" nudge. Handlers are now assigned
  /// PER BUS on the Manage Buses screen, so there's no toggle here.
  final String? handlerId;

  /// Opens Manage Buses, where each bus's handler is picked.
  final VoidCallback onManageBuses;

  const _PassengerCard({
    required this.tour,
    required this.passenger,
    required this.pending,
    required this.handlerId,
    required this.onManageBuses,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selectedSeats = passenger.assignedSeats.isEmpty
        ? '—'
        : passenger.assignedSeats.map((a) => a.seatId).join(', ');
    final stillNeeded = pending.fold<int>(0, (sum, l) => sum + l.remaining);

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                // px() not tap(): the avatar is decorative — the whole card
                // is the tap target, not this disc. The 13pt initials match
                // UgamPersonRow's default avatar exactly, so no fork here.
                width: UgamScale.px(context, 32),
                height: UgamScale.px(context, 32),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  SeatChartTile.initials(passenger.displayName),
                  style: UgamText.bodyStrong.copyWith(
                    color: c.accent,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.tight),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            passenger.displayName,
                            // bodyStrong IS 14 — this was `titleM` (18) forked
                            // down. The collapsed dock renders the same name at
                            // titleS, so the two states now share one ramp.
                            style: UgamText.bodyStrong.copyWith(color: c.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (handlerId == passenger.id) ...[
                          const SizedBox(width: 6),
                          // Was a 4px-radius hand-rolled badge sitting directly
                          // beside the pill-shaped pickup chip below.
                          UgamReqChip(
                            label: tr('tour_seat_assignment.badge_handler'),
                            variant: UgamChipVariant.warm,
                          ),
                        ],
                        _PickupCodeChip(passenger: passenger),
                      ],
                    ),
                    if (passenger.phone.isNotEmpty)
                      Text(
                        passenger.phone,
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                  ],
                ),
              ),
              UgamIconButton(
                // size/iconSize overrides deleted — inherit the component's
                // 44/19 defaults so this matches every other icon button.
                icon: Icons.edit_outlined,
                semanticLabel: tr('tour_seat_assignment.tooltip_edit_request'),
                onTap: () => EditRequestSheet.show(
                  context: context,
                  tour: tour,
                  passenger: passenger,
                ),
              ),
              Text(
                '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}',
                // 13 -> bodyStrong's own 14, matching the name beside it.
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: pending.map((line) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                    vertical: UgamSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    // Was a 6px corner while the visually identical queue chips
                    // ~40px below are full pills — two corner languages for the
                    // same information.
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    '${line.label}  ${line.progress}',
                    style: UgamText.caption.copyWith(
                      color: line.remaining == 0 ? c.good : c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr(
                    'tour_seat_assignment.seats_label',
                    namedArgs: {'seats': selectedSeats},
                  ),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (stillNeeded > 0)
                Text(
                  tr(
                    'tour_seat_assignment.more_needed',
                    namedArgs: {'count': stillNeeded.toString()},
                  ),
                  style: UgamText.caption.copyWith(
                    color: c.warm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (handlerId == null && stillNeeded == 0) ...[
            const SizedBox(height: UgamSpacing.tight),
            GestureDetector(
              onTap: onManageBuses,
              behavior: HitTestBehavior.opaque,
              child: Container(
                // Styled as a button but was only ~32pt tall, and it is the
                // only in-card route to assigning a handler (the gate that
                // blocks Lock & notify). centerLeft is load-bearing: without an
                // alignment the Row top-aligns inside the taller box, and
                // `center` would re-centre it horizontally.
                constraints: const BoxConstraints(minHeight: 44),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: c.warmFill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 14, color: c.warm),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('tour_seat_assignment.hint_pick_handler'),
                        style: UgamText.caption.copyWith(color: c.warm),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 14, color: c.warm),
                  ],
                ),
              ),
            ),
          ],
          // The all-passenger chip picker that used to live here was removed:
          // the dock's queue strip is now the SINGLE passenger switcher, so the
          // cramped bottom third breathes and there's only one place to jump
          // between requests.
        ],
      ),
    );
  }
}

// ─── Assignment dock ───────────────────────────────────────────────────
//
// Cohesive bottom panel that floats over the seat chart. Two snap states:
//   • Collapsed (default): grab handle + a one-line active-passenger summary
//     + the pending queue strip + the lock/download action. The chart owns
//     all the space above, so the WHOLE grid is visible.
//   • Expanded: drag the handle up (or tap it) to reveal the full passenger
//     detail (phone, every pending line, handler nudge, edit) — the sheet
//     grows UPWARD as an overlay, so the chart is never squeezed.
//
// Replaces the old stacked `_PassengerCard` + `_PendingDock`, which together
// ate ~40% of the screen and left only a sliver of the chart visible.
class _AssignmentDock extends StatelessWidget {
  final UgamColorSet c;
  final Tour tour;

  /// Active passenger being seated. Null when nobody is selected or every
  /// seat is filled — the dock then shows only its queue / done-state.
  final Passenger? passenger;
  final List<_PendingLine> pendingLines;
  final String? handlerId;
  final VoidCallback onManageBuses;

  /// The pending queue (everyone still needing seats).
  final List<Passenger> pending;
  final String? activeId;
  final ValueChanged<String> onTapPassenger;

  /// A pending-rider chip started / ended being dragged toward a seat. The
  /// screen uses these to light up fitting seats during the drag.
  final ValueChanged<String> onPendingDragStarted;
  final VoidCallback onPendingDragEnded;

  final VoidCallback? onLockTour;
  final VoidCallback? onDownloadChart;

  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<bool> onSetExpanded;

  const _AssignmentDock({
    required this.c,
    required this.tour,
    required this.passenger,
    required this.pendingLines,
    required this.handlerId,
    required this.onManageBuses,
    required this.pending,
    required this.activeId,
    required this.onTapPassenger,
    required this.onPendingDragStarted,
    required this.onPendingDragEnded,
    required this.onLockTour,
    required this.onDownloadChart,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onSetExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final hasActive = passenger != null;
    final showDetail = expanded && hasActive;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        // Lift the sheet off the chart only while it overlays it (expanded).
        boxShadow: showDetail
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 20,
                  offset: const Offset(0, -8),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle — tap toggles, a vertical flick snaps open/closed.
          // Disabled when there's no active passenger (nothing to expand to).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasActive ? onToggleExpanded : null,
            onVerticalDragEnd: hasActive
                ? (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -50) {
                      onSetExpanded(true);
                    } else if (v > 50) {
                      onSetExpanded(false);
                    }
                  }
                : null,
            child: Container(
              width: double.infinity,
              alignment: Alignment.center,
              // Pure hit-area growth (18 -> 44): the visible 36x4 bar and its
              // centred position are unchanged. This zone owns BOTH the tap
              // toggle and the drag-to-snap, and at 18pt the "drag the handle
              // up" gesture landed on the chart behind it instead.
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xxl),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: hasActive ? c.ink3 : c.border,
                  // 999 clamps to 2 on a 4pt-tall bar — identical pixels.
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
              ),
            ),
          ),
          // Body: full detail when expanded, otherwise the one-line summary.
          // AnimatedSize keeps owning the height change; the inner
          // AnimatedSwitcher cross-fades the detail / compact / done content so
          // the swap eases instead of popping. Keyed so the switcher animates.
          AnimatedSize(
            // Was a raw 200ms against the inner switcher's 180ms, so the dock's
            // content visibly lagged its container on expand.
            duration: UgamMotion.sheet,
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: UgamMotion.sheet,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              child: showDetail
                  ? ConstrainedBox(
                      key: const ValueKey('dock-detail'),
                      constraints: BoxConstraints(
                        maxHeight: media.size.height * 0.5,
                      ),
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: _PassengerCard(
                          tour: tour,
                          passenger: passenger!,
                          pending: pendingLines,
                          handlerId: handlerId,
                          onManageBuses: onManageBuses,
                        ),
                      ),
                    )
                  : hasActive
                  ? KeyedSubtree(
                      key: const ValueKey('dock-compact'),
                      child: _compactActive(context),
                    )
                  : const SizedBox.shrink(key: ValueKey('dock-done')),
            ),
          ),
          // Queue strip + primary action, then the bottom safe-area inset.
          _queueRow(context),
          SizedBox(height: media.padding.bottom + UgamSpacing.xs),
        ],
      ),
    );
  }

  /// One-line active-passenger summary shown while collapsed: avatar, name,
  /// request summary + "needs N more", and the seats-assigned tally. Tapping
  /// it expands the dock (same as the handle).
  Widget _compactActive(BuildContext context) {
    final p = passenger!;
    final stillNeeded = pendingLines.fold<int>(0, (s, l) => s + l.remaining);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.xs,
        UgamSpacing.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UgamSectionLabel(tr('tour_seat_assignment.now_seating')),
          const SizedBox(height: UgamSpacing.xs),
          // The active passenger sits in ONE clearly-accented card so it never
          // reads as "just another queue row". Tapping it expands to the full
          // request breakdown (same as the grab handle).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggleExpanded,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.tight,
              ),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.row),
                border: Border.all(color: c.accent.withValues(alpha: 0.28)),
              ),
              child: Row(
                children: [
                  Container(
                    // Accent-rationing: this disc was a solid `c.accent` fill
                    // sitting INSIDE an already accentFill-tinted card, right
                    // above the solid-accent Lock & notify button — three
                    // coppers competing in the collapsed dock. `c.card` (not
                    // accentFill) because accentFill on accentFill is invisible
                    // in light mode. The one solid accent left on this screen is
                    // the dock's primary UgamButton.
                    width: UgamScale.px(context, 38),
                    height: UgamScale.px(context, 38),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.card,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      SeatChartTile.initials(p.displayName),
                      // bodyStrong is already 14 — the override was a no-op.
                      style: UgamText.bodyStrong.copyWith(color: c.accent),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.tight),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          p.displayName,
                          // titleS IS 15 — this was `titleM` (18) forked down.
                          style: UgamText.titleS.copyWith(color: c.ink),
                          // 2 lines before ellipsis — app-wide name rule, see
                          // UgamRequestRow.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                p.requestSummary,
                                style: UgamText.caption.copyWith(color: c.ink2),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (stillNeeded > 0) ...[
                              Text(
                                '  ·  ',
                                style:
                                    UgamText.caption.copyWith(color: c.ink3),
                              ),
                              Text(
                                tr(
                                  'tour_seat_assignment.more_needed',
                                  namedArgs: {'count': stillNeeded.toString()},
                                ),
                                style: UgamText.caption.copyWith(
                                  color: c.warm,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Text(
                    '${p.totalSeatsAssigned}/${p.totalSeatsRequested}',
                    // titleS IS 15 — matches the name beside it, and the
                    // expanded card's tally now sits on bodyStrong (14), so the
                    // pair no longer jumps size on a dock toggle.
                    style: UgamText.tabular(
                      UgamText.titleS.copyWith(color: c.ink),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.xs),
                  Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: c.ink3),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pending queue — a VERTICAL list of up to three full-name [UgamPersonRow]s
  /// (the active one framed selected) plus a "See all N" row opening the full
  /// pending sheet, then the primary lock / download action. The vertical rows
  /// give each pending passenger their full name + request summary instead of
  /// the old horizontal cards that truncated names.
  Widget _queueRow(BuildContext context) {
    const cap = 6;
    final visible = pending.take(cap).toList();
    final overflow = pending.length - visible.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending.isEmpty)
            Row(
              children: [
                Icon(Icons.check_circle_rounded, size: 16, color: c.good),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('tour_seat_assignment.all_assigned_dock'),
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                ),
              ],
            )
          else ...[
            // "Up next" as a single COMPACT horizontal strip of passenger
            // chips, clearly under the "Now seating" card — no more stacked
            // near-identical full-width rows. Full names + request breakdown
            // still live one tap away in the "See all" sheet.
            Row(
              children: [
                Expanded(
                  child: UgamSectionLabel(
                    tr(
                      'tour_seat_assignment.up_next',
                      namedArgs: {'count': '${pending.length}'},
                    ),
                  ),
                ),
                if (overflow > 0)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showAllPending(context),
                    // On a >6-deep queue this label is the ONLY route to the
                    // rest of the riders, and it was a bare ~20pt Row. Padding
                    // (12 + 20 + 12) takes it to 44 without touching the
                    // painted label or chevron.
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.sm,
                        vertical: UgamSpacing.md,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('tour_seat_assignment.dock_see_all_short'),
                            style: UgamText.caption.copyWith(
                              color: c.ink2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: UgamSpacing.xs + 2),
            SizedBox(
              // The chips inside were 40pt — a horizontally-scrolling strip of
              // sub-44 targets. tap() floors the strip at 44 and lets it reach
              // the tuned 48 on a baseline-width phone.
              height: UgamScale.tap(context, 48),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: visible.length + (overflow > 0 ? 1 : 0),
                separatorBuilder: (_, _) =>
                    const SizedBox(width: UgamSpacing.sm),
                itemBuilder: (ctx, i) {
                  if (i >= visible.length) {
                    return _pendingMoreChip(context, overflow);
                  }
                  return _pendingChip(context, visible[i]);
                },
              ),
            ),
          ],
          // Primary action slot (mutually exclusive): Lock > Pick-handler >
          // Download.
          //
          // Pick-handler is the done-state dead-end fix: every seat is assigned
          // but no handler is picked, so the lock gate stays closed and the
          // in-detail handler nudge (only shown while a passenger is expanded)
          // is unreachable — this CTA routes to Manage Buses to pick one.
          if (onLockTour != null) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_lock_notify'),
              icon: Icons.lock_rounded,
              kind: UgamButtonKind.primary,
              expand: true,
              onPressed: onLockTour,
            ),
          ] else if (handlerId == null &&
              pending.isEmpty &&
              tour.status != TourStatus.locked &&
              tour.status != TourStatus.completed) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_pick_handler_lock'),
              icon: Icons.badge_outlined,
              kind: UgamButtonKind.primary,
              expand: true,
              onPressed: onManageBuses,
            ),
          ] else if (onDownloadChart != null) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_download_chart'),
              icon: Icons.download_rounded,
              kind: UgamButtonKind.primary,
              expand: true,
              onPressed: onDownloadChart,
            ),
          ],
          // Download the chart ALONGSIDE a Lock / Pick-handler primary, so the
          // organiser can review or share it BEFORE locking. Kept secondary
          // (neutral) so Lock stays the single accent primary; suppressed when
          // Download is already the primary above (its own else-if branch).
          if (onDownloadChart != null &&
              (onLockTour != null ||
                  (handlerId == null &&
                      pending.isEmpty &&
                      tour.status != TourStatus.locked &&
                      tour.status != TourStatus.completed))) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_download_chart'),
              icon: Icons.download_rounded,
              kind: UgamButtonKind.neutral,
              expand: true,
              onPressed: onDownloadChart,
            ),
          ],
        ],
      ),
    );
  }

  /// One compact "Up next" chip: avatar + name + assigned/requested tally.
  /// Tapping it makes that passenger active (same as the old vertical row). The
  /// active passenger is accent-filled so the strip echoes the "Now seating"
  /// card above it.
  Widget _pendingChip(BuildContext context, Passenger p) {
    final selected = activeId == p.id;
    final chip = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTapPassenger(p.id);
      },
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.xs,
          UgamSpacing.sm,
          UgamSpacing.md,
          UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: selected
              ? Border.all(color: c.accent.withValues(alpha: 0.35))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              // Accent-rationing: a solid copper disc here rendered at the same
              // time as the "Now seating" avatar ~60px above, for the SAME
              // person — read as two different selected passengers. The chip
              // already carries selection via its accentFill + accent hairline.
              width: UgamScale.px(context, 30),
              height: UgamScale.px(context, 30),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? c.accent.withValues(alpha: 0.18)
                    : c.card,
                shape: BoxShape.circle,
              ),
              child: Text(
                SeatChartTile.initials(p.displayName),
                style: UgamText.caption.copyWith(
                  color: selected ? c.accent : c.ink2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 108),
              child: Text(
                p.displayName,
                style: UgamText.caption.copyWith(
                  color: selected ? c.accent : c.ink,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${p.totalSeatsAssigned}/${p.totalSeatsRequested}',
              // Dropped the fractional 10.5 fork onto caption's own 12,
              // matching the name it sits beside.
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: selected ? c.accent : c.ink3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Long-press to DRAG this rider onto a seat (tap still selects). 150ms hold
    // so a horizontal swipe still scrolls the strip. The screen flags the drag
    // so fitting seats light up; the seat's drop target does the placement.
    return LongPressDraggable<PendingRiderDragData>(
      data: PendingRiderDragData(p.id),
      delay: const Duration(milliseconds: 150),
      hapticFeedbackOnStart: true,
      onDragStarted: () => onPendingDragStarted(p.id),
      onDragEnd: (_) => onPendingDragEnded(),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            p.displayName,
            style: UgamText.caption.copyWith(
              color: c.onAccent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: chip,
    );
  }

  /// Trailing "+N" chip on the "Up next" strip → opens the full pending sheet.
  Widget _pendingMoreChip(BuildContext context, int overflow) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showAllPending(context),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: c.border),
        ),
        child: Text(
          '+$overflow',
          style: UgamText.bodyStrong.copyWith(color: c.ink2),
        ),
      ),
    );
  }

  /// Full sheet of every pending passenger — opened from the dock's "+N"
  /// overflow tile so the agent can jump to anyone, not just the first few.
  void _showAllPending(BuildContext context) {
    UgamSheet.show<void>(
      context,
      title: tr(
        'tour_seat_assignment.dock_all_pending_title',
        namedArgs: {'count': '${pending.length}'},
      ),
      builder: (sheetCtx) {
        final cc = UgamColors.of(sheetCtx);
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.55,
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const BouncingScrollPhysics(),
            itemCount: pending.length,
            separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.sm),
            itemBuilder: (_, i) {
              final p = pending[i];
              final selected = p.id == activeId;
              return UgamPersonRow(
                name: p.displayName,
                subtitle: p.requestSummary,
                initials: SeatChartTile.initials(p.displayName),
                selected: selected,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  onTapPassenger(p.id);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: cc.accent,
                      ),
                      const SizedBox(width: UgamSpacing.xs),
                    ],
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: cc.ink3,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ─── Empty states ──────────────────────────────────────────────────────

class _NoBuses extends StatelessWidget {
  final String tourId;
  const _NoBuses({required this.tourId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: UgamEmpty(
          icon: Icons.directions_bus_outlined,
          title: tr('tour_seat_assignment.no_buses_title'),
          body: tr('tour_seat_assignment.no_buses_body'),
          cta: UgamCTA(
            label: tr('tour_seat_assignment.btn_add_bus'),
            leadingIcon: Icons.add_rounded,
            onPressed: () => Get.to(() => ManageBusesScreen(tourId: tourId)),
          ),
        ),
      ),
    );
  }
}

class _NoPassengers extends StatelessWidget {
  final String tourId;
  const _NoPassengers({required this.tourId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: UgamEmpty(
          icon: Icons.people_outline_rounded,
          title: tr('tour_seat_assignment.no_passengers_title'),
          body: tr('tour_seat_assignment.no_passengers_body'),
          // Dead-end fix: buses exist but nobody is booked, and this state used
          // to offer nothing to tap while the adjacent _NoBuses state hands the
          // agent a button. Route to the tour's requests, which is where a
          // passenger actually enters the system. Mirrors _NoBuses exactly.
          cta: UgamCTA(
            label: tr('tour_seat_assignment.btn_view_requests'),
            leadingIcon: Icons.assignment_outlined,
            onPressed: () =>
                Get.to(() => RequestsScreen(initialTourId: tourId)),
          ),
        ),
      ),
    );
  }
}

class _NoLayout extends StatelessWidget {
  const _NoLayout();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      alignment: Alignment.center,
      child: Text(
        tr('tour_seat_assignment.no_layout'),
        textAlign: TextAlign.center,
        style: UgamText.caption.copyWith(color: c.ink2),
      ),
    );
  }
}

// ─── Edit-seats flag sheet ─────────────────────────────────────────────────

/// Edit-mode sheet for one seat: two switches that toggle the seat's "Forward /
/// premium" and "Hold / reserved" flags. The handlers write straight through to
/// [TourController.setSeatForward] / [setSeatReserved]; the chart repaints
/// reactively once the bus layout mutates.
class _SeatFlagsSheet extends StatefulWidget {
  final String seatId;
  final String typeLabel;
  final String busName;
  final bool forward;
  final bool reserved;
  final ValueChanged<bool> onForward;
  final ValueChanged<bool> onReserved;

  const _SeatFlagsSheet({
    required this.seatId,
    required this.typeLabel,
    required this.busName,
    required this.forward,
    required this.reserved,
    required this.onForward,
    required this.onReserved,
  });

  @override
  State<_SeatFlagsSheet> createState() => _SeatFlagsSheetState();
}

class _SeatFlagsSheetState extends State<_SeatFlagsSheet> {
  late bool _forward = widget.forward;
  late bool _reserved = widget.reserved;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.tune_rounded, size: 18, color: c.ink),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(
                      'tour_seat_assignment.seat_label',
                      namedArgs: {'seat': widget.seatId},
                    ),
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.typeLabel} · ${widget.busName}',
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.lg),
        _FlagRow(
          icon: Icons.star_rounded,
          title: tr('tour_seat_assignment.flags.forward_title'),
          subtitle: tr('tour_seat_assignment.flags.forward_subtitle'),
          value: _forward,
          // Warm = attention; the forward zone is the priority/premium band.
          activeColor: c.warm,
          c: c,
          onTap: () {
            final v = !_forward;
            setState(() => _forward = v);
            widget.onForward(v);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _FlagRow(
          icon: Icons.lock_outline_rounded,
          title: tr('tour_seat_assignment.flags.reserved_title'),
          subtitle: tr('tour_seat_assignment.flags.reserved_subtitle'),
          value: _reserved,
          activeColor: c.accent,
          c: c,
          onTap: () {
            final v = !_reserved;
            setState(() => _reserved = v);
            widget.onReserved(v);
          },
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamCTA(
          label: tr('app.action.done'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// One tappable flag row in [_SeatFlagsSheet] — a full-width [UgamCard.plain]
/// that fills accentFill + a check tick when ON, and fires the controller call
/// immediately on tap (no Switch, no separate confirm). The whole row is the
/// hit target, the active tone reads the flag's colour (warm/accent).
class _FlagRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final Color activeColor;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _FlagRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.activeColor,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // One surface: a single tappable card whose fill flips to a tonal wash of
    // the flag's colour while ON, with a hairline tone border. No nested card.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: AnimatedContainer(
          duration: UgamMotion.tab,
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            // `sm + 4` was exactly UgamSpacing.md — same 12, now named.
            vertical: UgamSpacing.md,
          ),
          decoration: BoxDecoration(
            color: value ? activeColor.withValues(alpha: 0.14) : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.row),
            border: value
                ? Border.all(color: activeColor.withValues(alpha: 0.5))
                : null,
          ),
          child: Row(
            children: [
              // Small scale cue on the flag glyph as the value flips, alongside
              // the row's own color/border ease. Scale-only, no layout change.
              AnimatedScale(
                scale: value ? 1.12 : 1.0,
                duration: UgamMotion.tab,
                curve: Curves.easeOutCubic,
                child: Icon(
                  icon,
                  size: 18,
                  color: value ? activeColor : c.ink3,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.bodyStrong.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // A filled tick when ON; a hollow ring when OFF — the at-a-glance
              // "this flag is set" cue that replaces the Switch thumb.
              Icon(
                value
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: value ? activeColor : c.ink3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
