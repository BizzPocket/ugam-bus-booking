import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import 'manage_buses_screen.dart';

/// Bottom-nav "Assign" tab — the seat-matching workbench.
///
/// Layout philosophy (Ugam rebuild):
///   1. Clean Ugam topbar — title + Fleet circle button.
///   2. Tour pills (when >1) and bus pills as horizontal scrollable rows
///      in Ugam style (solid accent active, cardElev inactive).
///   3. UgamTabPills deck toggle when an upper deck exists.
///   4. Seat chart wrapped in `UgamCard.plain` with 22 px radius. The
///      seat tiles keep their drag/drop business logic intact; only
///      colours are re-routed through `UgamColors.of(context)`.
///   5. NEW: a "Pending passengers" dock pinned above the main dock
///      nav, with horizontal cards (avatar + name + needs-chip) plus a
///      right-aligned Auto-pick circle + Done pill. Tapping a card
///      sets a highlighted-passenger state so the matching free seats
///      pulse with an accent glow inside the chart.
///
/// Sacred business logic preserved verbatim: `_handleSeatDrop`,
/// `_onSeatTap`, paired-double rules, swap/move/consolidate calls,
/// occupant dialog.
class SeatAssignmentScreen extends StatefulWidget {
  const SeatAssignmentScreen({super.key});

  @override
  State<SeatAssignmentScreen> createState() => _SeatAssignmentScreenState();
}

/// Payload carried between a long-pressed booked tile (source) and any
/// drop-target tile. Captures everything the drop handler needs to
/// validate type compatibility and to construct the right controller
/// call: which seat, who's on it, how many berths they hold there, and
/// what physical seat type they're coming from.
class _SeatDragData {
  final String seatId;
  final String passengerId;
  final String passengerName;
  final String busId;
  final SeatType? seatType;
  final int berths; // 1 for shared/single, 2 for whole-double

  /// Pair partner — non-null when the source seat is a paired Double
  /// Sofa (two different passengers, one berth each). Triggers the
  /// "move both halves together" path in _handleSeatDrop. The dragged
  /// passenger is still [passengerId]; the partner is the other half
  /// who needs to travel with them.
  final String? partnerPassengerId;

  const _SeatDragData({
    required this.seatId,
    required this.passengerId,
    required this.passengerName,
    required this.busId,
    required this.seatType,
    required this.berths,
    this.partnerPassengerId,
  });
}

class _SeatAssignmentScreenState extends State<SeatAssignmentScreen> {
  final _tourCtrl = Get.find<TourController>();

  int _tourIdx = 0;
  int _busIdx = 0;
  bool _showUpper = false;

