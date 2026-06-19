import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'fullscreen_chart_screen.dart';
import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../design/ugam.dart';
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
/// so the chart legend is never hidden behind the floating dock.
const double _kCollapsedDockHeight = 176;

class _TourSeatAssignmentScreenState extends State<TourSeatAssignmentScreen> {
  String? _selectedBusId;
  String? _selectedPassengerId;

  /// "Edit seats" mode. When ON, a seat tap opens the Forward/Reserved flag
  /// sheet (instead of placing / managing an occupant), and drag-to-move is
  /// suspended (the two modes never compete for the same long-press).
  bool _editMode = false;

  /// The seat being long-press-dragged on the chart (the source seat id), and
  /// whether SOME drag is currently in flight. Non-null only mid-drag; while a
  /// drag is active every other tile lights up per [_dropHighlightFor] so the
  /// agent sees legal targets before releasing.
  String? _dragFromSeatId;
  bool _dragActive = false;

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
    final ok = await UgamDialog.confirm(
      context,
      title: tr('seat_assignment.clear_bus.title'),
      message: tr(
        'seat_assignment.clear_bus.body',
        namedArgs: {'count': '$seatCount', 'bus': bus.name},
      ),
      cancelLabel: tr('app.action.cancel'),
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
          if (n > 0) (trip: p.tripType, berths: n),
    ];
    return seatHasLegRoom(
      activeTrip: passenger.tripType,
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
      activeTrip: passenger.tripType,
      cap: cellType == SeatType.doubleSofa ? 2 : 1,
      occupants: occupants,
    );
  }

  void _onSeatTapped(SeatCell cell, Bus bus, Tour tour) {
    if (cell.isEmpty || cell.seatId == null) return;

    // Edit-seats mode → every real seat routes to the Forward/Reserved flag
    // sheet; occupant management and placement are suspended.
    if (_editMode) {
      _showSeatFlagsSheet(cell, bus);
      return;
    }

    // Relocate mode → the tapped seat is the TARGET for the in-hand mover: a
    // free seat moves them here (after confirm), an occupied seat opens the
    // occupant menu with a "seat [mover] here" swap.
    if (_relocate != null) {
      _onRelocateSeatTapped(cell, bus, tour);
      return;
    }

    final assignmentMap = _assignmentMap(tour, bus.id);
    final owners = assignmentMap[cell.seatId] ?? const <String>[];

    // Occupied seat → open the shared occupant action sheet (manage anyone
    // sitting here: call / move / swap / move-to-another-bus / free, with a
    // person toggle for a shared sofa). When a passenger is mid-placement and
    // the seat can be shared, the sheet also offers "seat [name] here".
    if (owners.isNotEmpty) {
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
  void _openOccupantSheet(
    SeatCell cell,
    Bus bus,
    Tour tour,
    List<String> owners, {
    Passenger? active,
  }) {
    final byId = {for (final p in tour.passengers) p.id: p};
    final seen = <String>{};
    final occupants = <Passenger>[];
    for (final id in owners) {
      if (seen.add(id)) {
        final p = byId[id];
        if (p != null) occupants.add(p);
      }
    }
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
        final conflict = _conflictingOccupant(active, occupants);
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
    );
  }

  /// Cancel an occupant's return seat (freeing it), then offer to book a
  /// replacement return ticket straight into the just-freed seat. Only reachable
  /// once the tour is in its return phase (the sheet gates the entry point).
  Future<void> _cancelReturnSeatFlow(Passenger occ) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('tour_detail.cancel_return_confirm_title'),
      message: tr('tour_detail.cancel_return_confirm_body',
          namedArgs: {'name': occ.displayName}),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('tour_detail.cancel_return_cta'),
      destructive: true,
      confirmIcon: Icons.event_busy_rounded,
    );
    if (!ok) return;
    await _ctrl.cancelReturnSeat(widget.tourId, occ.id);
    if (!mounted) return;
    AppSnackBar.success(tr('tour_detail.cancel_return_done',
        namedArgs: {'name': occ.displayName}));

    final rebook = await UgamDialog.confirm(
      context,
      title: tr('tour_detail.cancel_return_rebook_title'),
      message: tr('tour_detail.cancel_return_rebook_body'),
      cancelLabel: tr('app.action.cancel'),
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
    if (moverBerths > targetCap) {
      AppSnackBar.warning(
        tr(
          'tour_seat_assignment.relocate.too_small',
          namedArgs: {'seat': seatId, 'name': mover.displayName},
        ),
      );
      return;
    }

    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('tour_seat_assignment.relocate.move_confirm_title'),
      message: tr(
        'tour_seat_assignment.relocate.move_confirm_body',
        namedArgs: {'name': mover.displayName, 'seat': seatId, 'bus': bus.name},
      ),
      cancelLabel: tr('app.action.cancel'),
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
    final confirmed = await UgamDialog.confirm(
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
      cancelLabel: tr('app.action.cancel'),
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
          trip: o.tripType,
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
    final confirmed = await UgamDialog.confirm(
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
      cancelLabel: tr('app.action.cancel'),
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
  Passenger? _conflictingOccupant(Passenger active, List<Passenger> occupants) {
    final overlap = occupants
        .where((o) => _tripsOverlap(o.tripType, active.tripType))
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
    final confirmed = await UgamDialog.confirm(
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
      cancelLabel: tr('app.action.cancel'),
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
      trip: p.tripType,
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
    if (_editMode) return false;
    if (cell.reserved)
      return false; // a held seat stays put — can't drag it off
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
        final confirmed = await UgamDialog.confirm(
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
          cancelLabel: tr('app.action.cancel'),
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
        // Merge the source pair into the leg-disjoint occupied double: move each
        // sharer's single berth onto the target (its occupants stay put), so all
        // four share one double across opposite legs. Two atomic 1-berth moves.
        for (final o in fromOccs) {
          await _ctrl.moveSeat(
            tourId: tour.id,
            passengerId: o.passengerId,
            busId: bus.id,
            fromSeatId: fromSeatId,
            toSeatId: toSeatId,
            toBusId: bus.id,
            berths: 1,
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

    final footer = await showChartFooterSheet(
      context,
      initial: saved,
      tour: tour,
    );
    if (footer == null) return;
    if (!mounted) return;

    await ChartFooterStore.save(tour.id, footer);
    if (!mounted) return;

    setState(() => _generatingChart = true);
    AppSnackBar.info(tr('chart.generating'));
    try {
      await SeatChartPdf.shareTourChartA4(tour: tour, footer: footer);
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
              return const _NoPassengers();
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

            final canDownload =
                tour.status == TourStatus.locked && tour.buses.isNotEmpty;

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
                    Row(
                      children: [
                        Expanded(
                          child: _BusPills(
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
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        // Edit-seats toggle: ON routes a seat tap to the
                        // Forward/Reserved flag sheet and suspends drag-to-move;
                        // OFF restores tap-to-place + drag. Visible in standalone
                        // and embedded alike.
                        _EditSeatsToggle(
                          editMode: _editMode,
                          onToggle: () =>
                              setState(() => _editMode = !_editMode),
                          c: c,
                        ),
                        const SizedBox(width: UgamSpacing.gutter),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.md),
                    if (_relocate != null)
                      Padding(
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
                              // legend is never hidden behind it.
                              _kCollapsedDockHeight +
                                  MediaQuery.of(context).padding.bottom,
                            ),
                            physics: const BouncingScrollPhysics(),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _SeatGrid(
                                  layout: bus.layout,
                                  tour: tour,
                                  assignmentMap: assignmentMap,
                                  currentPassengerId: passenger?.id,
                                  onTap: (cell) =>
                                      _onSeatTapped(cell, bus, tour),
                                  busName: bus.name,
                                  editMode: _editMode,
                                  // Drag-to-move is live whenever not editing
                                  // flags.
                                  enableDrag: !_editMode,
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
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(bottom: false, child: content),
    );
  }
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

  const _SeatPassengerPicker({
    required this.candidates,
    required this.activeId,
    required this.onPick,
    this.subtitle,
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

  Widget _row(UgamColorSet c, Passenger p) {
    final isActive = p.id == activeId;
    return GestureDetector(
      onTap: () => onPick(p),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: isActive ? Border.all(color: c.accent, width: 1.5) : null,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isActive ? c.accent : c.accentFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                SeatChartTile.initials(p.displayName),
                style: UgamText.bodyStrong.copyWith(
                  color: isActive ? c.onAccent : c.accent,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.displayName,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    p.requestSummary,
                    style: UgamText.micro.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (isActive) ...[
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.check_circle_rounded, size: 16, color: c.accent),
            ],
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

// ─── Edit-seats toggle ─────────────────────────────────────────────────

/// A compact pill that flips the workbench between PLACE mode (tap a free seat
/// to seat the selected passenger; long-press a booked seat to drag-move) and
/// EDIT-SEATS mode (a seat tap opens the Forward/Reserved flag sheet). Mirrors
/// the seat-detail screen's Edit-seats affordance so the two surfaces read the
/// same. Sits at the end of the bus-pills row, visible in both standalone and
/// embedded modes.
class _EditSeatsToggle extends StatelessWidget {
  final bool editMode;
  final VoidCallback onToggle;
  final UgamColorSet c;

  const _EditSeatsToggle({
    required this.editMode,
    required this.onToggle,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: editMode,
      label: editMode
          ? tr('tour_seat_assignment.done_editing_seats')
          : tr('tour_seat_assignment.edit_seats'),
      child: GestureDetector(
        onTap: onToggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
          decoration: BoxDecoration(
            color: editMode ? c.accentFill : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            border: editMode
                ? Border.all(color: c.accent.withValues(alpha: 0.28))
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                editMode ? Icons.check_rounded : Icons.tune_rounded,
                size: 16,
                color: editMode ? c.accent : c.ink,
              ),
              const SizedBox(width: 6),
              Text(
                editMode
                    ? tr('app.action.done')
                    : tr('tour_seat_assignment.edit_seats'),
                style: UgamText.caption.copyWith(
                  color: editMode ? c.accent : c.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
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
      height: 44,
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
            onTap: () => onTapBus(bus.id),
            child: Container(
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
                    style: UgamText.bodyStrong.copyWith(
                      color: selected ? c.accent : c.ink,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? c.accent.withValues(alpha: 0.16)
                          : c.card,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Text(
                      '$assigned/$capacity',
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: selected ? c.accent : c.ink2,
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5,
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
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
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
          GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.sm,
                vertical: 2,
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
        ],
      ),
    );
  }
}

// ─── Seat grid card ────────────────────────────────────────────────────

class _SeatGrid extends StatelessWidget {
  final BusLayout? layout;
  final Tour tour;
  final Map<String, List<String>> assignmentMap;
  final String? currentPassengerId;
  final ValueChanged<SeatCell> onTap;
  final String busName;

  /// True in edit-flags mode: tiles draw the tune glyph + forward ring and a
  /// tap routes to the flag sheet (drag is off).
  final bool editMode;

  // ── Drag-to-move hooks (off in edit-flags mode) ───────────────────────────
  final bool enableDrag;
  final bool dragActive;
  final bool Function(SeatCell cell) canDragSeat;
  final SeatDropHighlight Function(SeatCell cell) dropHighlightFor;
  final String? Function(SeatCell cell) dragLabelFor;
  final void Function(SeatCell cell) onSeatDragStarted;
  final VoidCallback onSeatDragEnded;
  final void Function(String fromSeatId, String toSeatId) onSeatDraggedToSeat;

  const _SeatGrid({
    required this.layout,
    required this.tour,
    required this.assignmentMap,
    required this.currentPassengerId,
    required this.onTap,
    required this.busName,
    required this.editMode,
    required this.enableDrag,
    required this.dragActive,
    required this.canDragSeat,
    required this.dropHighlightFor,
    required this.dragLabelFor,
    required this.onSeatDragStarted,
    required this.onSeatDragEnded,
    required this.onSeatDraggedToSeat,
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
          CombinedSeatGrid(
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
                editMode: editMode,
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
                  child: isMine
                      ? Stack(
                          children: [
                            tile,
                            // Selection ring marks the seats already held by
                            // the passenger currently being assigned.
                            Positioned.fill(
                              child: IgnorePointer(
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
                          ],
                        )
                      : tile,
                ),
              );
            },
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

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        border: Border(top: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  passenger.name.isNotEmpty
                      ? passenger.name[0].toUpperCase()
                      : '?',
                  style: UgamText.bodyStrong.copyWith(
                    color: c.accent,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.sm + 2),
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
                            style: UgamText.titleM.copyWith(
                              color: c.ink,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (handlerId == passenger.id) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.warmFill,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              tr('tour_seat_assignment.badge_handler'),
                              style: UgamText.micro.copyWith(
                                color: c.warm,
                                fontSize: 9.5,
                                letterSpacing: 0.6,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
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
                icon: Icons.edit_outlined,
                size: 38,
                iconSize: 18,
                semanticLabel: tr('tour_seat_assignment.tooltip_edit_request'),
                onTap: () => EditRequestSheet.show(
                  context: context,
                  tour: tour,
                  passenger: passenger,
                ),
              ),
              Text(
                '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}',
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
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
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(6),
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
            const SizedBox(height: UgamSpacing.sm + 2),
            GestureDetector(
              onTap: onManageBuses,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: c.warmFill,
                  borderRadius: BorderRadius.circular(UgamRadius.input - 6),
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
        border: Border(top: BorderSide(color: c.border)),
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
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: hasActive ? c.ink3 : c.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          // Body: full detail when expanded, otherwise the one-line summary.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: showDetail
                ? ConstrainedBox(
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
                ? _compactActive(context)
                : const SizedBox.shrink(),
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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggleExpanded,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.xs,
          UgamSpacing.gutter,
          UgamSpacing.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.accentFill,
                shape: BoxShape.circle,
              ),
              child: Text(
                p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                style: UgamText.bodyStrong.copyWith(color: c.accent, fontSize: 13),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.displayName,
                    style: UgamText.titleM.copyWith(color: c.ink, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
                          style: UgamText.caption.copyWith(color: c.ink3),
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
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }

  /// Pending queue strip (horizontal passenger cards + "+N" overflow) and the
  /// primary lock / download action. Unchanged from the previous dock — just
  /// hosted inside the new sheet.
  Widget _queueRow(BuildContext context) {
    const cap = 8;
    final visible = pending.take(cap).toList();
    final overflow = pending.length - visible.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.xs,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: pending.isEmpty
                ? Row(
                    children: [
                      Icon(Icons.check_circle_rounded, size: 16, color: c.good),
                      const SizedBox(width: UgamSpacing.sm),
                      Expanded(
                        child: Text(
                          tr('tour_seat_assignment.all_assigned_dock'),
                          style: UgamText.bodyStrong.copyWith(
                            color: c.ink,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    height: 64,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: visible.length + (overflow > 0 ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: UgamSpacing.sm),
                      itemBuilder: (ctx, i) {
                        if (i >= visible.length) {
                          // The +N overflow opens a full sheet of every pending
                          // passenger so none are stranded off-screen.
                          return GestureDetector(
                            onTap: () => _showAllPending(ctx),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              width: 70,
                              decoration: BoxDecoration(
                                color: c.cardElev,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.row,
                                ),
                                border: Border.all(color: c.border),
                              ),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '+$overflow',
                                    style: UgamText.bodyStrong.copyWith(
                                      color: c.ink,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    tr('tour_seat_assignment.dock_view_all'),
                                    style: UgamText.micro.copyWith(
                                      color: c.ink3,
                                      fontSize: 8.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        final p = visible[i];
                        final active = activeId == p.id;
                        return _PendingCard(
                          c: c,
                          passenger: p,
                          active: active,
                          onTap: () => onTapPassenger(p.id),
                        );
                      },
                    ),
                  ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          if (onLockTour != null)
            UgamButton(
              label: tr('tour_seat_assignment.btn_lock_notify'),
              icon: Icons.lock_rounded,
              kind: UgamButtonKind.primary,
              onPressed: onLockTour,
            )
          else if (onDownloadChart != null)
            UgamButton(
              label: tr('tour_seat_assignment.btn_download_chart'),
              icon: Icons.download_rounded,
              kind: UgamButtonKind.primary,
              onPressed: onDownloadChart,
            ),
        ],
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
              return GestureDetector(
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  onTapPassenger(p.id);
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  decoration: BoxDecoration(
                    color: cc.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
                    border: selected
                        ? Border.all(color: cc.accent, width: 1.5)
                        : null,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: selected ? cc.accent : cc.accentFill,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          SeatChartTile.initials(p.displayName),
                          style: UgamText.bodyStrong.copyWith(
                            color: selected ? cc.onAccent : cc.accent,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              p.displayName,
                              style: UgamText.bodyStrong.copyWith(
                                color: cc.ink,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p.requestSummary,
                              style: UgamText.micro.copyWith(color: cc.ink2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: UgamSpacing.sm),
                        Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: cc.accent,
                        ),
                      ],
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: cc.ink3,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _PendingCard extends StatelessWidget {
  final UgamColorSet c;
  final Passenger passenger;
  final bool active;
  final VoidCallback onTap;

  const _PendingCard({
    required this.c,
    required this.passenger,
    required this.active,
    required this.onTap,
  });

  String get _initials {
    final name = passenger.displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  String get _needsLabel {
    final remaining =
        passenger.totalSeatsRequested - passenger.totalSeatsAssigned;
    if (remaining <= 0) return passenger.requestSummary;
    final firstLine = passenger.requestLines.isNotEmpty
        ? passenger.requestLines.first.shortLabel
        : tr(
            'tour_seat_assignment.needs_seat',
            namedArgs: {'count': '$remaining'},
          );
    if (passenger.requestLines.length <= 1) return firstLine;
    return '$firstLine +${passenger.requestLines.length - 1}';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 116,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.sm,
          vertical: UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(
            color: active ? c.accent : c.border,
            width: active ? 1.2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: active ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                _initials,
                style: UgamText.bodyStrong.copyWith(
                  color: active ? c.onAccent : c.ink,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    passenger.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _needsLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.caption.copyWith(
                      color: active ? c.accent : c.ink2,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
        padding: const EdgeInsets.all(UgamSpacing.huge),
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
  const _NoPassengers();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.huge),
        child: UgamEmpty(
          icon: Icons.people_outline_rounded,
          title: tr('tour_seat_assignment.no_passengers_title'),
          body: tr('tour_seat_assignment.no_passengers_body'),
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
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
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
        _FlagSwitch(
          icon: Icons.star_rounded,
          title: tr('tour_seat_assignment.flags.forward_title'),
          subtitle: tr('tour_seat_assignment.flags.forward_subtitle'),
          value: _forward,
          // Warm = attention; the forward zone is the priority/premium band.
          activeColor: c.warm,
          c: c,
          onChanged: (v) {
            setState(() => _forward = v);
            widget.onForward(v);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _FlagSwitch(
          icon: Icons.lock_outline_rounded,
          title: tr('tour_seat_assignment.flags.reserved_title'),
          subtitle: tr('tour_seat_assignment.flags.reserved_subtitle'),
          value: _reserved,
          activeColor: c.accent,
          c: c,
          onChanged: (v) {
            setState(() => _reserved = v);
            widget.onReserved(v);
          },
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamButton(
          label: tr('app.action.done'),
          kind: UgamButtonKind.ghost,
          onPressed: () => Navigator.of(context).pop(),
          expand: true,
        ),
      ],
    );
  }
}

class _FlagSwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final Color activeColor;
  final UgamColorSet c;
  final ValueChanged<bool> onChanged;

  const _FlagSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.activeColor,
    required this.c,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(
          color: value ? activeColor.withValues(alpha: 0.5) : c.border,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: value ? activeColor : c.ink3),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: UgamText.bodyStrong.copyWith(color: c.ink)),
                const SizedBox(height: 1),
                Text(subtitle, style: UgamText.micro.copyWith(color: c.ink2)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: activeColor,
            activeThumbColor: c.onAccent,
          ),
        ],
      ),
    );
  }
}
