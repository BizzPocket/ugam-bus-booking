import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../design/ugam.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/app_dialogs.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../widgets/edit_request_sheet.dart';
import 'manage_buses_screen.dart';

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
///     `_drainPending`, `_findCell`, `_toggleHandler`, `_lockTour`.
class TourSeatAssignmentScreen extends StatefulWidget {
  final String tourId;

  /// Optional. When set, the screen lands on this specific passenger so
  /// the agent can start tapping seats immediately. Passed through from
  /// the "Assign Seats →" button on the Requests screen.
  final String? initialPassengerId;

  const TourSeatAssignmentScreen({
    super.key,
    required this.tourId,
    this.initialPassengerId,
  });

  @override
  State<TourSeatAssignmentScreen> createState() =>
      _TourSeatAssignmentScreenState();
}

class _TourSeatAssignmentScreenState extends State<TourSeatAssignmentScreen> {
  String? _selectedBusId;
  String? _selectedPassengerId;

  @override
  void initState() {
    super.initState();
    _selectedPassengerId = widget.initialPassengerId;
  }

  TourController get _ctrl => Get.find<TourController>();

  Tour? get _tour => _ctrl.getTour(widget.tourId);

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
    final partial =
        tour.passengers.where((p) => !p.isFullyAssigned).toList();
    if (partial.isNotEmpty) return partial.first;
    return tour.passengers.first;
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
      pending.add(_PendingLine(
        seatType: line.seatType,
        position: line.position,
        remaining: line.qty,
        totalRequested: line.qty,
      ));
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
      final idx = pending.indexWhere((l) =>
          l.seatType == t &&
          (l.position == null || l.position == cellPos) &&
          l.remaining > 0);
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
      final hasDoubleLine = pending.any((l) =>
          l.seatType == SeatType.doubleSofa &&
          positionOk(l) &&
          l.remaining > 0);
      if (hasDoubleLine) return 2;
      final singleRemaining = pending
          .where((l) =>
              l.seatType == SeatType.singleSofa &&
              positionOk(l) &&
              l.remaining > 0)
          .fold<int>(0, (sum, l) => sum + l.remaining);
      if (singleRemaining >= 2) return 2;
      if (singleRemaining == 1) return 1;
      return 0;
    }

    if (cell.seatType == SeatType.singleSofa) {
      final hasSingleLine = pending.any((l) =>
          l.seatType == SeatType.singleSofa &&
          positionOk(l) &&
          l.remaining > 0);
      if (hasSingleLine) return 1;
      final hasDoubleLine = pending.any((l) =>
          l.seatType == SeatType.doubleSofa && l.remaining > 0);
      if (hasDoubleLine) return 1;
      return 0;
    }

    final hasMatch = pending.any((l) =>
        l.seatType == cell.seatType && positionOk(l) && l.remaining > 0);
    return hasMatch ? 1 : 0;
  }

  Future<void> _onSeatTapped(SeatCell cell, Bus bus, Tour tour) async {
    if (cell.isEmpty || cell.seatId == null) return;
    final passenger = _selectedPassenger(tour);
    if (passenger == null) {
      AppSnackBar.error(tr('tour_seat_assignment.err_no_passengers'));
      return;
    }

    final assignmentMap = _assignmentMap(tour, bus.id);
    final owners = assignmentMap[cell.seatId] ?? const <String>[];
    int berthsToAdd;

    // Tap on own assigned seat → drop this passenger's claim. Doesn't
    // affect a co-owner (e.g. the other half of a shared double).
    if (owners.contains(passenger.id)) {
      final next = List<SeatAssignment>.from(passenger.assignedSeats)
        ..removeWhere(
            (a) => a.busId == bus.id && a.seatId == cell.seatId);
      await _ctrl.assignSeats(tour.id, passenger.id, next);
      return;
    }

    // Cell already occupied. Two sub-cases:
    //   a) doubleSofa with exactly one other passenger → offer the share
    //      flow (the agent talks to the existing occupant and agrees to
    //      split the sofa between two unrelated singles).
    //   b) anything else → refuse as taken.
    if (owners.isNotEmpty) {
      final isShareEligible =
          cell.seatType == SeatType.doubleSofa && owners.length == 1;
      if (!isShareEligible) {
        final firstOther = tour.passengers
            .where((p) => p.id == owners.first)
            .toList()
            .firstOrNull;
        AppSnackBar.warning(
          tr('tour_seat_assignment.err_seat_taken', namedArgs: {
            'seat': cell.seatId!,
            'otherName': firstOther?.name ??
                tr('tour_seat_assignment.err_seat_taken_fallback_name'),
          }),
        );
        return;
      }

      // Share path. A singleSofa OR doubleSofa pending line can claim
      // half of the double (position match still required when the line
      // specifies a position).
      final pending = _pendingLines(passenger, tour: tour);
      final matchIdx = pending.indexWhere((l) =>
          (l.seatType == SeatType.singleSofa ||
              l.seatType == SeatType.doubleSofa) &&
          (l.position == null || l.position == cell.position) &&
          l.remaining > 0);
      if (matchIdx < 0) {
        AppSnackBar.warning(
          tr('tour_seat_assignment.err_type_mismatch', namedArgs: {
            'passengerName': passenger.displayName,
            'seatType': seatTypeLabel(cell.seatType!, cell.position),
          }),
        );
        return;
      }

      final otherP = tour.passengers
          .where((p) => p.id == owners.first)
          .toList()
          .firstOrNull;
      final confirmed = await AppDialogs.confirm(
        title: tr('tour_seat_assignment.share_confirm_title'),
        message: tr('tour_seat_assignment.share_confirm_body', namedArgs: {
          'seat': cell.seatId!,
          'otherName': otherP?.displayName ??
              tr('tour_seat_assignment.err_seat_taken_fallback_name'),
          'currentName': passenger.displayName,
        }),
        confirmText: tr('tour_seat_assignment.share_confirm_yes'),
      );
      if (!confirmed) return;
      berthsToAdd = 1;
    } else {
      // Free seat — decide how many berths to claim on this cell.
      berthsToAdd = _berthsForFreeCell(passenger, cell, tour: tour);
      if (berthsToAdd == 0) {
        AppSnackBar.warning(
          tr('tour_seat_assignment.err_type_mismatch', namedArgs: {
            'passengerName': passenger.displayName,
            'seatType': seatTypeLabel(cell.seatType!, cell.position),
          }),
        );
        return;
      }
    }

    final next = List<SeatAssignment>.from(passenger.assignedSeats);
    for (var i = 0; i < berthsToAdd; i++) {
      next.add(SeatAssignment(busId: bus.id, seatId: cell.seatId!));
    }
    await _ctrl.assignSeats(tour.id, passenger.id, next);

    // Auto-advance to next unassigned passenger when current is done.
    final updatedTour = _ctrl.getTour(tour.id);
    final updatedPassenger = updatedTour?.passengers
        .firstWhere((p) => p.id == passenger.id, orElse: () => passenger);

    if (updatedPassenger != null && updatedPassenger.isFullyAssigned) {
      AppSnackBar.success(
        tr('tour_seat_assignment.snack_fully_assigned_body',
            namedArgs: {'passengerName': passenger.displayName}),
        title: tr('tour_seat_assignment.snack_fully_assigned_title'),
      );

      final nextUnassigned = updatedTour!.passengers
          .where((p) => !p.isFullyAssigned)
          .toList();
      if (nextUnassigned.isNotEmpty) {
        setState(() => _selectedPassengerId = nextUnassigned.first.id);
      } else if (updatedTour.handlerId != null) {
        AppSnackBar.success(
          tr('tour_seat_assignment.snack_all_done_body'),
          title: tr('tour_seat_assignment.snack_all_done_title'),
        );
      } else {
        AppSnackBar.warning(
          tr('tour_seat_assignment.snack_no_handler'),
        );
      }
    } else {
      AppSnackBar.success(
        tr('tour_seat_assignment.snack_seat_saved',
            namedArgs: {'seatId': cell.seatId!}),
      );
    }
  }

  Future<void> _toggleHandler(Tour tour, String passengerId) async {
    if (tour.handlerId == passengerId) {
      await _ctrl.removeHandler(tour.id);
      AppSnackBar.success(tr('tour_seat_assignment.snack_handler_removed'));
    } else {
      await _ctrl.setHandler(tour.id, passengerId);
      final p = tour.passengers
          .where((x) => x.id == passengerId)
          .toList()
          .firstOrNull;
      AppSnackBar.success(
        tr('tour_seat_assignment.snack_handler_set', namedArgs: {
          'name': p?.name ??
              tr('tour_seat_assignment.snack_handler_set_fallback_name'),
        }),
      );
    }
  }

  Future<void> _lockTour(Tour tour) async {
    if (!tour.allSeatsAssigned) {
      AppSnackBar.error(tr('tour_seat_assignment.err_not_all_assigned'));
      return;
    }
    if (tour.handlerId == null) {
      AppSnackBar.error(tr('tour_seat_assignment.err_no_handler'));
      return;
    }
    await _ctrl.lockTour(tour.id);
    AppSnackBar.success(tr('tour_seat_assignment.snack_tour_locked'));
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        // The header doesn't depend on any reactive state — hoist it
        // above the Obx so realtime tour updates don't repaint it.
        child: Column(
          children: [
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
                final assignmentMap = assignmentsByBus[bus.id] ??
                    const <String, List<String>>{};


                final canLock = tour.status == TourStatus.assigning &&
                    tour.allSeatsAssigned &&
                    tour.handlerId != null;

                final pending = tour.passengers
                    .where((p) => !p.isFullyAssigned && !p.isWaitlisted)
                    .toList();

                return Column(
                  children: [
                    _BusPills(
                      buses: tour.buses,
                      selectedBusId: bus.id,
                      seatsAssignedFor: (id) => _occupants(
                          assignmentsByBus[id] ??
                              const <String, List<String>>{}),
                      onTapBus: (id) {
                        setState(() {
                          _selectedBusId = id;
                        });
                      },
                      c: c,
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
                              assignmentMap: assignmentMap,
                              currentPassengerId: passenger?.id,
                              onTap: (cell) => _onSeatTapped(cell, bus, tour),
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
                        onChange: (id) =>
                            setState(() => _selectedPassengerId = id),
                        onToggleHandler: (id) => _toggleHandler(tour, id),
                      ),
                    _PendingDock(
                      c: c,
                      pending: pending,
                      activeId: passenger?.id,
                      onTapPassenger: (id) =>
                          setState(() => _selectedPassengerId = id),
                      onLockTour: canLock ? () => _lockTour(tour) : null,
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
        ),
      ),
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

// ─── Top bar ───────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title;
  final String tourId;
  final UgamColorSet c;

  const _TopBar({
    required this.title,
    required this.tourId,
    required this.c,
  });

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
                        horizontal: 6, vertical: 2),
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
  final Map<String, List<String>> assignmentMap;
  final String? currentPassengerId;
  final ValueChanged<SeatCell> onTap;

  const _SeatGrid({
    required this.layout,
    required this.assignmentMap,
    required this.currentPassengerId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null) {
      return const _NoLayout();
    }

    const double tileW = 56;
    const double tileH = 58;

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: CombinedSeatGrid(
        layout: l,
        cellWidth: tileW,
        cellHeight: tileH,
        colGap: 8,
        rowGap: 8,
        driverLabel: tr('tour_seat_assignment.grid_label_driver'),
        tileBuilder: (ctx, cell) {
          final owners = assignmentMap[cell.seatId] ?? const <String>[];
          final mineCount = currentPassengerId == null
              ? 0
              : owners.where((id) => id == currentPassengerId).length;
          final otherCount = owners.length - mineCount;
          return SizedBox(
            width: tileW,
            height: tileH,
            child: RepaintBoundary(
              child: _SeatTile(
                cell: cell,
                mineCount: mineCount,
                otherCount: otherCount,
                onTap: () => onTap(cell),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SeatTile extends StatelessWidget {
  final SeatCell cell;
  final int mineCount;
  final int otherCount;
  final VoidCallback onTap;

  const _SeatTile({
    required this.cell,
    required this.mineCount,
    required this.otherCount,
    required this.onTap,
  });

  bool get isMine => mineCount > 0;

  bool get _needsSplit {
    if (cell.seatType != SeatType.doubleSofa) return false;
    final total = mineCount + otherCount;
    if (total == 0 || total >= 2 && (mineCount == 2 || otherCount == 2)) {
      return false;
    }
    return true;
  }

  String? get _typeMark {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return 'S';
      case SeatType.doubleSofa:
        return 'D';
      case SeatType.seater:
        return 'T';
      case null:
        return null;
    }
  }

  Color _typeTint(UgamColorSet c) {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return c.goodFill;
      case SeatType.doubleSofa:
        return c.accentFill;
      case SeatType.seater:
        return c.cardElev;
      case null:
        return c.card;
    }
  }

  Color _typeBorder(UgamColorSet c) {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return c.good.withValues(alpha: 0.45);
      case SeatType.doubleSofa:
        return c.accent.withValues(alpha: 0.35);
      case SeatType.seater:
        return c.border;
      case null:
        return c.border;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final isOther = otherCount > 0;
    final mark = _typeMark;

    if (_needsSplit) {
      final Color leftColor;
      final Color rightColor;
      if (isMine && otherCount > 0) {
        leftColor = c.warm;
        rightColor = c.accent;
      } else if (isMine) {
        leftColor = c.warm;
        rightColor = _typeTint(c);
      } else {
        leftColor = c.accent;
        rightColor = _typeTint(c);
      }
      return GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UgamRadius.seat),
            border: Border.all(color: c.accent, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(child: Container(color: leftColor)),
                  Expanded(child: Container(color: rightColor)),
                ],
              ),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    cell.seatId ?? '',
                    style: UgamText.bodyStrong.copyWith(
                      color: Colors.white,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              if (mark != null)
                Positioned(
                  top: 2,
                  right: 4,
                  child: Text(
                    mark,
                    style: UgamText.micro.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 9,
                    ),
                  ),
                ),
              const Positioned(
                bottom: 2,
                left: 0,
                right: 0,
                child: Center(
                  child: Icon(
                    Icons.swap_horiz_rounded,
                    size: 10,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Color bg;
    Color border;
    Color textColor;
    if (isMine) {
      bg = c.warm;
      border = c.warm;
      textColor = c.onAccent;
    } else if (isOther) {
      bg = c.accent;
      border = c.accent;
      textColor = c.onAccent;
    } else {
      bg = _typeTint(c);
      border = _typeBorder(c);
      if (cell.seatType == SeatType.singleSofa) {
        textColor = c.good;
      } else if (cell.seatType == SeatType.doubleSofa) {
        textColor = c.accent;
      } else {
        textColor = c.ink2;
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.seat),
          border: Border.all(color: border, width: 1.5),
        ),
        child: Stack(
          children: [
            Center(
              child: Text(
                cell.seatId ?? '',
                style: UgamText.bodyStrong.copyWith(
                  color: textColor,
                  fontSize: 13,
                ),
              ),
            ),
            if (mark != null)
              Positioned(
                top: 2,
                right: 4,
                child: Text(
                  mark,
                  style: UgamText.micro.copyWith(
                    color: textColor.withValues(alpha: 0.75),
                    fontSize: 9,
                  ),
                ),
              ),
          ],
        ),
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
  final String? handlerId;
  final ValueChanged<String> onChange;
  final ValueChanged<String> onToggleHandler;

  const _PassengerCard({
    required this.tour,
    required this.passenger,
    required this.pending,
    required this.allPassengers,
    required this.handlerId,
    required this.onChange,
    required this.onToggleHandler,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selectedSeats = passenger.assignedSeats.isEmpty
        ? '—'
        : passenger.assignedSeats.map((a) => a.seatId).join(', ');
    final stillNeeded =
        pending.fold<int>(0, (sum, l) => sum + l.remaining);

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
                tooltip: handlerId == passenger.id
                    ? tr('tour_seat_assignment.tooltip_remove_handler')
                    : tr('tour_seat_assignment.tooltip_set_handler'),
                onPressed: () => onToggleHandler(passenger.id),
                icon: Icon(
                  handlerId == passenger.id
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 22,
                  color: handlerId == passenger.id ? c.warm : c.ink3,
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
                icon: Icon(
                  Icons.edit_outlined,
                  size: 20,
                  color: c.ink3,
                ),
              ),
              Text(
                '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}',
                style: UgamText.tabular(UgamText.bodyStrong.copyWith(
                  color: c.ink,
                  fontSize: 13,
                )),
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
                  tr('tour_seat_assignment.seats_label',
                      namedArgs: {'seats': selectedSeats}),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (stillNeeded > 0)
                Text(
                  tr('tour_seat_assignment.more_needed',
                      namedArgs: {'count': stillNeeded.toString()}),
                  style: UgamText.caption.copyWith(
                    color: c.warm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (handlerId == null && stillNeeded == 0) ...[
            const SizedBox(height: UgamSpacing.sm + 2),
            Container(
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
                  Icon(
                    Icons.star_outline_rounded,
                    size: 14,
                    color: c.warm,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tr('tour_seat_assignment.hint_pick_handler'),
                      style: UgamText.caption.copyWith(color: c.warm),
                    ),
                  ),
                ],
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

  const _PendingDock({
    required this.c,
    required this.pending,
    required this.activeId,
    required this.onTapPassenger,
    required this.onLockTour,
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
                          'All passengers assigned.',
                          style: UgamText.bodyStrong
                              .copyWith(color: c.ink, fontSize: 13),
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
                              borderRadius:
                                  BorderRadius.circular(UgamRadius.row),
                              border: Border.all(color: c.border),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '+$overflow',
                              style: UgamText.bodyStrong
                                  .copyWith(color: c.ink2, fontSize: 13),
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
            GestureDetector(
              onTap: onLockTour,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.lg,
                  vertical: UgamSpacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: c.good,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_rounded, size: 14, color: c.onAccent),
                    const SizedBox(width: 6),
                    Text(
                      tr('tour_seat_assignment.btn_lock_tour'),
                      style: UgamText.bodyStrong
                          .copyWith(color: c.onAccent, fontSize: 12),
                    ),
                  ],
                ),
              ),
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
    final parts =
        name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
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
        : '$remaining seat';
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