  /// Passenger whose pending lines should make matching free seats
  /// pulse. Set from the pending dock; cleared on swipe, tap on bg,
  /// or once they're fully assigned.
  String? _highlightedPassengerId;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final tours = _tourCtrl.activeTours;
          if (tours.isEmpty) {
            return Column(
              children: [
                _TopBar(title: tr('seat_assignment.title'), c: c),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.grid_view_rounded,
                    title: tr('seat_assignment.empty.no_tours_title'),
                    body: tr('seat_assignment.empty.no_tours_body'),
                  ),
                ),
              ],
            );
          }
          if (_tourIdx >= tours.length) _tourIdx = 0;
          final tour = tours[_tourIdx];

          if (tour.buses.isEmpty) {
            return Column(
              children: [
                _TopBar(
                  title: tr('seat_assignment.title'),
                  c: c,
                  tourId: tour.id,
                ),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.directions_bus_outlined,
                    title: 'No buses yet',
                    body: 'Add a bus to this tour to see its seat chart.',
                  ),
                ),
              ],
            );
          }
          if (_busIdx >= tour.buses.length) _busIdx = 0;
          final bus = tour.buses[_busIdx];

          // Build booking lookups for the current bus.
          //
          // `occupantsBySeat[seatId]` lists one passenger id PER berth
          // held on that seat (duplicates intentional). Three cases:
          //   - []      → free seat.
          //   - [X]     → 1 berth used by X (single sofa, or one half
          //               of an otherwise-empty double).
          //   - [X, X]  → whole-double held entirely by X.
          //   - [X, Y]  → PAIRED double: two different passengers share
          //               one berth each. Drag moves on a paired double
          //               must keep the pair together — see _handleSeatDrop.
          final occupantsBySeat = <String, List<String>>{};
          final nameBySeat = <String, String>{};
          final idBySeat = <String, String>{};
          final phoneBySeat = <String, String>{};
          for (final p in tour.passengers) {
            for (final a in p.assignedSeats) {
              if (a.busId == bus.id) {
                occupantsBySeat.putIfAbsent(a.seatId, () => []).add(p.id);
                nameBySeat[a.seatId] = p.displayName;
                idBySeat[a.seatId] = p.id;
                phoneBySeat[a.seatId] = p.phone;
              }
            }
          }
          final berthsBySeat = <String, int>{
            for (final e in occupantsBySeat.entries) e.key: e.value.length,
          };

          final hasUpperDeck =
              bus.layout?.upperDeck.any((c) => c.hasSeat) ?? false;

          // Pending passengers across the whole tour — anyone who isn't
          // fully assigned and isn't waitlisted. The dock surfaces them
          // so the agent can tap → highlight matching seats.
          final pending = tour.passengers
              .where((p) => !p.isFullyAssigned && !p.isWaitlisted)
              .toList();

          // Once the highlighted passenger is fully assigned (or gone),
          // drop the highlight so the chart stops glowing.
          final highlighted = _highlightedPassengerId == null
              ? null
              : tour.passengers
                  .where((p) => p.id == _highlightedPassengerId)
                  .toList()
                  .firstOrNull;
          final glowSeatTypes = highlighted == null
              ? const <SeatType>{}
              : highlighted.requestLines.map((l) => l.seatType).toSet();

          return Column(
            children: [
              _TopBar(
                title: tr('seat_assignment.title'),
                c: c,
                tourId: tour.id,
              ),
              // Tour pills — only shown when more than one active tour.
              if (tours.length > 1) ...[
                _TourPills(
                  tours: tours,
                  selected: _tourIdx,
                  onSelect: (i) => setState(() {
                    _tourIdx = i;
                    _busIdx = 0;
                    _showUpper = false;
                    _highlightedPassengerId = null;
                  }),
                  c: c,
                ),
                const SizedBox(height: UgamSpacing.md),
              ] else
                const SizedBox(height: UgamSpacing.xs),
              _BusPills(
                buses: tour.buses,
                passengers: tour.passengers,
                selected: _busIdx,
                onSelect: (i) => setState(() {
                  _busIdx = i;
                  _showUpper = false;
                }),
                c: c,
              ),
              if (hasUpperDeck) ...[
                const SizedBox(height: UgamSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.gutter,
                  ),
                  child: UgamTabPills(
                    currentIndex: _showUpper ? 1 : 0,
                    onChanged: (i) => setState(() => _showUpper = i == 1),
                    items: [
                      UgamTabItem(
                        label: tr('seat_assignment.lower_deck'),
                        icon: Icons.event_seat_rounded,
                      ),
                      UgamTabItem(
                        label: tr('seat_assignment.upper_deck'),
                        icon: Icons.single_bed_rounded,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: UgamSpacing.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.gutter,
                  ),
                  child: _SeatChartCard(
                    layout: bus.layout,
                    showUpper: _showUpper,
                    nameBySeat: nameBySeat,
                    phoneBySeat: phoneBySeat,
                    idBySeat: idBySeat,
                    berthsBySeat: berthsBySeat,
                    occupantsBySeat: occupantsBySeat,
                    busId: bus.id,
                    glowSeatTypes: glowSeatTypes,
                    onSeatDrop: (data, targetCell) => _handleSeatDrop(
                      data: data,
                      targetCell: targetCell,
                      tour: tour,
                      busId: bus.id,
                      nameBySeat: nameBySeat,
                      idBySeat: idBySeat,
                      occupantsBySeat: occupantsBySeat,
                    ),
                    onSeatTap: (seatId) => _onSeatTap(
                      seatId: seatId,
                      tour: tour,
                      bus: bus,
                      nameBySeat: nameBySeat,
                      idBySeat: idBySeat,
                    ),
                  ),
                ),
              ),
              _PendingDock(
                c: c,
                pending: pending,
                highlightedId: _highlightedPassengerId,
                onTapPassenger: (id) {
                  setState(() {
                    _highlightedPassengerId =
                        _highlightedPassengerId == id ? null : id;
                  });
                },
                onAutoPick: pending.isEmpty
                    ? null
                    : () {
                        // Placeholder gesture — surfaces the next pending
                        // passenger and highlights their matching seats.
                        setState(() {
                          _highlightedPassengerId = pending.first.id;
                        });
                        AppSnackBar.info(
                          'Highlighted ${pending.first.displayName} — '
                          'tap a matching seat to assign.',
                          title: 'Auto-pick',
                        );
                      },
                onDone: pending.isEmpty
                    ? null
                    : () => setState(() {
                          _highlightedPassengerId = null;
                        }),
              ),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + UgamSpacing.xs,
              ),
            ],
          );
        }),
      ),
    );
  }

  /// Handle a long-press drag drop. Validation:
  ///   - Same seat → no-op.
  ///   - Cross seater↔sleeper → reject (mismatched seat class).
  ///   - Whole-double (berths == 2) dropped on a 1-berth seat → reject.
  ///   - PAIRED-DOUBLE source (data.partnerPassengerId != null):
  ///       target must be a FREE Double Sofa; moves both halves of
  ///       the pair together. Anything else → block with a snackbar
  ///       pointing the agent to break the pair from the dialog.
  ///   - Solo source, free target → moveSeat.
  ///   - Solo source, booked target → swapSeats.
  Future<void> _handleSeatDrop({
    required _SeatDragData data,
    required SeatCell targetCell,
    required Tour tour,
    required String busId,
    required Map<String, String> nameBySeat,
    required Map<String, String> idBySeat,
    required Map<String, List<String>> occupantsBySeat,
  }) async {
    final targetSeatId = targetCell.seatId;
    if (targetSeatId == null) return;
    if (targetSeatId == data.seatId) return;

    final sourceType = data.seatType;
    final targetType = targetCell.seatType;
    final sourceIsSleeper =
        sourceType == SeatType.singleSofa || sourceType == SeatType.doubleSofa;
    final targetIsSleeper =
        targetType == SeatType.singleSofa || targetType == SeatType.doubleSofa;
    final sourceIsSeater = sourceType == SeatType.seater;
    final targetIsSeater = targetType == SeatType.seater;

    if (sourceIsSleeper && targetIsSeater) {
      AppSnackBar.warning(
        "Can't move a sleeper berth onto a seater chair.",
        title: 'Mismatched seat class',
      );
      return;
    }
    if (sourceIsSeater && targetIsSleeper) {
      AppSnackBar.warning(
        "Can't move a seater passenger onto a sleeper berth.",
        title: 'Mismatched seat class',
      );
      return;
    }

    final targetCapacity = targetType == SeatType.doubleSofa ? 2 : 1;

    // ── Paired-double source ───────────────────────────────────
    // Two different passengers share the source seat. Per the pair
    // rule, they travel together — dropping one of them must move
    // BOTH onto the target. The only valid target for that is a
    // free Double Sofa; anything else breaks the pair.
    if (data.partnerPassengerId != null) {
      final targetOccupants = occupantsBySeat[targetSeatId] ?? const [];
      final targetIsFree = targetOccupants.isEmpty;
      if (targetType != SeatType.doubleSofa || !targetIsFree) {
        AppSnackBar.warning(
          'This is a paired Double Sofa — drop on a free Double Sofa '
          'to move both passengers, or break the pair from the seat '
          'dialog first.',
          title: 'Pair stays together',
        );
        return;
      }
      // Move dragger first, then partner. Each moveSeat call removes
      // their 1 berth from the source and adds 1 to the target — net
      // result: pair travels intact.
      await _tourCtrl.moveSeat(
        tourId: tour.id,
        passengerId: data.passengerId,
        busId: busId,
        fromSeatId: data.seatId,
        toSeatId: targetSeatId,
      );
      await _tourCtrl.moveSeat(
        tourId: tour.id,
        passengerId: data.partnerPassengerId!,
        busId: busId,
        fromSeatId: data.seatId,
        toSeatId: targetSeatId,
      );
      AppSnackBar.success(
        'Moved pair ${data.seatId} → $targetSeatId.',
        title: 'Pair moved',
      );
      return;
    }

    // ── Solo / whole-double source ─────────────────────────────
    if (data.berths > targetCapacity) {
      AppSnackBar.warning(
        '${data.passengerName} holds a whole double berth — '
        "they won't fit on a single sofa.",
        title: 'Seat too small',
      );
      return;
    }

    final targetOwnerId = idBySeat[targetSeatId];

    // ── Cross-fill consolidation ──────────────────────────────
    // A passenger satisfying a doubleSofa request via two singles
    // (cross-fill) gets "promoted" onto a free Double when the admin
    // drags one of those singles there. Both singles release and the
    // passenger ends up owning the whole double. Triggers only when:
    //   - source is a Single Sofa,
    //   - target is a FREE Double Sofa,
    //   - the passenger holds at least one OTHER single sofa berth on
    //     this bus (the partner that needs to release).
    // Without this, the agent has to "Free this seat" on one single by
    // hand and then re-assign — annoying enough to leave passengers
    // stuck on awkward 2-single allocations even when doubles open up.
    if (data.seatType == SeatType.singleSofa &&
        targetType == SeatType.doubleSofa &&
        targetOwnerId == null) {
      final passenger = tour.passengers
          .where((p) => p.id == data.passengerId)
          .toList()
          .firstOrNull;
      final bus = tour.buses.where((b) => b.id == busId).toList().firstOrNull;
      final layout = bus?.layout;
      String? otherSingleSeatId;
      if (passenger != null && layout != null) {
        final allCells = [...layout.lowerDeck, ...layout.upperDeck];
        for (final a in passenger.assignedSeats) {
          if (a.busId != busId) continue;
          if (a.seatId == data.seatId) continue;
          final cell = allCells
              .where((c) => c.seatId == a.seatId)
              .toList()
              .firstOrNull;
          if (cell?.seatType == SeatType.singleSofa) {
            otherSingleSeatId = a.seatId;
            break;
          }
        }
      }
      if (otherSingleSeatId != null) {
        await _tourCtrl.consolidateOntoDouble(
          tourId: tour.id,
          passengerId: data.passengerId,
          busId: busId,
          targetSeatId: targetSeatId,
          sourceSeatIds: [data.seatId, otherSingleSeatId],
        );
        AppSnackBar.success(
          'Consolidated ${data.passengerName} onto $targetSeatId — '
          '${data.seatId} + $otherSingleSeatId freed.',
          title: 'Moved onto Double',
        );
        return;
      }
      // Falls through to a plain moveSeat below — passenger ends up
      // owning HALF of the double, leaving the other half bookable.
    }

    if (targetOwnerId == null) {
      // Free target → simple move.
      await _tourCtrl.moveSeat(
        tourId: tour.id,
        passengerId: data.passengerId,
        busId: busId,
        fromSeatId: data.seatId,
        toSeatId: targetSeatId,
      );
      AppSnackBar.success(
        'Moved ${data.passengerName} from ${data.seatId} to $targetSeatId.',
        title: 'Seat moved',
      );
      return;
    }

    if (targetOwnerId == data.passengerId) {
      // Dropping onto another seat the same passenger already holds —
      // nothing meaningful to do.
      return;
    }

    final targetName = nameBySeat[targetSeatId] ?? 'passenger';
    await _tourCtrl.swapSeats(
      tourId: tour.id,
      busId: busId,
      passengerAId: data.passengerId,
      seatAId: data.seatId,
      passengerBId: targetOwnerId,
      seatBId: targetSeatId,
    );
    AppSnackBar.success(
      'Swapped ${data.seatId} (${data.passengerName}) '
      '↔ $targetSeatId ($targetName).',
      title: 'Seats swapped',
    );
  }

  /// Booked-seat → occupant dialog. Free-seat → snack-bar hint pointing
  /// to the Requests tab (which owns actual write traffic).
  void _onSeatTap({
    required String seatId,
    required Tour tour,
    required dynamic bus, // Bus from bus_details.dart, avoid extra import
    required Map<String, String> nameBySeat,
    required Map<String, String> idBySeat,
  }) {
    final passengers = tour.passengers;
    final ownerId = idBySeat[seatId];

    if (ownerId == null) {
      // Free seat — no occupant to show. Hint at the drag/drop
      // mechanic instead of the old "go to Requests tab" instruction,
      // since drag-to-move and consolidation now work right here.
      AppSnackBar.info(
        'Long-press an occupied seat and drop it here to move someone in.',
        title: 'Free seat',
      );
      return;
    }

    final occupant = passengers.firstWhere(
      (p) => p.id == ownerId,
      orElse: () => passengers.first,
    );

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => _OccupantDialog(
        occupant: occupant,
        tappedSeatId: seatId,
        busId: bus.id as String,
        busName: bus.name as String,
        tour: tour,
        onSwitchToOccupant: () {
          Navigator.of(dialogCtx).pop();
          Get.toNamed(
            '/seat-assignment',
            arguments: {'tourId': tour.id, 'passengerId': occupant.id},
          );
        },
        onCancelSeat: () async {
          Navigator.of(dialogCtx).pop();
          await _tourCtrl.cancelOneSeat(
            tourId: tour.id,
            passengerId: occupant.id,
            busId: bus.id as String,
            seatId: seatId,
          );
          AppSnackBar.success(
            'Cancelled seat $seatId for ${occupant.displayName}.',
            title: 'Seat cancelled',
          );
        },
        onFreeSeat: () async {
          Navigator.of(dialogCtx).pop();
          // Free = drop this seat from the passenger's assignedSeats
          // but keep their request_lines intact. The passenger remains
          // "outstanding" — the agent can reassign them later.
          final next = occupant.assignedSeats
              .where(
                (a) => !(a.busId == (bus.id as String) && a.seatId == seatId),
              )
              .toList();
          await _tourCtrl.assignSeats(tour.id, occupant.id, next);
          AppSnackBar.success(
            'Freed seat $seatId — ${occupant.displayName} can still be reassigned.',
            title: 'Seat freed',
          );
        },
        onUnassignAll: () async {
          Navigator.of(dialogCtx).pop();
          await _tourCtrl.assignSeats(
            tour.id,
            occupant.id,
            const <SeatAssignment>[],
          );
        },
      ),
    );
  }
}

