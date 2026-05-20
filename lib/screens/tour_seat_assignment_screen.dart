import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../config/theme.dart';
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

/// Tour-scoped seat assignment. Mirrors the Pencil "Seat Assignment" screen:
/// bus tabs, deck tabs, visual seat grid, and a bottom card for the current
/// passenger being assigned.
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
  bool _showUpperDeck = false;
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
  /// handy. Re-computes the slice for one bus; cheap because it
  /// short-circuits on the busId filter.
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
  ///
  /// Each entry in `assignedSeats` represents one "berth". On regular
  /// seats (single / seater) that's always the whole seat. On a
  /// doubleSofa cell a passenger may hold 1 berth (half — the other half
  /// is free, or shared with someone else) or 2 berths (the whole
  /// double, owned solo).
  ///
  /// Consumption rules, per cell the passenger has any berth on:
  ///   - singleSofa / seater: decrement that type's line per berth.
  ///   - doubleSofa, 2 berths held solo: decrement 1 `doubleSofa` line
  ///     if available, otherwise 2 `singleSofa` lines (covers the
  ///     "10-singles requested, only 6 singles in bus + 2 doubles"
  ///     fill-from-doubles flow).
  ///   - doubleSofa, 1 berth (half — empty other half OR shared):
  ///     decrement 1 `singleSofa` line if available, fallback to 1
  ///     `doubleSofa` line.
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
    // half-doubles) drain ONE doubleSofa line. This is the "bus is
    // short on whole doubles, fill the customer's double request with
    // two singles instead" flow. We pass null cellPos so we only match
    // doubleSofa lines that don't specify a position — customer-form
    // requests don't set one.
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
    for (final c in layout.lowerDeck) {
      if (c.seatId == seatId) return c;
    }
    for (final c in layout.upperDeck) {
      if (c.seatId == seatId) return c;
    }
    return null;
  }

  /// How many berths to claim when this passenger taps an unoccupied
  /// cell. Returns 0 when the cell's type doesn't match anything pending.
  ///
  /// Berth model recap: one entry in `assignedSeats` = one berth. A
  /// whole Double Sofa is TWO entries with the same seatId; sharing a
  /// double is ONE entry per occupant. `_pendingLines`,
  /// `TourController.moveSeat`, and `swapSeats` all consume/preserve
  /// this count, so this helper has to agree with them.
  ///
  /// Special case for a `doubleSofa`:
  ///   - 2 if a `doubleSofa` request line is pending → passenger takes
  ///     the WHOLE double. Two berth-entries are added; the other half
  ///     is no longer bookable by anyone else. (Previously this branch
  ///     returned 1, which silently halved every double assignment and
  ///     left the partner-slot open for accidental shares — that's the
  ///     bug the user reported.)
  ///   - 2 if no `doubleSofa` line but ≥ 2 `singleSofa` lines remain
  ///     (the "10 singles requested, fill the rest from doubles" flow:
  ///     two singles fold into one whole double).
  ///   - 1 if exactly 1 `singleSofa` line remains — the passenger
  ///     intentionally takes half, leaving the other half open for a
  ///     later share.
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
      // First preference: an exact singleSofa line.
      final hasSingleLine = pending.any((l) =>
          l.seatType == SeatType.singleSofa &&
          positionOk(l) &&
          l.remaining > 0);
      if (hasSingleLine) return 1;
      // Cross-fill: passenger requested a Double Sofa but the bus is
      // short on doubles. Each single sofa we assign covers HALF of a
      // pending doubleSofa line; once they have two, _pendingLines'
      // pair-up pass drains the line. Returning 1 here lets the agent
      // tap a single while honouring the doubleSofa request.
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
      // Passenger is done — surface the milestone clearly.
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
        // Everyone's done and a handler is picked — the Lock Tour CTA
        // is now active. Nudge the agent toward it.
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
      // Mid-passenger: brief, low-noise confirmation so the agent knows
      // the tap was saved (the seat turning amber is also a visual cue).
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
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        // The header doesn't depend on any reactive state (title is a
        // static `tr` key, tourId comes from widget config) — hoist it
        // above the Obx so realtime tour updates don't repaint it. It
        // also keeps the back button + Fleet link visible across the
        // tour-not-found / no-buses / no-passengers empty states.
        child: Column(
          children: [
            _Header(
              title: tr('tour_seat_assignment.title'),
              tourId: widget.tourId,
            ),
            Expanded(
              child: Obx(() {
        final tour = _tour;
        if (tour == null) {
          return Center(child: Text(tr('tour_seat_assignment.tour_not_found')));
        }
        if (tour.buses.isEmpty) {
          return _NoBuses(tourId: widget.tourId);
        }
        if (tour.passengers.isEmpty) {
          return _NoPassengers();
        }

          final bus = _selectedBus(tour)!;
          final passenger = _selectedPassenger(tour);
          // One pass over all passengers builds the lookup for every
          // bus at once; we slice it instead of re-walking the
          // passengers list per pill + per active bus.
          final assignmentsByBus = _assignmentsByBus(tour);
          final assignmentMap =
              assignmentsByBus[bus.id] ?? const <String, List<String>>{};

          final hasUpper = bus.layout?.upperDeck.any((c) => c.hasSeat) ?? false;
          return Column(
            children: [
              // Single inline strip: horizontally scrolling bus tabs +
              // (when present) a compact deck toggle on the right. Replaces
              // the old subtitle / bus header / standalone deck tab stack
              // that ate ~150-200px before the grid even rendered.
              _BusStrip(
                buses: tour.buses,
                selectedBusId: bus.id,
                seatsAssignedFor: (id) => _occupants(
                    assignmentsByBus[id] ?? const <String, List<String>>{}),
                onTapBus: (id) {
                  setState(() {
                    _selectedBusId = id;
                    _showUpperDeck = false;
                  });
                },
                hasUpper: hasUpper,
                showUpperDeck: _showUpperDeck,
                onDeckChanged: (v) => setState(() => _showUpperDeck = v),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  physics: const BouncingScrollPhysics(),
                  child: _SeatGrid(
                    layout: bus.layout,
                    showUpper: _showUpperDeck,
                    assignmentMap: assignmentMap,
                    currentPassengerId: passenger?.id,
                    onTap: (cell) => _onSeatTapped(cell, bus, tour),
                  ),
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
                  onLockTour: tour.status == TourStatus.assigning &&
                          tour.allSeatsAssigned &&
                          tour.handlerId != null
                      ? () => _lockTour(tour)
                      : null,
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

class _Header extends StatelessWidget {
  final String title;
  final String tourId;
  const _Header({required this.title, required this.tourId});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.md,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 42,
              height: 42,
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
              style: UgamText.titleL.copyWith(color: c.ink, fontSize: 19),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: () =>
                Get.to(() => ManageBusesScreen(tourId: tourId)),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Text(
                tr('tour_seat_assignment.fleet_link'),
                style: UgamText.bodyStrong
                    .copyWith(color: c.accent, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact top strip on the assignment screen. Combines:
///   - horizontally-scrolling bus tabs (one chip per bus, showing
///     name + seats-sold)
///   - an inline deck toggle on the right when the selected bus has
///     an upper deck
///
/// Replaces the previous _Subtitle + _BusTabs + _BusHeader + _DeckTabs
/// stack which ate ~150-200px of vertical space before the seat grid
/// even rendered. Driver name was sacrificed (it lives in the Fleet
/// screen) so this band fits in a single 48-px row.
class _BusStrip extends StatelessWidget {
  final List<Bus> buses;
  final String selectedBusId;
  final int Function(String) seatsAssignedFor;
  final ValueChanged<String> onTapBus;
  final bool hasUpper;
  final bool showUpperDeck;
  final ValueChanged<bool> onDeckChanged;

  const _BusStrip({
    required this.buses,
    required this.selectedBusId,
    required this.seatsAssignedFor,
    required this.onTapBus,
    required this.hasUpper,
    required this.showUpperDeck,
    required this.onDeckChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: buses.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final bus = buses[i];
                  final selected = bus.id == selectedBusId;
                  final assigned = seatsAssignedFor(bus.id);
                  final capacity = bus.totalSeats;
                  return GestureDetector(
                    onTap: () => onTapBus(bus.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected ? AppTheme.brand : AppColors.surface(ctx),
                        borderRadius: BorderRadius.circular(9999),
                        border: Border.all(
                          color: selected
                              ? AppTheme.brand
                              : AppColors.border(ctx),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            bus.name,
                            style: AppText.chipTextActive.copyWith(
                              color: selected
                                  ? Colors.white
                                  : AppColors.text(ctx),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '$assigned/$capacity',
                            style: AppText.cardMeta.copyWith(
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? Colors.white.withValues(alpha: 0.85)
                                  : AppColors.textMuted(ctx),
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
          if (hasUpper) ...[
            const SizedBox(width: 10),
            _DeckToggle(
              showUpper: showUpperDeck,
              onChanged: onDeckChanged,
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact two-state pill: "L" / "U" deck toggle. Lives on the right
/// edge of `_BusStrip` only when the current bus has an upper deck.
class _DeckToggle extends StatelessWidget {
  final bool showUpper;
  final ValueChanged<bool> onChanged;
  const _DeckToggle({required this.showUpper, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget half(String label, bool isUpper) {
      final active = isUpper == showUpper;
      return GestureDetector(
        onTap: () => onChanged(isUpper),
        child: Container(
          width: 30,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Text(
            label,
            style: AppText.buttonInline.copyWith(
              color: active ? Colors.white : AppColors.textMuted(context),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [half('L', false), half('U', true)],
      ),
    );
  }
}


class _SeatGrid extends StatelessWidget {
  final BusLayout? layout;
  final bool showUpper;
  final Map<String, List<String>> assignmentMap;
  final String? currentPassengerId;
  final ValueChanged<SeatCell> onTap;

  const _SeatGrid({
    required this.layout,
    required this.showUpper,
    required this.assignmentMap,
    required this.currentPassengerId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null) {
      return _NoLayout();
    }
    final cells = showUpper ? l.upperDeck : l.lowerDeck;
    final seatCellsForCheck = cells.where((c) => c.hasSeat).toList();
    if (seatCellsForCheck.isEmpty) {
      return _NoLayout();
    }

    // Lay seats out by their actual (row, col) instead of packing
    // sequentially, so a layout with empty grid cells (e.g. the col-1
    // aisle in 2x1 sleeper buses, or single-on-left / double-on-right
    // splits) renders the way it was generated. Previously the GridView
    // dropped empty slots, collapsing the new lane-based layout back
    // into a flat grid.
    final cols = l.cols;
    var maxRow = 0;
    for (final c in seatCellsForCheck) {
      if (c.row > maxRow) maxRow = c.row;
    }
    final slots = List<SeatCell?>.filled((maxRow + 1) * cols, null);
    for (final c in seatCellsForCheck) {
      final idx = c.row * cols + c.col;
      if (idx >= 0 && idx < slots.length) {
        slots[idx] = c;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(
              Icons.person_outline_rounded,
              size: 14,
              color: AppColors.textMuted(context),
            ),
            const SizedBox(width: 4),
            Text(
              showUpper
                  ? tr('tour_seat_assignment.grid_label_upper')
                  : tr('tour_seat_assignment.grid_label_driver'),
              style: AppText.badgeSm.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: AppColors.textMuted(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.1,
            ),
            itemCount: slots.length,
            itemBuilder: (ctx, i) {
              final cell = slots[i];
              if (cell == null) {
                // Empty slot — aisle / gap. Keep the cell footprint so
                // the surrounding seats stay aligned in their lanes.
                return const SizedBox.shrink();
              }
              final owners = assignmentMap[cell.seatId] ?? const <String>[];
              // Count this passenger's berths separately from others' so
              // a whole-double-held-solo (2 of MY entries on the same
              // cell) reads as `mineCount=2, otherCount=0` and not as a
              // share.
              final mineCount = currentPassengerId == null
                  ? 0
                  : owners.where((id) => id == currentPassengerId).length;
              final otherCount = owners.length - mineCount;
              // RepaintBoundary isolates each tile's repaint from its
              // neighbours — selecting a passenger changes amber/blue
              // tints on a handful of tiles, but without this boundary
              // the whole grid layer is invalidated every tap.
              return RepaintBoundary(
                child: _SeatTile(
                  cell: cell,
                  mineCount: mineCount,
                  otherCount: otherCount,
                  onTap: () => onTap(cell),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SeatTile extends StatelessWidget {
  final SeatCell cell;
  /// Berths the currently-selected passenger holds on this cell.
  /// 0 = none, 1 = half (the other half is free or shared), 2 = whole
  /// double held solo.
  final int mineCount;
  /// Berths held by OTHER passengers — i.e. everyone except the one
  /// currently selected at the bottom of the screen.
  final int otherCount;
  final VoidCallback onTap;

  const _SeatTile({
    required this.cell,
    required this.mineCount,
    required this.otherCount,
    required this.onTap,
  });

  bool get isMine => mineCount > 0;

  /// True iff this cell needs the split-rendering path. Three cases on a
  /// doubleSofa:
  ///   - mineCount == 1 && otherCount == 1: shared (amber | brand)
  ///   - mineCount == 1 && otherCount == 0: half-mine (amber | free tint)
  ///   - mineCount == 0 && otherCount == 1: half-other (brand | free tint)
  /// Whole-owned (count == 2 on one side) renders as a solid tile, not
  /// a split — both berths belong to the same passenger.
  bool get _needsSplit {
    if (cell.seatType != SeatType.doubleSofa) return false;
    final total = mineCount + otherCount;
    if (total == 0 || total >= 2 && (mineCount == 2 || otherCount == 2)) {
      return false;
    }
    return true;
  }

  /// 1-letter mark for the seat type (S = Single Sofa, D = Double Sofa,
  /// T = Seater). Shown in the corner so the agent can read the bus
  /// at a glance.
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

  Color get _typeTint {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return const Color(0xFFE7F8EE); // pale green
      case SeatType.doubleSofa:
        return const Color(0xFFE0F2FE); // pale blue
      case SeatType.seater:
        return const Color(0xFFF1F5F9); // pale grey
      case null:
        return Colors.white;
    }
  }

  Color _typeBorder(BuildContext context) {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return const Color(0xFF22C55E);
      case SeatType.doubleSofa:
        return const Color(0xFF0EA5E9);
      case SeatType.seater:
        return AppColors.textMuted(context);
      case null:
        return AppColors.border(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOther = otherCount > 0;
    final mark = _typeMark;

    // Partial doubleSofa: render two side-by-side halves so the agent
    // can see at a glance which berths are taken vs free. Cases:
    //   - mine=1, other=1: shared (amber | brand)
    //   - mine=1, other=0: half-mine, other half free (amber | tint)
    //   - mine=0, other=1: half-other, other half free (brand | tint)
    if (_needsSplit) {
      final Color leftColor;
      final Color rightColor;
      if (isMine && otherCount > 0) {
        leftColor = AppTheme.brandAccent; // self
        rightColor = AppTheme.brand;      // co-owner
      } else if (isMine) {
        leftColor = AppTheme.brandAccent; // self half
        rightColor = _typeTint;           // free half — agent can still claim it
      } else {
        leftColor = AppTheme.brand;       // other half
        rightColor = _typeTint;           // free half
      }
      return GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.brand, width: 1.5),
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
              // Seat label sits in a small dark chip so it stays legible
              // regardless of whether the half behind it is filled
              // (amber/brand) or free (tint).
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    cell.seatId ?? '',
                    style: AppText.cardMeta.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
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
                    style: AppText.badgeSm.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
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
      bg = AppTheme.brandAccent;
      border = AppTheme.brandAccent;
      textColor = Colors.white;
    } else if (isOther) {
      bg = AppTheme.brand;
      border = AppTheme.brand;
      textColor = Colors.white;
    } else {
      bg = _typeTint;
      border = _typeBorder(context);
      textColor = AppColors.text(context);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: 1.5),
        ),
        child: Stack(
          children: [
            Center(
              child: Text(
                cell.seatId ?? '',
                style: TextStyle(fontFamily: 'Inter', 
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
            if (mark != null)
              Positioned(
                top: 2,
                right: 4,
                child: Text(
                  mark,
                  style: AppText.badgeSm.copyWith(
                    color: textColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PassengerCard extends StatelessWidget {
  final Tour tour;
  final Passenger passenger;
  final List<_PendingLine> pending;
  final List<Passenger> allPassengers;
  final String? handlerId;
  final ValueChanged<String> onChange;
  final ValueChanged<String> onToggleHandler;
  final VoidCallback? onLockTour;

  const _PassengerCard({
    required this.tour,
    required this.passenger,
    required this.pending,
    required this.allPassengers,
    required this.handlerId,
    required this.onChange,
    required this.onToggleHandler,
    required this.onLockTour,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedSeats = passenger.assignedSeats.isEmpty
        ? '—'
        : passenger.assignedSeats.map((a) => a.seatId).join(', ');
    final stillNeeded =
        pending.fold<int>(0, (sum, l) => sum + l.remaining);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        border: Border(top: BorderSide(color: AppColors.border(context))),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Passenger picker (horizontal chips).
          SizedBox(
            height: 30,
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
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? AppTheme.brand : AppColors.bg(ctx),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected
                            ? AppTheme.brand
                            : AppColors.border(ctx),
                      ),
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
                              color:
                                  selected ? Colors.white : AppTheme.success,
                            ),
                          ),
                        Text(
                          p.displayName,
                          style: AppText.cardMeta.copyWith(
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : AppColors.text(ctx),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppTheme.brandLight,
                child: Text(
                  passenger.name.isNotEmpty
                      ? passenger.name[0].toUpperCase()
                      : '?',
                  style: AppText.buttonInline.copyWith(color: AppTheme.brand),
                ),
              ),
              const SizedBox(width: 10),
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
                            style: AppText.cardTitleSm.copyWith(
                              fontSize: 14,
                              color: theme.colorScheme.onSurface,
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
                              color:
                                  AppTheme.brandAccent.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              tr('tour_seat_assignment.badge_handler'),
                              style: TextStyle(fontFamily: 'Inter', 
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: AppTheme.brandAccent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (passenger.phone.isNotEmpty)
                      Text(
                        passenger.phone,
                        style: AppText.cardMeta.copyWith(
                          color: AppColors.textMuted(context),
                        ),
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
                  color: handlerId == passenger.id
                      ? AppTheme.brandAccent
                      : AppColors.textMuted(context),
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
                  color: AppColors.textMuted(context),
                ),
              ),
              Text(
                '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}',
                style: AppText.chipTextActive.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
                  color: AppColors.bg(context),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${line.label}  ${line.progress}',
                  style: AppText.cardLabel.copyWith(
                    fontWeight: FontWeight.w600,
                    color: line.remaining == 0
                        ? AppTheme.success
                        : AppColors.text(context),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('tour_seat_assignment.seats_label',
                      namedArgs: {'seats': selectedSeats}),
                  style: TextStyle(fontFamily: 'Inter', 
                    fontSize: 12,
                    color: AppColors.textMuted(context),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (stillNeeded > 0)
                Text(
                  tr('tour_seat_assignment.more_needed',
                      namedArgs: {'count': stillNeeded.toString()}),
                  style: TextStyle(fontFamily: 'Inter', 
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.warning,
                  ),
                ),
            ],
          ),
          if (handlerId == null && stillNeeded == 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: AppTheme.warningLight,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.star_outline_rounded,
                    size: 14,
                    color: AppTheme.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tr('tour_seat_assignment.hint_pick_handler'),
                      style: TextStyle(fontFamily: 'Inter', 
                        fontSize: 11,
                        color: AppTheme.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (onLockTour != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: onLockTour,
                icon: const Icon(Icons.lock_rounded, size: 16),
                label: Text(tr('tour_seat_assignment.btn_lock_tour')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoBuses extends StatelessWidget {
  final String tourId;
  const _NoBuses({required this.tourId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.directions_bus_outlined,
              size: 56,
              color: AppColors.textMuted(context),
            ),
            const SizedBox(height: 14),
            Text(
              tr('tour_seat_assignment.no_buses_title'),
              style: TextStyle(fontFamily: 'Inter', 
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('tour_seat_assignment.no_buses_body'),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Inter', 
                fontSize: 12,
                color: AppColors.textMuted(context),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => Get.to(
                () => ManageBusesScreen(tourId: tourId),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('tour_seat_assignment.btn_add_bus')),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPassengers extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline_rounded,
              size: 56,
              color: AppColors.textMuted(context),
            ),
            const SizedBox(height: 14),
            Text(
              tr('tour_seat_assignment.no_passengers_title'),
              style: TextStyle(fontFamily: 'Inter', 
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('tour_seat_assignment.no_passengers_body'),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Inter', 
                fontSize: 12,
                color: AppColors.textMuted(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoLayout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      alignment: Alignment.center,
      child: Text(
        tr('tour_seat_assignment.no_layout'),
        textAlign: TextAlign.center,
        style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: AppColors.textMuted(context)),
      ),
    );
  }
}
