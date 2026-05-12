import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

/// Bottom-nav "Assign" tab — read-only overview of seat allocations.
///
/// Layout philosophy:
///   1. Compact header (tour title + bus picker chips + deck toggle).
///   2. The chart itself fills every remaining vertical pixel.
///   3. Tile widths are computed from the available width via
///      [LayoutBuilder], so the row ALWAYS fits the screen — no
///      horizontal scroll, no pinch zoom, no clipped columns.
///   4. Each booked tile renders the FULL passenger name + FULL local
///      phone, scaled to fit the tile via [FittedBox].
///   5. Tapping a booked seat opens a centred occupant dialog with
///      contact info and admin actions (cancel one seat / unassign all
///      / jump to that passenger in the dedicated editor).
///   6. The dedicated TourSeatAssignmentScreen owns actual writes — this
///      tab only does ad-hoc fixes through the dialog.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          final tours = _tourCtrl.activeTours;
          if (tours.isEmpty) {
            return _emptyState(
              icon: Icons.grid_view_rounded,
              title: tr('seat_assignment.empty.no_tours_title'),
              body: tr('seat_assignment.empty.no_tours_body'),
            );
          }
          if (_tourIdx >= tours.length) _tourIdx = 0;
          final tour = tours[_tourIdx];

          if (tour.buses.isEmpty) {
            return _emptyState(
              icon: Icons.directions_bus_outlined,
              title: 'No buses yet',
              body: 'Add a bus to this tour to see its seat chart.',
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

          final assigned = nameBySeat.length;
          final total = bus.totalSeats;
          final pct = total > 0 ? (assigned * 100 ~/ total) : 0;
          final hasUpperDeck =
              bus.layout?.upperDeck.any((c) => c.hasSeat) ?? false;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              children: [
                const SizedBox(height: 10),
                _Header(tourTitle: tour.title),
                const SizedBox(height: 10),
                _BusChipStrip(
                  buses: tour.buses,
                  passengers: tour.passengers,
                  selected: _busIdx,
                  onSelect: (i) => setState(() {
                    _busIdx = i;
                    _showUpper = false;
                  }),
                ),
                const SizedBox(height: 10),
                if (hasUpperDeck) ...[
                  _DeckToggle(
                    showUpper: _showUpper,
                    onChange: (v) => setState(() => _showUpper = v),
                  ),
                  const SizedBox(height: 10),
                ],
                Expanded(
                  child: _SeatChartCard(
                    layout: bus.layout,
                    showUpper: _showUpper,
                    nameBySeat: nameBySeat,
                    phoneBySeat: phoneBySeat,
                    idBySeat: idBySeat,
                    berthsBySeat: berthsBySeat,
                    occupantsBySeat: occupantsBySeat,
                    busId: bus.id,
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
                _ChartStatusBar(
                  busLabel: '${bus.name}'
                      '${bus.busNumber.isNotEmpty ? ' · ${bus.busNumber}' : ''}',
                  assigned: assigned,
                  total: total,
                  pct: pct,
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String body,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
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
    final sourceIsSleeper = sourceType == SeatType.singleSofa ||
        sourceType == SeatType.doubleSofa;
    final targetIsSleeper = targetType == SeatType.singleSofa ||
        targetType == SeatType.doubleSofa;
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
          Get.toNamed('/seat-assignment', arguments: {
            'tourId': tour.id,
            'passengerId': occupant.id,
          });
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
              .where((a) =>
                  !(a.busId == (bus.id as String) && a.seatId == seatId))
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

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String tourTitle;
  const _Header({required this.tourTitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          tr('seat_assignment.title'),
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            tourTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Bus chip strip ────────────────────────────────────────────────────

class _BusChipStrip extends StatelessWidget {
  final List<dynamic> buses; // List<Bus>
  final List<Passenger> passengers;
  final int selected;
  final ValueChanged<int> onSelect;

  const _BusChipStrip({
    required this.buses,
    required this.passengers,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: buses.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final b = buses[i];
          final busId = b.id as String;
          final assigned = passengers.fold<int>(
            0,
            (sum, p) =>
                sum + p.assignedSeats.where((a) => a.busId == busId).length,
          );
          final isActive = i == selected;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isActive ? AppTheme.brand : cs.surface,
                borderRadius: BorderRadius.circular(12),
                border: isActive
                    ? null
                    : Border.all(color: AppColors.border(context)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    b.name as String,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                      color: isActive ? Colors.white : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$assigned/${b.totalSeats} · '
                    '${b.isAC ? tr('seat_assignment.ac') : tr('seat_assignment.non_ac')}',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: isActive
                          ? Colors.white.withValues(alpha: 0.85)
                          : cs.onSurfaceVariant,
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

// ─── Deck toggle ───────────────────────────────────────────────────────

class _DeckToggle extends StatelessWidget {
  final bool showUpper;
  final ValueChanged<bool> onChange;

  const _DeckToggle({required this.showUpper, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _seg(label: tr('seat_assignment.lower_deck'), active: !showUpper, onTap: () => onChange(false)),
          _seg(label: tr('seat_assignment.upper_deck'), active: showUpper, onTap: () => onChange(true)),
        ],
      ),
    );
  }

  Widget _seg({required String label, required bool active, required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: active ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : AppTheme.brand,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Seat chart card ───────────────────────────────────────────────────

/// The white rounded card containing the bus chart.
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
    required this.onSeatTap,
    required this.onSeatDrop,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (layout == null) {
      return _card(
        cs, context,
        child: Center(
          child: Text(
            tr('seat_assignment.no_layout'),
            style: GoogleFonts.inter(
              fontSize: 14,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final deck = showUpper ? layout!.upperDeck : layout!.lowerDeck;
    final seatCells = deck.where((c) => c.hasSeat).toList();
    if (seatCells.isEmpty) {
      return _card(
        cs, context,
        child: Center(
          child: Text(
            tr('seat_assignment.no_seats_on_deck'),
            style: GoogleFonts.inter(
              fontSize: 13,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final maxRow =
        seatCells.map((c) => c.row).reduce((a, b) => a > b ? a : b);
    final cols = layout!.cols;
    final leftCols = cols ~/ 2;
    // Logical row width = cols cells separated by inter-cell gaps with
    // an aisle in the middle. We compute tile width from the LayoutBuilder
    // constraints below so the whole row sums to the chart width.
    return _card(
      cs, context,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          const horizontalPadding = 10.0;
          const cellGap = 4.0;
          const aisleGap = 12.0;
          // Sub the chart padding + gaps + aisle from the available width
          // to get the total width that's actually used by seat tiles.
          // cols tiles, (leftCols - 1) gaps on the left half,
          // 1 aisle, (cols - leftCols - 1) gaps on the right half.
          final innerWidth = constraints.maxWidth - 2 * horizontalPadding;
          final leftGapCount = math.max(0, leftCols - 1);
          final rightGapCount = math.max(0, (cols - leftCols) - 1);
          final usableWidth = innerWidth -
              aisleGap -
              (leftGapCount + rightGapCount) * cellGap;
          final cellWidth = (usableWidth / cols).clamp(36.0, 120.0);
          // Tile height = ~1.05 × width on sleeper decks so a booked tile
          // can stack seatId + name + phone comfortably. Capped at 84 so
          // a 10-row bus still fits on a single screen.
          final tileHeight = math.min(84.0, cellWidth * 1.05);

          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: 14,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Front-of-bus driver indicator.
                  _front(cs, cellWidth: cellWidth),
                  const SizedBox(height: 10),
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
                      onSeatDrop: onSeatDrop,
                      nameBySeat: nameBySeat,
                      phoneBySeat: phoneBySeat,
                      onSeatTap: onSeatTap,
                    ),
                    if (r < maxRow) const SizedBox(height: 6),
                  ],
                  const SizedBox(height: 10),
                  Divider(height: 1, color: AppColors.border(context)),
                  const SizedBox(height: 4),
                  Text(
                    'REAR',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                      color: cs.onSurfaceVariant,
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

  Widget _card(ColorScheme cs, BuildContext context, {required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: child,
    );
  }

  /// Front-of-bus row: steering-wheel icon on the right (driver side).
  Widget _front(ColorScheme cs, {required double cellWidth}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(
          Icons.directions_bus_filled_rounded,
          size: 16,
          color: cs.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          tr('seat_assignment.driver_label'),
          style: GoogleFonts.inter(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
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
        // RepaintBoundary isolates each tile's paint surface — drag
        // hover highlights and selection ripples no longer invalidate
        // the whole chart layer.
        children.add(RepaintBoundary(
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
            onTap: () => onSeatTap(seatId),
            onDropped: (data) => onSeatDrop(data, cell),
          ),
        ));
      }
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: children,
    );
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
    final Color bg;
    final Color fg;
    final Color border;

    if (_isBooked) {
      bg = AppTheme.brand;
      fg = Colors.white;
      border = AppTheme.brand;
    } else if (_isDouble) {
      bg = const Color(0xFFE0F2FE); // pale blue
      fg = AppColors.text(context);
      border = const Color(0xFF0EA5E9);
    } else if (seatType == SeatType.singleSofa) {
      bg = const Color(0xFFE7F8EE); // pale green
      fg = AppColors.text(context);
      border = const Color(0xFF22C55E);
    } else {
      bg = const Color(0xFFF1F5F9);
      fg = AppColors.text(context);
      border = AppColors.border(context);
    }

    Widget tile(Color drawBg, Color drawBorder, double drawBorderWidth) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: drawBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: drawBorder, width: drawBorderWidth),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: _isBooked ? _bookedBody(fg) : _freeBody(fg),
      );
    }

    // Every tile is a DragTarget — hover paints an amber outline so the
    // agent knows where they're about to drop.
    Widget content = DragTarget<_SeatDragData>(
      onWillAcceptWithDetails: (details) =>
          details.data.seatId != seatId,
      onAcceptWithDetails: (details) => onDropped(details.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hovering ? AppTheme.brandAccent : Colors.transparent,
              width: 2,
            ),
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
        feedback: _DragFeedback(
          passengerName: name!,
          seatId: seatId,
        ),
        childWhenDragging: Opacity(opacity: 0.25, child: content),
        child: content,
      );
    }

    return GestureDetector(onTap: onTap, child: content);
  }

  Widget _bookedBody(Color fg) {
    final phoneText = _phoneDisplay;
    // FittedBox(scaleDown) keeps long names + 10-digit phones readable
    // on the smallest tile size the LayoutBuilder may produce (~36 px
    // wide on tiny phones with many cols).
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              seatId,
              style: GoogleFonts.inter(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: fg.withValues(alpha: 0.75),
                height: 1,
                letterSpacing: 0.4,
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
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: fg,
              height: 1.1,
            ),
          ),
        ),
        if (phoneText != null)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              phoneText,
              maxLines: 1,
              style: GoogleFonts.inter(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: fg.withValues(alpha: 0.85),
                height: 1,
                letterSpacing: 0.2,
              ),
            ),
          ),
      ],
    );
  }

  Widget _freeBody(Color fg) {
    if (_isSleeper) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Icon(_icon, size: 18, color: fg.withValues(alpha: 0.8)),
          Text(
            seatId,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
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
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Status bar ────────────────────────────────────────────────────────

class _ChartStatusBar extends StatelessWidget {
  final String busLabel;
  final int assigned;
  final int total;
  final int pct;

  const _ChartStatusBar({
    required this.busLabel,
    required this.assigned,
    required this.total,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final free = (total - assigned).clamp(0, total);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  busLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$assigned assigned · $free free · $pct% full',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _swatch(cs, context, color: AppTheme.brand, label: 'Booked'),
          const SizedBox(width: 6),
          _swatch(
            cs, context,
            color: Colors.white,
            borderColor: AppColors.border(context),
            label: 'Free',
          ),
        ],
      ),
    );
  }

  Widget _swatch(
    ColorScheme cs,
    BuildContext context, {
    required Color color,
    Color? borderColor,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
            border: borderColor != null ? Border.all(color: borderColor) : null,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
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
    final parts =
        name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final seatsOnThisBus = occupant.assignedSeats
        .where((a) => a.busId == busId)
        .map((a) => a.seatId)
        .toList();
    final seatsElsewhere =
        occupant.assignedSeats.where((a) => a.busId != busId).toList();
    final requestLines = occupant.requestLines
        .map((l) => l.label)
        .where((l) => l.isNotEmpty)
        .toList();

    final maxHeight = MediaQuery.of(context).size.height * 0.9;

    return Dialog(
      backgroundColor: AppColors.surface(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: cs.onSurfaceVariant),
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
                      decoration: const BoxDecoration(
                        color: AppTheme.brand,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        _initials,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
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
                            style: GoogleFonts.inter(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          if (occupant.phone.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              occupant.phone,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Quick-call CTA. Hides itself when the passenger
                    // record has no phone (anon imports, manual entries
                    // without a number). Tapping launches the system
                    // dialer pre-filled — agent confirms + presses
                    // call, so this is a read-only handoff.
                    if (occupant.phone.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      _CallButton(phone: occupant.phone),
                    ],
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.brandLight,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppTheme.brand.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event_seat_rounded,
                          size: 18, color: AppTheme.brand),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Seat $tappedSeatId',
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.brandDark,
                              ),
                            ),
                            Text(
                              '$busName · ${tour.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: AppTheme.brandDark
                                    .withValues(alpha: 0.75),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _sectionLabel('SEATS ON THIS BUS', cs),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: seatsOnThisBus.isEmpty
                      ? [
                          Text(
                            'No seats on $busName.',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          )
                        ]
                      : seatsOnThisBus
                          .map((id) =>
                              _seatBadge(id, highlight: id == tappedSeatId))
                          .toList(),
                ),
                if (seatsElsewhere.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('OTHER BUSES', cs),
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
                      return _seatBadge(label, highlight: false);
                    }).toList(),
                  ),
                ],
                if (requestLines.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('REQUESTED', cs),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: requestLines
                        .map((line) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                line,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
                if (occupant.note != null && occupant.note!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('NOTE', cs),
                  const SizedBox(height: 8),
                  Text(
                    occupant.note!,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                      height: 1.4,
                    ),
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
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Free this seat (single, full-width) — keep the
                // passenger's request line, just drop them off this
                // specific seat. Most common ad-hoc fix during
                // shuffling.
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
                      foregroundColor: AppTheme.brand,
                      side: BorderSide(
                          color: AppTheme.brand.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Cancel (this seat) + Unassign all — both destructive,
                // both reduce the passenger's footprint on the tour.
                // Cancel ALSO trims their request line so the booking
                // shrinks; Unassign all just clears their seats.
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
                          foregroundColor: AppTheme.danger,
                          side: BorderSide(
                              color:
                                  AppTheme.danger.withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
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
                            foregroundColor: AppTheme.danger,
                            side: BorderSide(
                                color:
                                    AppTheme.danger.withValues(alpha: 0.5)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
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

  Widget _sectionLabel(String label, ColorScheme cs) {
    return Text(
      label,
      style: GoogleFonts.inter(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  Widget _seatBadge(String id, {required bool highlight}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight ? AppTheme.brandAccent : AppTheme.brand,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        id,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Circular brand-tinted "call" pill. Used in the occupant dialog and
/// re-exported via the shared phone-dialer util so future surfaces can
/// drop it in the same way.
class _CallButton extends StatelessWidget {
  final String phone;
  const _CallButton({required this.phone});

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
          decoration: const BoxDecoration(
            color: AppTheme.brandLight,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.phone_rounded,
            size: 18,
            color: AppTheme.brand,
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

  const _DragFeedback({
    required this.passengerName,
    required this.seatId,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.brandAccent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              offset: const Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              seatId,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.85),
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              passengerName,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