// ─── Top bar ───────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title;
  final UgamColorSet c;
  final String? tourId;

  const _TopBar({required this.title, required this.c, this.tourId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 26),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: tourId == null
                ? null
                : () => Get.to(() => ManageBusesScreen(tourId: tourId!)),
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
                color: tourId == null ? c.ink3 : c.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tour pills ────────────────────────────────────────────────────────

class _TourPills extends StatelessWidget {
  final List<Tour> tours;
  final int selected;
  final ValueChanged<int> onSelect;
  final UgamColorSet c;

  const _TourPills({
    required this.tours,
    required this.selected,
    required this.onSelect,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
        itemCount: tours.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (ctx, i) {
          final t = tours[i];
          final active = i == selected;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: active ? c.accent : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              alignment: Alignment.center,
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.bodyStrong.copyWith(
                  color: active ? c.onAccent : c.ink,
                  fontSize: 12,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Bus pills ─────────────────────────────────────────────────────────

class _BusPills extends StatelessWidget {
  final List<dynamic> buses; // List<Bus>
  final List<Passenger> passengers;
  final int selected;
  final ValueChanged<int> onSelect;
  final UgamColorSet c;

  const _BusPills({
    required this.buses,
    required this.passengers,
    required this.selected,
    required this.onSelect,
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
          final b = buses[i];
          final busId = b.id as String;
          final assigned = passengers.fold<int>(
            0,
            (sum, p) =>
                sum + p.assignedSeats.where((a) => a.busId == busId).length,
          );
          final active = i == selected;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: active ? c.accent : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    b.name as String,
                    style: UgamText.bodyStrong.copyWith(
                      color: active ? c.onAccent : c.ink,
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
                      color: active
                          ? c.onAccent.withValues(alpha: 0.18)
                          : c.card,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Text(
                      '$assigned/${b.totalSeats}',
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: active ? c.onAccent : c.ink2,
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

// ─── Seat chart card ───────────────────────────────────────────────────

/// The rounded card containing the bus chart.
///
/// Uses [LayoutBuilder] to discover the available width, then divides
/// it among the row's logical columns so a tile always fits. Aisle
/// between left-of-aisle and right-of-aisle columns. Each tile renders
/// at the computed width — no fixed pixel sizes that could overflow.
class _SeatChartCard extends StatelessWidget {
  final BusLayout? layout;
  final bool showUpper;
  final Map<String, String> nameBySeat;
  final Map<String, String> phoneBySeat;
  final Map<String, String> idBySeat;
  final Map<String, int> berthsBySeat;
  final Map<String, List<String>> occupantsBySeat;
  final String busId;
  final Set<SeatType> glowSeatTypes;
  final ValueChanged<String> onSeatTap;
  final void Function(_SeatDragData data, SeatCell targetCell) onSeatDrop;

  const _SeatChartCard({
    required this.layout,
    required this.showUpper,
    required this.nameBySeat,
    required this.phoneBySeat,
    required this.idBySeat,
    required this.berthsBySeat,
    required this.occupantsBySeat,
    required this.busId,
    required this.glowSeatTypes,
    required this.onSeatTap,
    required this.onSeatDrop,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    if (layout == null) {
      return UgamCard.plain(
        child: Center(
          child: Text(
            tr('seat_assignment.no_layout'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
        ),
      );
    }

    final deck = showUpper ? layout!.upperDeck : layout!.lowerDeck;
    final seatCells = deck.where((c) => c.hasSeat).toList();
    if (seatCells.isEmpty) {
      return UgamCard.plain(
        child: Center(
          child: Text(
            tr('seat_assignment.no_seats_on_deck'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
        ),
      );
    }

    final maxRow = seatCells.map((c) => c.row).reduce((a, b) => a > b ? a : b);
    final cols = layout!.cols;
    final leftCols = cols ~/ 2;
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.lg,
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          const cellGap = 4.0;
          const aisleGap = 12.0;
          // Each `_SeatTile` is wrapped in a DragTarget's
          // AnimatedContainer with `Border.all(width: 2)` for the
          // drop-hover outline — that adds 4 px (2 per side) to every
          // tile's actual width on top of the `width:` passed in.
          // Subtract `cols * 4` from the budget here, otherwise the
          // Row overflows by ~cols × 4 px (~8-16 px depending on cols).
          const dragOutlinePerTile = 4.0;
          final innerWidth = constraints.maxWidth;
          final leftGapCount = math.max(0, leftCols - 1);
          final rightGapCount = math.max(0, (cols - leftCols) - 1);
          final usableWidth = innerWidth -
              aisleGap -
              (leftGapCount + rightGapCount) * cellGap -
              cols * dragOutlinePerTile;
          final cellWidth = (usableWidth / cols).clamp(0.0, 120.0);
          // Tile height = ~1.05 × width on sleeper decks so a booked tile
          // can stack seatId + name + phone comfortably. Capped at 84 so
          // a 10-row bus still fits on a single screen.
          final tileHeight = math.min(84.0, cellWidth * 1.05);

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _frontLabel(c),
                const SizedBox(height: UgamSpacing.sm),
                for (int r = 0; r <= maxRow; r++) ...[
                  _SeatRow(
                    row: r,
                    cols: cols,
                    leftCols: leftCols,
                    deck: deck,
                    cellWidth: cellWidth,
                    cellHeight: tileHeight,
                    aisleGap: aisleGap,
                    cellGap: cellGap,
                    busId: busId,
                    idBySeat: idBySeat,
                    berthsBySeat: berthsBySeat,
                    occupantsBySeat: occupantsBySeat,
                    glowSeatTypes: glowSeatTypes,
                    onSeatDrop: onSeatDrop,
                    nameBySeat: nameBySeat,
                    phoneBySeat: phoneBySeat,
                    onSeatTap: onSeatTap,
                  ),
                  if (r < maxRow) const SizedBox(height: 6),
                ],
                const SizedBox(height: UgamSpacing.sm),
                Container(height: 1, color: c.border),
                const SizedBox(height: UgamSpacing.xs),
                Text(
                  'REAR',
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _frontLabel(UgamColorSet c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(
          Icons.directions_bus_filled_rounded,
          size: 14,
          color: c.ink3,
        ),
        const SizedBox(width: 4),
        Text(
          tr('seat_assignment.driver_label'),
          style: UgamText.micro.copyWith(color: c.ink3),
        ),
      ],
    );
  }
}

// ─── Seat row ──────────────────────────────────────────────────────────

class _SeatRow extends StatelessWidget {
  final int row;
  final int cols;
  final int leftCols;
  final List<SeatCell> deck;
  final double cellWidth;
  final double cellHeight;
  final double aisleGap;
  final double cellGap;
  final Map<String, String> nameBySeat;
  final Map<String, String> phoneBySeat;
  final Map<String, String> idBySeat;
  final Map<String, int> berthsBySeat;

  /// Per-seat occupant list, one entry per berth. Used by the tile to
  /// figure out (a) how many berths the OWNER holds on the seat
  /// (1 = shared, 2 = whole-double), and (b) whether the seat is a
  /// paired double, in which case the drag-data carries the partner.
  final Map<String, List<String>> occupantsBySeat;
  final Set<SeatType> glowSeatTypes;
  final String busId;
  final ValueChanged<String> onSeatTap;
  final void Function(_SeatDragData data, SeatCell targetCell) onSeatDrop;

  const _SeatRow({
    required this.row,
    required this.cols,
    required this.leftCols,
    required this.deck,
    required this.cellWidth,
    required this.cellHeight,
    required this.aisleGap,
    required this.cellGap,
    required this.nameBySeat,
    required this.phoneBySeat,
    required this.idBySeat,
    required this.berthsBySeat,
    required this.occupantsBySeat,
    required this.glowSeatTypes,
    required this.busId,
    required this.onSeatTap,
    required this.onSeatDrop,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (int c = 0; c < cols; c++) {
      // Insert the aisle right before the first right-of-aisle column.
      if (c == leftCols && c > 0) {
        children.add(SizedBox(width: aisleGap));
      } else if (c > 0) {
        children.add(SizedBox(width: cellGap));
      }
      final cell = deck.firstWhere(
        (s) => s.row == row && s.col == c,
        orElse: () => SeatCell(row: row, col: c),
      );
      if (cell.isEmpty || cell.seatId == null) {
        children.add(SizedBox(width: cellWidth, height: cellHeight));
      } else {
        final seatId = cell.seatId!;
        final name = nameBySeat[seatId];
        final phone = phoneBySeat[seatId];
        final ownerId = idBySeat[seatId];
        final occupants = occupantsBySeat[seatId] ?? const <String>[];
        // Per-passenger berth count (NOT the seat's total occupancy).
        // Determines whether the dragger holds a whole-double or just
        // their half of a paired/shared seat.
        final ownerBerths = ownerId == null
            ? 0
            : occupants.where((id) => id == ownerId).length;
        // Pair partner: when two DIFFERENT passengers share the seat,
        // the one that isn't the displayed owner is the "partner". Used
        // by _handleSeatDrop to move both halves of a pair together.
        final distinct = occupants.toSet();
        final partnerId = (distinct.length == 2 && ownerId != null)
            ? distinct.firstWhere((id) => id != ownerId)
            : null;
        // Glow only on free seats whose physical type matches one of the
        // highlighted passenger's pending request lines.
        final glow = ownerId == null &&
            cell.seatType != null &&
            glowSeatTypes.contains(cell.seatType);
        // RepaintBoundary isolates each tile's paint surface — drag
        // hover highlights and selection ripples no longer invalidate
        // the whole chart layer.
        children.add(
          RepaintBoundary(
            child: _SeatTile(
              width: cellWidth,
              height: cellHeight,
              cell: cell,
              name: name,
              phone: phone,
              ownerId: ownerId,
              berths: ownerBerths > 0 ? ownerBerths : 1,
              partnerId: partnerId,
              busId: busId,
              glow: glow,
              onTap: () => onSeatTap(seatId),
              onDropped: (data) => onSeatDrop(data, cell),
            ),
          ),
        );
      }
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: children);
  }
}

// ─── Seat tile ─────────────────────────────────────────────────────────
//
// Every tile is a [DragTarget] (so anyone can drop onto it). Booked
// tiles are additionally wrapped in [LongPressDraggable] so the agent
// can pick up a passenger and drop them on another seat to move
// (target free) or swap (target booked).
class _SeatTile extends StatelessWidget {
  final double width;
  final double height;
  final SeatCell cell;
  final String? name;
  final String? phone;
  final String? ownerId;

  /// Berths the owner holds on this seat (NOT the seat's total
  /// occupancy). 1 for shared/single, 2 for whole-double. The drop
  /// handler uses this to validate "does this passenger fit here".
  final int berths;

  /// Pair partner — set when the seat is a paired Double Sofa (two
  /// different passengers share it). Carried in the drag payload so
  /// the drop handler can move BOTH halves of the pair together.
  final String? partnerId;

  final String busId;

  /// When true, the free tile pulses with an accent glow (signals to
  /// the agent that this seat matches the highlighted passenger's
  /// pending request type).
  final bool glow;

  final VoidCallback onTap;
  final void Function(_SeatDragData data) onDropped;

  const _SeatTile({
    required this.width,
    required this.height,
    required this.cell,
    required this.name,
    required this.phone,
    required this.ownerId,
    required this.berths,
    required this.partnerId,
    required this.busId,
    required this.glow,
    required this.onTap,
    required this.onDropped,
  });

  String get seatId => cell.seatId!;
  SeatType? get seatType => cell.seatType;

  bool get _isBooked => name != null && name!.isNotEmpty;
  bool get _isDouble => seatType == SeatType.doubleSofa;
  bool get _isSleeper =>
      seatType == SeatType.singleSofa || seatType == SeatType.doubleSofa;

  IconData get _icon {
    switch (seatType) {
      case SeatType.singleSofa:
        return Icons.single_bed_rounded;
      case SeatType.doubleSofa:
        return Icons.king_bed_rounded;
      case SeatType.seater:
        return Icons.event_seat_rounded;
      case null:
        return Icons.crop_square_rounded;
    }
  }

  /// Drop +91 / 91 prefix + any non-digits, return the local 10-digit
  /// number. Falls back to whatever's there.
  String? get _phoneDisplay {
    if (phone == null) return null;
    final digits = phone!.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    if (digits.length > 10 && digits.startsWith('91')) {
      return digits.substring(digits.length - 10);
    }
    return digits;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final Color bg;
    final Color fg;
    final Color border;

    if (_isBooked) {
      bg = c.accent;
      fg = c.onAccent;
      border = c.accent;
    } else if (_isDouble) {
      bg = c.accentFill;
      fg = c.ink;
      border = c.accent.withValues(alpha: 0.45);
    } else if (seatType == SeatType.singleSofa) {
      bg = c.goodFill;
      fg = c.ink;
      border = c.good.withValues(alpha: 0.55);
    } else {
      bg = c.cardElev;
      fg = c.ink;
      border = c.border;
    }

    Widget tile(Color drawBg, Color drawBorder, double drawBorderWidth) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: drawBg,
          borderRadius: BorderRadius.circular(UgamRadius.seat + 2),
          border: Border.all(color: drawBorder, width: drawBorderWidth),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: _isBooked ? _bookedBody(fg) : _freeBody(fg, c),
      );
    }

    // Every tile is a DragTarget — hover paints a warm outline so the
    // agent knows where they're about to drop. When `glow` is set we
    // also pulse the outline in accent to telegraph "this seat matches
    // the highlighted passenger".
    Widget content = DragTarget<_SeatDragData>(
      onWillAcceptWithDetails: (details) => details.data.seatId != seatId,
      onAcceptWithDetails: (details) => onDropped(details.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        final Color outlineColor;
        final double outlineWidth;
        if (hovering) {
          outlineColor = c.warm;
          outlineWidth = 2;
        } else if (glow) {
          outlineColor = c.accent;
          outlineWidth = 2;
        } else {
          outlineColor = Colors.transparent;
          outlineWidth = 2;
        }
        return AnimatedContainer(
          duration: UgamMotion.tapIn,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UgamRadius.seat + 4),
            border: Border.all(color: outlineColor, width: outlineWidth),
            color: glow && !hovering
                ? c.accent.withValues(alpha: 0.10)
                : Colors.transparent,
          ),
          child: tile(bg, border, _isBooked ? 0 : 1.2),
        );
      },
    );

    // Booked tiles can also be picked up. Long-press initiates the
    // drag; a tiny chip with the passenger's name + seat hovers under
    // the finger so the agent can aim.
    if (_isBooked && ownerId != null) {
      final data = _SeatDragData(
        seatId: seatId,
        passengerId: ownerId!,
        passengerName: name!,
        busId: busId,
        seatType: seatType,
        berths: berths,
        partnerPassengerId: partnerId,
      );
      content = LongPressDraggable<_SeatDragData>(
        data: data,
        delay: const Duration(milliseconds: 220),
        hapticFeedbackOnStart: true,
        feedback: _DragFeedback(passengerName: name!, seatId: seatId, c: c),
        childWhenDragging: Opacity(opacity: 0.25, child: content),
        child: content,
      );
    }

    return GestureDetector(onTap: onTap, child: content);
  }

  Widget _bookedBody(Color fg) {
    final phoneText = _phoneDisplay;
    // FittedBox(scaleDown) keeps long names + 10-digit phones readable
    // on the smallest tile size the LayoutBuilder may produce.
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              seatId,
              style: UgamText.micro.copyWith(
                color: fg.withValues(alpha: 0.75),
                fontSize: 8.5,
              ),
            ),
            Icon(_icon, size: 11, color: fg.withValues(alpha: 0.75)),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            name!,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: UgamText.bodyStrong.copyWith(
              color: fg,
              fontSize: 11,
              height: 1.1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (phoneText != null)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              phoneText,
              maxLines: 1,
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: fg.withValues(alpha: 0.85),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _freeBody(Color fg, UgamColorSet c) {
    if (_isSleeper) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Icon(_icon, size: 18, color: fg.withValues(alpha: 0.8)),
          Text(
            seatId,
            style: UgamText.bodyStrong.copyWith(
              color: fg,
              fontSize: 12,
              height: 1,
            ),
          ),
        ],
      );
    }
    return Stack(
      children: [
        Positioned(
          top: 2,
          left: 4,
          child: Icon(_icon, size: 10, color: fg.withValues(alpha: 0.7)),
        ),
        Center(
          child: Text(
            seatId,
            style: UgamText.bodyStrong.copyWith(
              color: fg,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Pending passengers dock ───────────────────────────────────────────

class _PendingDock extends StatelessWidget {
  final UgamColorSet c;
  final List<Passenger> pending;
  final String? highlightedId;
  final ValueChanged<String> onTapPassenger;
  final VoidCallback? onAutoPick;
  final VoidCallback? onDone;

  const _PendingDock({
    required this.c,
    required this.pending,
    required this.highlightedId,
    required this.onTapPassenger,
    required this.onAutoPick,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    // Cap to 8 visible cards. Anything past that is rolled into a
    // single "+N more" tile.
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
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: c.good,
                      ),
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
                          // Overflow tile.
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
                        final active = highlightedId == p.id;
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
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: onAutoPick,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: onAutoPick == null ? c.cardElev : c.accent,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: onAutoPick == null ? c.ink3 : c.onAccent,
                  ),
                ),
              ),
              const SizedBox(height: UgamSpacing.xs + 2),
              GestureDetector(
                onTap: onDone,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: onDone == null ? c.cardElev : c.goodFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    'Done',
                    style: UgamText.bodyStrong.copyWith(
                      color: onDone == null ? c.ink3 : c.good,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
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

// ─── Occupant detail dialog ────────────────────────────────────────────

/// Centred dialog shown when tapping a booked seat. Surfaces contact
/// info, every seat the passenger holds (this bus + others), their
/// request lines and note, and the destructive actions an agent
/// reaches for from this overview tab (cancel one seat, unassign all,
/// jump to the dedicated editor).
class _OccupantDialog extends StatelessWidget {
  final Passenger occupant;
  final String tappedSeatId;
  final String busId;
  final String busName;
  final Tour tour;
  final VoidCallback onSwitchToOccupant;

  /// Cancel = unassign seat + decrement matching request line. Use when
  /// the customer no longer wants this seat (booking shrinks).
  final VoidCallback onCancelSeat;

  /// Free = unassign just this seat but KEEP the request line. The
  /// passenger still wants the seat; the agent will reassign them
  /// elsewhere. Used during seat shuffling.
  final VoidCallback onFreeSeat;

  /// Unassign all = strip every seat this passenger holds on this
  /// tour. Keeps the request count (passenger is still "outstanding").
  final VoidCallback onUnassignAll;

  const _OccupantDialog({
    required this.occupant,
    required this.tappedSeatId,
    required this.busId,
    required this.busName,
    required this.tour,
    required this.onSwitchToOccupant,
    required this.onCancelSeat,
    required this.onFreeSeat,
    required this.onUnassignAll,
  });

  String get _initials {
    final name = occupant.displayName.trim();
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

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final seatsOnThisBus = occupant.assignedSeats
        .where((a) => a.busId == busId)
        .map((a) => a.seatId)
        .toList();
    final seatsElsewhere = occupant.assignedSeats
        .where((a) => a.busId != busId)
        .toList();
    final requestLines = occupant.requestLines
        .map((l) => l.label)
        .where((l) => l.isNotEmpty)
        .toList();

    final maxHeight = MediaQuery.of(context).size.height * 0.9;

    return Dialog(
      backgroundColor: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: c.ink2,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        _initials,
                        style: UgamText.titleM.copyWith(
                          color: c.onAccent,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            occupant.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: UgamText.titleM.copyWith(
                              color: c.ink,
                              fontSize: 17,
                            ),
                          ),
                          if (occupant.phone.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              occupant.phone,
                              style: UgamText.body.copyWith(color: c.ink2),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Quick-call CTA. Hides itself when the passenger
                    // record has no phone. Tapping launches the system
                    // dialer pre-filled.
                    if (occupant.phone.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      _CallButton(phone: occupant.phone, c: c),
                    ],
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.input),
                    border: Border.all(
                      color: c.accent.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.event_seat_rounded,
                        size: 18,
                        color: c.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Seat $tappedSeatId',
                              style: UgamText.titleM.copyWith(
                                color: c.accent,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '$busName · ${tour.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: UgamText.caption.copyWith(
                                color: c.accent.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _sectionLabel('SEATS ON THIS BUS', c),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: seatsOnThisBus.isEmpty
                      ? [
                          Text(
                            'No seats on $busName.',
                            style: UgamText.caption.copyWith(color: c.ink2),
                          ),
                        ]
                      : seatsOnThisBus
                          .map(
                            (id) => _seatBadge(
                              id,
                              c: c,
                              highlight: id == tappedSeatId,
                            ),
                          )
                          .toList(),
                ),
                if (seatsElsewhere.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('OTHER BUSES', c),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: seatsElsewhere.map((a) {
                      final otherBus = tour.buses
                          .where((b) => b.id == a.busId)
                          .toList()
                          .firstOrNull;
                      final label = otherBus != null
                          ? '${otherBus.name} · ${a.seatId}'
                          : a.seatId;
                      return _seatBadge(label, c: c, highlight: false);
                    }).toList(),
                  ),
                ],
                if (requestLines.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('REQUESTED', c),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: requestLines
                        .map(
                          (line) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: c.cardElev,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              line,
                              style: UgamText.caption.copyWith(
                                color: c.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (occupant.note != null && occupant.note!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('NOTE', c),
                  const SizedBox(height: 8),
                  Text(
                    occupant.note!,
                    style: UgamText.body.copyWith(color: c.ink2),
                  ),
                ],
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: onSwitchToOccupant,
                    icon: const Icon(Icons.person_pin_rounded, size: 18),
                    label: Text(
                      'Switch to ${occupant.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UgamText.titleS.copyWith(
                        color: c.onAccent,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onFreeSeat,
                    icon: const Icon(Icons.event_seat_outlined, size: 16),
                    label: const Text(
                      'Free this seat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.accent,
                      side: BorderSide(
                        color: c.accent.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onCancelSeat,
                        icon: const Icon(Icons.event_busy_rounded, size: 16),
                        label: const Text(
                          'Cancel seat',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.danger,
                          side: BorderSide(
                            color: c.danger.withValues(alpha: 0.5),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    if (occupant.assignedSeats.length > 1) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onUnassignAll,
                          icon: const Icon(Icons.clear_all_rounded, size: 16),
                          label: const Text(
                            'Unassign all',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: c.danger,
                            side: BorderSide(
                              color: c.danger.withValues(alpha: 0.5),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String label, UgamColorSet c) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink2));
  }

  Widget _seatBadge(String id, {required UgamColorSet c, required bool highlight}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight ? c.warm : c.accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        id,
        style: UgamText.bodyStrong.copyWith(
          color: c.onAccent,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Circular accent-tinted "call" pill.
class _CallButton extends StatelessWidget {
  final String phone;
  final UgamColorSet c;
  const _CallButton({required this.phone, required this.c});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Call $phone',
      child: InkResponse(
        onTap: () => PhoneDialer.call(phone),
        radius: 24,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.accentFill,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.phone_rounded,
            size: 18,
            color: c.accent,
          ),
        ),
      ),
    );
  }
}

// ─── Drag feedback ─────────────────────────────────────────────────────
//
// Compact floating chip that hovers under the finger during a
// long-press drag. Shows the dragged passenger's name + source seat
// so the agent can aim accurately. Wrapped in Material because the
// drag overlay renders outside the normal widget tree and needs its
// own typography context.
class _DragFeedback extends StatelessWidget {
  final String passengerName;
  final String seatId;
  final UgamColorSet c;

  const _DragFeedback({
    required this.passengerName,
    required this.seatId,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.warm,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              offset: Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              seatId,
              style: UgamText.micro.copyWith(
                color: c.onAccent.withValues(alpha: 0.85),
                fontSize: 9,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              passengerName,
              style: UgamText.bodyStrong.copyWith(
                color: c.onAccent,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
