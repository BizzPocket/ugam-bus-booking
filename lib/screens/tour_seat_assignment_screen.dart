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
import '../services/chart_footer_store.dart';
import '../services/seat_chart_pdf.dart';
import '../utils/app_dialogs.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_drop_engine.dart';
import '../utils/seat_leg_capacity.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
import '../widgets/occupant_action_sheet.dart';
import '../widgets/chart_footer_sheet.dart';
import '../widgets/edit_request_sheet.dart';
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
///   * Pending dock pinned to the bottom — horizontal passenger cards +
///     auto-pick / done circle column. The "Lock tour" pill appears in
///     the dock when `tour.allSeatsAssigned && tour.handlerId != null`.
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

  /// Total occupants across all seats on a bus — a shared double counts
  /// as 2, not 1. Used wherever we display "seats sold" totals.
  int _occupants(Map<String, List<String>> assignmentMap) =>
      assignmentMap.values.fold<int>(0, (sum, list) => sum + list.length);

  /// Pending request lines for the passenger after subtracting what's
  /// already been assigned.
  List<_PendingLine> _pendingLines(Passenger passenger, {Tour? tour}) {
    final pending = <_PendingLine>[];
    for (final line in passenger.requestLines) {
      pending.add(
        _PendingLine(
          seatType: line.seatType,
          position: line.position,
          remaining: line.qty,
          totalRequested: line.qty,
        ),
      );
    }
    final t = tour ?? _tour;
    if (t == null) return pending;

    // Group this passenger's berths by physical cell.
    final groups = <String, _CellGroup>{};
    for (final a in passenger.assignedSeats) {
      final key = '${a.busId}:${a.seatId}';
      groups
          .putIfAbsent(key, () => _CellGroup(busId: a.busId, seatId: a.seatId))
          .berths++;
    }

    // Track berths that didn't find a matching exact-type line on the
    // first pass — used for the cross-fill rule (2 singles can satisfy
    // 1 doubleSofa line when the bus is short on doubles).
    int leftoverSingleBerths = 0;
    int leftoverHalfDoubles = 0;

    for (final g in groups.values) {
      final cell = _findCell(t, g.busId, g.seatId);
      if (cell == null) continue;

      if (cell.seatType == SeatType.singleSofa) {
        for (var i = 0; i < g.berths; i++) {
          if (!_drainPending(pending, [SeatType.singleSofa], cell.position)) {
            leftoverSingleBerths++;
          }
        }
        continue;
      }

      if (cell.seatType == SeatType.seater) {
        for (var i = 0; i < g.berths; i++) {
          _drainPending(pending, [SeatType.seater], cell.position);
        }
        continue;
      }

      // doubleSofa
      if (g.berths >= 2) {
        // Whole double held solo. Prefer the doubleSofa line; otherwise
        // consume 2 single lines.
        if (!_drainPending(pending, [SeatType.doubleSofa], cell.position)) {
          _drainPending(pending, [SeatType.singleSofa], cell.position);
          _drainPending(pending, [SeatType.singleSofa], cell.position);
        }
      } else {
        // 1 berth on a double — half-share. Prefer single, fall back to
        // a half-of-double counted toward a doubleSofa line in the
        // cross-fill pass below.
        if (!_drainPending(pending, [SeatType.singleSofa], cell.position)) {
          leftoverHalfDoubles++;
        }
      }
    }

    // Cross-fill: two leftover single-class berths (single sofas OR
    // half-doubles) drain ONE doubleSofa line.
    int leftoverPairs = (leftoverSingleBerths + leftoverHalfDoubles) ~/ 2;
    while (leftoverPairs > 0) {
      if (_drainPending(pending, [SeatType.doubleSofa], null)) {
        leftoverPairs--;
      } else {
        break;
      }
    }

    return pending;
  }

  /// Decrement the first pending line whose `seatType` is in [tryTypes]
  /// (checked in order) and whose position matches [cellPos]. Returns
  /// true when something was decremented.
  bool _drainPending(
    List<_PendingLine> pending,
    List<SeatType> tryTypes,
    SeatPosition? cellPos,
  ) {
    for (final t in tryTypes) {
      final idx = pending.indexWhere(
        (l) =>
            l.seatType == t &&
            (l.position == null || l.position == cellPos) &&
            l.remaining > 0,
      );
      if (idx >= 0) {
        pending[idx] = pending[idx].copyDecremented();
        return true;
      }
    }
    return false;
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
  int _berthsForFreeCell(Passenger passenger, SeatCell cell, {Tour? tour}) {
    final pending = _pendingLines(passenger, tour: tour);
    bool positionOk(_PendingLine l) =>
        l.position == null || l.position == cell.position;

    if (cell.seatType == SeatType.doubleSofa) {
      final hasDoubleLine = pending.any(
        (l) =>
            l.seatType == SeatType.doubleSofa &&
            positionOk(l) &&
            l.remaining > 0,
      );
      if (hasDoubleLine) return 2;
      final singleRemaining = pending
          .where(
            (l) =>
                l.seatType == SeatType.singleSofa &&
                positionOk(l) &&
                l.remaining > 0,
          )
          .fold<int>(0, (sum, l) => sum + l.remaining);
      if (singleRemaining >= 2) return 2;
      if (singleRemaining == 1) return 1;
      return 0;
    }

    if (cell.seatType == SeatType.singleSofa) {
      final hasSingleLine = pending.any(
        (l) =>
            l.seatType == SeatType.singleSofa &&
            positionOk(l) &&
            l.remaining > 0,
      );
      if (hasSingleLine) return 1;
      final hasDoubleLine = pending.any(
        (l) => l.seatType == SeatType.doubleSofa && l.remaining > 0,
      );
      if (hasDoubleLine) return 1;
      return 0;
    }

    final hasMatch = pending.any(
      (l) => l.seatType == cell.seatType && positionOk(l) && l.remaining > 0,
    );
    return hasMatch ? 1 : 0;
  }

  void _onSeatTapped(SeatCell cell, Bus bus, Tour tour) {
    if (cell.isEmpty || cell.seatId == null) return;

    // Edit-seats mode → every real seat routes to the Forward/Reserved flag
    // sheet; occupant management and placement are suspended.
    if (_editMode) {
      _showSeatFlagsSheet(cell, bus);
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

    final c = UgamColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (sheetCtx) => _SeatPassengerPicker(
        seatId: cell.seatId ?? '',
        busName: bus.name,
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
    if (active != null && !owners.contains(active.id)) {
      final berths = _seatHereBerths(tour, bus, cell, active, occupants);
      if (berths > 0) {
        placing = active;
        onSeatHere = () =>
            _seatHere(active, bus, tour, cell, occupants.first, berths);
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
    final need = _berthsForFreeCell(active, cell, tour: tour);
    if (need == 0) return 0;
    final cap = cell.seatType == SeatType.doubleSofa ? 2 : 1;

    final holders = <SeatLegHolder>[
      for (final o in occupants)
        (
          trip: o.tripType,
          berths: o.assignedSeats
              .where((a) => a.busId == bus.id && a.seatId == seatId)
              .length,
        ),
    ];

    return seatHasLegRoom(
      activeTrip: active.tripType,
      need: need,
      cap: cap,
      occupants: holders,
    )
        ? need
        : 0;
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
    final confirmed = await AppDialogs.confirm(
      title: tr('tour_seat_assignment.share_confirm_title'),
      message: tr(
        'tour_seat_assignment.share_confirm_body',
        namedArgs: {
          'seat': cell.seatId!,
          'otherName': other.displayName,
          'currentName': passenger.displayName,
        },
      ),
      confirmText: tr('tour_seat_assignment.share_confirm_yes'),
    );
    if (!confirmed) return;
    await _placeBerths(passenger, bus, tour, cell, berths);
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
  List<SeatOccupant> _occupantsOn(Tour tour, Bus bus, SeatCell cell) {
    final seatId = cell.seatId;
    if (seatId == null) return const [];
    final ids = _assignmentMap(tour, bus.id)[seatId] ?? const <String>[];
    final seen = <String>{};
    final out = <SeatOccupant>[];
    for (final id in ids) {
      if (!seen.add(id)) continue;
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
    SeatCell target,
  ) {
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
      fromOccupants: _occupantsOn(tour, bus, fromCell),
      targetOccupants: _occupantsOn(tour, bus, target),
    );
  }

  /// Whether [cell] can be PICKED UP for a drag — any occupant (a shared double
  /// lifts BOTH together).
  bool _canDragSeat(Tour tour, Bus bus, SeatCell cell) =>
      !_editMode && _occupantsOn(tour, bus, cell).isNotEmpty;

  /// Chip label that follows the finger — the occupant's name, or "A + B" for a
  /// shared double moving as a unit.
  String? _dragLabelFor(Tour tour, Bus bus, SeatCell cell) {
    final ids = (cell.seatId == null
            ? const <String>[]
            : _assignmentMap(tour, bus.id)[cell.seatId] ?? const <String>[])
        .toSet();
    if (ids.isEmpty) return null;
    final names = ids
        .map((id) =>
            tour.passengers.firstWhereOrNull((p) => p.id == id)?.displayName)
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
      default:
        return SeatDropHighlight.dim;
    }
  }

  /// Toast explaining why a drop was rejected.
  void _toastBlocked(SeatDropBlock block, SeatCell fromCell, String toSeatId) {
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
          tr('tour_seat_assignment.drop.too_small_body', namedArgs: {
            'name': _dragLabelFor(_tour!, _selectedBus(_tour!)!, fromCell) ?? '',
          }),
          title: tr('tour_seat_assignment.drop.too_small_title'),
        );
        return;
      case SeatDropBlock.held:
        AppSnackBar.warning(
          tr('tour_seat_assignment.drop.held_body',
              namedArgs: {'seat': toSeatId}),
          title: tr('tour_seat_assignment.drop.held_title'),
        );
        return;
      case SeatDropBlock.sharedTargetAmbiguous:
      case SeatDropBlock.noLegRoom:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_body'),
          title: tr('tour_seat_assignment.drop.shared_title'),
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

  /// Resolve a released drag from [fromSeatId] onto [toSeatId] on [bus] by
  /// dispatching the engine verdict.
  Future<void> _handleSeatDrop(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId,
  ) async {
    final fromCell = _findCell(tour, bus.id, fromSeatId);
    final targetCell = _findCell(tour, bus.id, toSeatId);
    if (fromCell == null || targetCell == null) return;
    final fromOccs = _occupantsOn(tour, bus, fromCell);
    if (fromOccs.isEmpty) return;

    final decision = _decideDrop(tour, bus, fromCell, targetCell);
    final mover = tour.passengers
        .firstWhereOrNull((p) => p.id == fromOccs.first.passengerId);

    switch (decision.action) {
      case SeatDropAction.blocked:
        _toastBlocked(decision.block!, fromCell, toSeatId);
        return;

      case SeatDropAction.move:
        if (mover == null) return;
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
        );
        AppSnackBar.success(
          tr('tour_seat_assignment.drop.moved_body',
              namedArgs: {'name': mover.displayName, 'seat': toSeatId}),
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
          tr('tour_seat_assignment.drop.split_body',
              namedArgs: {'name': mover.displayName, 'seat': toSeatId}),
          title: tr('tour_seat_assignment.drop.split_title'),
        );
        return;

      case SeatDropAction.fill:
        if (mover == null) return;
        final occ = tour.passengers
            .firstWhereOrNull((p) => p.id == _occupantsOn(tour, bus, targetCell)
                .firstOrNull
                ?.passengerId);
        if (occ == null) return;
        final confirmed = await AppDialogs.confirm(
          title: tr('tour_seat_assignment.share_confirm_title'),
          message: tr('tour_seat_assignment.share_confirm_body', namedArgs: {
            'seat': toSeatId,
            'otherName': occ.displayName,
            'currentName': mover.displayName,
          }),
          confirmText: tr('tour_seat_assignment.share_confirm_yes'),
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
          tr('tour_seat_assignment.drop.filled_body', namedArgs: {
            'a': mover.displayName,
            'b': occ.displayName,
            'seat': toSeatId,
          }),
          title: tr('tour_seat_assignment.drop.filled_title'),
        );
        return;

      case SeatDropAction.swap:
        if (mover == null) return;
        final occ = tour.passengers.firstWhereOrNull(
          (p) => p.id == _occupantsOn(tour, bus, targetCell).first.passengerId,
        );
        if (occ == null) return;
        await _ctrl.swapSeats(
          tourId: tour.id,
          busId: bus.id,
          passengerAId: mover.id,
          seatAId: fromSeatId,
          passengerBId: occ.id,
          seatBId: toSeatId,
          busBId: bus.id,
        );
        AppSnackBar.success(
          tr('tour_seat_assignment.drop.swapped_body',
              namedArgs: {'a': mover.displayName, 'b': occ.displayName}),
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
          tr('tour_seat_assignment.drop.moved_both_body', namedArgs: {
            'names': _dragLabelFor(tour, bus, fromCell) ?? '',
            'seat': toSeatId,
          }),
          title: tr('tour_seat_assignment.drop.moved_both_title'),
        );
        return;
    }
  }

  // ── Edit seats: Forward / Reserved flags ────────────────────────────────

  /// Edit-mode tap on a seat → a small sheet with two switches: "Forward /
  /// premium seat" ([TourController.setSeatForward]) and "Hold / reserved"
  /// ([TourController.setSeatReserved]). The chart repaints reactively once the
  /// controller mutates the bus layout.
  void _showSeatFlagsSheet(SeatCell cell, Bus bus) {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final c = UgamColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (_) => _SeatFlagsSheet(
        seatId: seatId,
        typeLabel: cell.typeLabel,
        busName: bus.name,
        forward: cell.forward,
        reserved: cell.reserved,
        onForward: (v) => _ctrl.setSeatForward(widget.tourId, bus.id, seatId, v),
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
          _TopBar(
            title: tr('tour_seat_assignment.title'),
            tourId: widget.tourId,
            c: c,
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
                .where((p) =>
                    !p.isFullyAssigned && !p.isWaitlisted && !p.journeyDone)
                .toList();

            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _BusPills(
                        buses: tour.buses,
                        selectedBusId: bus.id,
                        seatsAssignedFor: (id) => _occupants(
                          assignmentsByBus[id] ??
                              const <String, List<String>>{},
                        ),
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
                      onToggle: () => setState(() => _editMode = !_editMode),
                      c: c,
                    ),
                    const SizedBox(width: UgamSpacing.gutter),
                  ],
                ),
                const SizedBox(height: UgamSpacing.md),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          0,
                          UgamSpacing.gutter,
                          UgamSpacing.sm,
                        ),
                        physics: const BouncingScrollPhysics(),
                        child: _SeatGrid(
                          layout: bus.layout,
                          tour: tour,
                          assignmentMap: assignmentMap,
                          currentPassengerId: passenger?.id,
                          onTap: (cell) => _onSeatTapped(cell, bus, tour),
                          busName: bus.name,
                          editMode: _editMode,
                          // Drag-to-move is live whenever not editing flags.
                          enableDrag: !_editMode,
                          dragActive: _dragActive,
                          canDragSeat: (cell) => _canDragSeat(tour, bus, cell),
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
                              _handleSeatDrop(tour, bus, fromSeatId, toSeatId),
                        ),
                      );
                    },
                  ),
                ),
                if (passenger != null)
                  _PassengerCard(
                    tour: tour,
                    passenger: passenger,
                    pending: _pendingLines(passenger),
                    allPassengers: tour.passengers,
                    handlerId: tour.handlerId,
                    onChange: (id) => _selectPassenger(tour, id),
                    onManageBuses: () =>
                        Get.to(() => ManageBusesScreen(tourId: widget.tourId)),
                  ),
                _PendingDock(
                  c: c,
                  pending: pending,
                  activeId: passenger?.id,
                  onTapPassenger: (id) => _selectPassenger(tour, id),
                  onLockTour: canLock ? () => _openLockAndNotify(tour) : null,
                  onDownloadChart: canDownload
                      ? () => _downloadChart(tour)
                      : null,
                ),
                SizedBox(
                  height:
                      MediaQuery.of(context).padding.bottom + UgamSpacing.xs,
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

/// Per-cell tally used by `_pendingLines`. `berths` is how many entries
/// in `Passenger.assignedSeats` point at this cell — 1 for a regular
/// seat or half-double, 2 when the passenger owns a whole double solo.
class _CellGroup {
  final String busId;
  final String seatId;
  int berths;
  _CellGroup({required this.busId, required this.seatId}) : berths = 0;
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
/// the currently-selected passenger (if any) is tagged at the top.
class _SeatPassengerPicker extends StatelessWidget {
  final String seatId;
  final String busName;
  final List<Passenger> candidates;
  final String? activeId;
  final ValueChanged<Passenger> onPick;

  const _SeatPassengerPicker({
    required this.seatId,
    required this.busName,
    required this.candidates,
    required this.activeId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: UgamSpacing.md),
              decoration: BoxDecoration(
                color: c.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            tr(
              'tour_seat_assignment.picker_title',
              namedArgs: {'seat': seatId, 'bus': busName},
            ),
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            tr('tour_seat_assignment.picker_subtitle'),
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
      ),
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
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                SeatChartTile.initials(p.displayName),
                style: UgamText.bodyStrong.copyWith(
                  color: c.onAccent,
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

// ─── Top bar ───────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title;
  final String tourId;
  final UgamColorSet c;

  const _TopBar({required this.title, required this.tourId, required this.c});

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
              title,
              style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: () => Get.to(() => ManageBusesScreen(tourId: tourId)),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.directions_bus_filled_rounded,
                size: 19,
                color: c.ink,
              ),
            ),
          ),
        ],
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
            color: editMode ? c.accent : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                editMode ? Icons.check_rounded : Icons.tune_rounded,
                size: 16,
                color: editMode ? c.onAccent : c.ink,
              ),
              const SizedBox(width: 6),
              Text(
                editMode
                    ? tr('app.action.done')
                    : tr('tour_seat_assignment.edit_seats'),
                style: UgamText.caption.copyWith(
                  color: editMode ? c.onAccent : c.ink,
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
                color: selected ? c.accent : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bus.name,
                    style: UgamText.bodyStrong.copyWith(
                      color: selected ? c.onAccent : c.ink,
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
                          ? c.onAccent.withValues(alpha: 0.18)
                          : c.card,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Text(
                      '$assigned/$capacity',
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: selected ? c.onAccent : c.ink2,
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
  final List<Passenger> allPassengers;

  /// Tour-wide handler pointer — kept only to badge the handler in this card
  /// and to drive the "assign a handler" nudge. Handlers are now assigned
  /// PER BUS on the Manage Buses screen, so there's no toggle here.
  final String? handlerId;
  final ValueChanged<String> onChange;

  /// Opens Manage Buses, where each bus's handler is picked.
  final VoidCallback onManageBuses;

  const _PassengerCard({
    required this.tour,
    required this.passenger,
    required this.pending,
    required this.allPassengers,
    required this.handlerId,
    required this.onChange,
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
                                fontSize: 8,
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
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: tr('tour_seat_assignment.tooltip_edit_request'),
                onPressed: () => EditRequestSheet.show(
                  context: context,
                  tour: tour,
                  passenger: passenger,
                ),
                icon: Icon(Icons.edit_outlined, size: 20, color: c.ink3),
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
          // Inline passenger picker — kept simple chips so the agent can
          // quickly jump between requests without leaving the screen.
          const SizedBox(height: UgamSpacing.sm + 2),
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: allPassengers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (ctx, i) {
                final p = allPassengers[i];
                final selected = p.id == passenger.id;
                return GestureDetector(
                  onTap: () => onChange(p.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? c.accent : c.cardElev,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (p.isFullyAssigned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.check_circle_rounded,
                              size: 12,
                              color: selected ? c.onAccent : c.good,
                            ),
                          ),
                        Text(
                          p.displayName,
                          style: UgamText.caption.copyWith(
                            color: selected ? c.onAccent : c.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Pending dock ──────────────────────────────────────────────────────

class _PendingDock extends StatelessWidget {
  final UgamColorSet c;
  final List<Passenger> pending;
  final String? activeId;
  final ValueChanged<String> onTapPassenger;
  final VoidCallback? onLockTour;
  final VoidCallback? onDownloadChart;

  const _PendingDock({
    required this.c,
    required this.pending,
    required this.activeId,
    required this.onTapPassenger,
    required this.onLockTour,
    this.onDownloadChart,
  });

  @override
  Widget build(BuildContext context) {
    const cap = 8;
    final visible = pending.take(cap).toList();
    final overflow = pending.length - visible.length;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        border: Border(top: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 2,
        UgamSpacing.gutter,
        UgamSpacing.sm + 2,
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
                          return Container(
                            width: 70,
                            decoration: BoxDecoration(
                              color: c.cardElev,
                              borderRadius: BorderRadius.circular(
                                UgamRadius.row,
                              ),
                              border: Border.all(color: c.border),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '+$overflow',
                              style: UgamText.bodyStrong.copyWith(
                                color: c.ink2,
                                fontSize: 13,
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
        width: 104,
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
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: active ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                _initials,
                style: UgamText.bodyStrong.copyWith(
                  color: active ? c.onAccent : c.ink,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 6),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: UgamSpacing.md),
              decoration: BoxDecoration(
                color: c.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
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
      ),
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
