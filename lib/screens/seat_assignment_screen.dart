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
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import 'manage_buses_screen.dart';

/// Bottom-nav "Assign" tab — the seat-matching workbench.
class SeatAssignmentScreen extends StatefulWidget {
  const SeatAssignmentScreen({super.key});

  @override
  State<SeatAssignmentScreen> createState() => _SeatAssignmentScreenState();
}

/// Payload carried between a long-pressed booked tile (source) and any
/// drop-target tile.
class _SeatDragData {
  final String seatId;
  final String passengerId;
  final String passengerName;
  final String busId;
  final SeatType? seatType;
  final int berths; // 1 for shared/single, 2 for whole-double
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

          final assignedSeatCount = occupantsBySeat.length;

          return Column(
            children: [
              _TopBar(
                title: tr('seat_assignment.title'),
                c: c,
                tourId: tour.id,
                onClearSeats: assignedSeatCount == 0
                    ? null
                    : () => _confirmClearBus(tour, bus, assignedSeatCount),
              ),
              // Tour pills — only shown when more than one active tour.
              if (tours.length > 1) ...[
                _TourPills(
                  tours: tours,
                  selected: _tourIdx,
                  onSelect: (i) => setState(() {
                    _tourIdx = i;
                    _busIdx = 0;
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
                }),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.gutter,
                  ),
                  child: _SeatChartCard(
                    layout: bus.layout,
                    tour: tour,
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
              ),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + UgamSpacing.lg,
              ),
            ],
          );
        }),
      ),
    );
  }

  /// Confirm + unassign every seat on the currently-selected bus. Passengers
  /// keep their requests, so they drop straight back into the "to assign" pool.
  Future<void> _confirmClearBus(Tour tour, Bus bus, int seatCount) async {
    final c = UgamColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.card,
        title: Text(tr('seat_assignment.clear_bus.title')),
        content: Text(
          tr('seat_assignment.clear_bus.body', namedArgs: {
            'count': '$seatCount',
            'bus': bus.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('seat_assignment.clear_bus.confirm')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _tourCtrl.unassignBus(tour.id, bus.id);
      AppSnackBar.success(
        tr('seat_assignment.clear_bus.done', namedArgs: {'bus': bus.name}),
      );
    } catch (_) {
      // unassignBus already surfaced the error.
    }
  }

  /// Handle a long-press drag drop. Validation:
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
        final allCells = layout.grid;
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

  void _onSeatTap({
    required String seatId,
    required Tour tour,
    required dynamic bus,
    required Map<String, String> nameBySeat,
    required Map<String, String> idBySeat,
  }) {
    final passengers = tour.passengers;
    final ownerId = idBySeat[seatId];

    if (ownerId == null) {
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

  /// When non-null, shows a "clear seats" action that unassigns every seat on
  /// the currently-selected bus. Null hides the action (e.g. nothing assigned).
  final VoidCallback? onClearSeats;

  const _TopBar({
    required this.title,
    required this.c,
    this.tourId,
    this.onClearSeats,
  });

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
          if (onClearSeats != null) ...[
            GestureDetector(
              onTap: onClearSeats,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.danger.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.layers_clear_rounded,
                  size: 19,
                  color: c.danger,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
          ],
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
  final List<dynamic> buses;
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

class _SeatChartCard extends StatelessWidget {
  final BusLayout? layout;
  final Map<String, String> nameBySeat;
  final Map<String, String> phoneBySeat;
  final Map<String, String> idBySeat;
  final Map<String, int> berthsBySeat;
  final Map<String, List<String>> occupantsBySeat;
  final String busId;
  final Tour tour;
  final ValueChanged<String> onSeatTap;
  final void Function(_SeatDragData data, SeatCell targetCell) onSeatDrop;

  const _SeatChartCard({
    required this.layout,
    required this.nameBySeat,
    required this.phoneBySeat,
    required this.idBySeat,
    required this.berthsBySeat,
    required this.occupantsBySeat,
    required this.busId,
    required this.tour,
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

    const double tileW = 62;
    const double tileH = 78;

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.lg,
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: CombinedSeatGrid(
          layout: layout!,
          cellWidth: tileW,
          cellHeight: tileH,
          colGap: 4,
          rowGap: 6,
          driverLabel: tr('seat_assignment.driver_label'),
          tileBuilder: (ctx, cell) {
            final seatId = cell.seatId;
            final occupants = seatId != null
                ? (occupantsBySeat[seatId] ?? const <String>[])
                : const <String>[];
            return RepaintBoundary(
              child: _SeatTile(
                width: tileW,
                height: tileH,
                cell: cell,
                tour: tour,
                occupantIds: occupants,
                busId: busId,
                onTap: () {
                  if (seatId != null) onSeatTap(seatId);
                },
                onDropped: (data) => onSeatDrop(data, cell),
              ),
            );
          },
        ),
      ),
    );
  }

}

// ─── Seat tile ─────────────────────────────────────────────────────────

class _SeatTile extends StatelessWidget {
  final double width;
  final double height;
  final SeatCell cell;
  final Tour tour;
  final List<String> occupantIds;
  final String busId;
  final VoidCallback onTap;
  final void Function(_SeatDragData data) onDropped;

  const _SeatTile({
    required this.width,
    required this.height,
    required this.cell,
    required this.tour,
    required this.occupantIds,
    required this.busId,
    required this.onTap,
    required this.onDropped,
  });

  String get seatId => cell.seatId!;
  SeatType? get seatType => cell.seatType;

  bool get _isBooked => occupantIds.isNotEmpty;
  bool get _isSleeper =>
      seatType == SeatType.singleSofa || seatType == SeatType.doubleSofa;

  String? get name {
    if (occupantIds.isEmpty) return null;
    final p = tour.passengers.where((x) => x.id == occupantIds.first).toList().firstOrNull;
    return p?.displayName;
  }

  String? get phone {
    if (occupantIds.isEmpty) return null;
    final p = tour.passengers.where((x) => x.id == occupantIds.first).toList().firstOrNull;
    return p?.phone;
  }

  String? get ownerId => occupantIds.isEmpty ? null : occupantIds.first;

  int get berths => occupantIds.length;

  String? get partnerId {
    final distinct = occupantIds.toSet().toList();
    if (distinct.length == 2) {
      return distinct[1];
    }
    return null;
  }

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

  String? get _phoneDisplay {
    if (phone == null) return null;
    final digits = phone!.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    if (digits.length > 10 && digits.startsWith('91')) {
      return digits.substring(digits.length - 10);
    }
    return digits;
  }

  String getInitials(String displayName) {
    final n = displayName.trim();
    if (n.isEmpty) return '?';
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // ── Shared/split Double Sofa rendering ──────────────────────────────────
    final distinct = occupantIds.toSet().toList();
    if (seatType == SeatType.doubleSofa && distinct.length == 2) {
      final occA = tour.passengers.where((p) => p.id == distinct[0]).toList().firstOrNull;
      final occB = tour.passengers.where((p) => p.id == distinct[1]).toList().firstOrNull;
      final initA = occA != null ? getInitials(occA.displayName) : '?';
      final initB = occB != null ? getInitials(occB.displayName) : '?';

      Widget content = DragTarget<_SeatDragData>(
        onWillAcceptWithDetails: (details) => details.data.seatId != seatId,
        onAcceptWithDetails: (details) => onDropped(details.data),
        builder: (context, candidate, _) {
          final hovering = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: UgamMotion.tapIn,
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(UgamRadius.seat + 2),
              border: Border.all(
                color: hovering ? c.warm : c.accent,
                width: hovering ? 2 : 1.2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        color: c.accent,
                        alignment: Alignment.center,
                        child: Text(
                          initA,
                          style: UgamText.bodyStrong.copyWith(
                            color: c.onAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        color: c.accent,
                        alignment: Alignment.center,
                        child: Text(
                          initB,
                          style: UgamText.bodyStrong.copyWith(
                            color: c.onAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      seatId,
                      style: UgamText.bodyStrong.copyWith(
                        color: Colors.white,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );

      if (occA != null) {
        final data = _SeatDragData(
          seatId: seatId,
          passengerId: occA.id,
          passengerName: occA.displayName,
          busId: busId,
          seatType: seatType,
          berths: 1,
          partnerPassengerId: occB?.id,
        );
        content = LongPressDraggable<_SeatDragData>(
          data: data,
          delay: const Duration(milliseconds: 220),
          hapticFeedbackOnStart: true,
          feedback: _DragFeedback(passengerName: occA.displayName, seatId: seatId, c: c),
          childWhenDragging: Opacity(opacity: 0.25, child: content),
          child: content,
        );
      }

      return GestureDetector(onTap: onTap, child: content);
    }

    // ── Half-booked Double Sofa rendering ───────────────────────────────
    if (seatType == SeatType.doubleSofa && occupantIds.length == 1) {
      final occ = tour.passengers.where((p) => p.id == occupantIds.first).toList().firstOrNull;
      final initials = occ != null ? getInitials(occ.displayName) : '?';

      Widget content = DragTarget<_SeatDragData>(
        onWillAcceptWithDetails: (details) => details.data.seatId != seatId,
        onAcceptWithDetails: (details) => onDropped(details.data),
        builder: (context, candidate, _) {
          final hovering = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: UgamMotion.tapIn,
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(UgamRadius.seat + 2),
              border: Border.all(
                color: hovering ? c.warm : c.accent.withValues(alpha: 0.45),
                width: hovering ? 2 : 1.2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        color: c.accent,
                        alignment: Alignment.center,
                        child: Text(
                          initials,
                          style: UgamText.bodyStrong.copyWith(
                            color: c.onAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        color: c.accentFill,
                        alignment: Alignment.center,
                        child: Icon(
                          _icon,
                          size: 14,
                          color: c.accent.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      seatId,
                      style: UgamText.bodyStrong.copyWith(
                        color: Colors.white,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );

      if (occ != null) {
        final data = _SeatDragData(
          seatId: seatId,
          passengerId: occ.id,
          passengerName: occ.displayName,
          busId: busId,
          seatType: seatType,
          berths: 1,
          partnerPassengerId: null,
        );
        content = LongPressDraggable<_SeatDragData>(
          data: data,
          delay: const Duration(milliseconds: 220),
          hapticFeedbackOnStart: true,
          feedback: _DragFeedback(passengerName: occ.displayName, seatId: seatId, c: c),
          childWhenDragging: Opacity(opacity: 0.25, child: content),
          child: content,
        );
      }

      return GestureDetector(onTap: onTap, child: content);
    }

    // ── Standard Tile rendering (Free or Fully Booked) ───────────────────
    final Color bg;
    final Color fg;
    final Color border;

    if (_isBooked) {
      if (seatType == SeatType.doubleSofa) {
        bg = c.accent;
        fg = c.onAccent;
        border = c.accent;
      } else if (seatType == SeatType.singleSofa) {
        bg = c.good;
        fg = c.onAccent;
        border = c.good;
      } else {
        bg = c.border;
        fg = c.ink;
        border = c.border;
      }
    } else {
      if (seatType == SeatType.doubleSofa) {
        bg = c.accentFill;
        fg = c.accent;
        border = c.accent.withValues(alpha: 0.35);
      } else if (seatType == SeatType.singleSofa) {
        bg = c.goodFill;
        fg = c.good;
        border = c.good.withValues(alpha: 0.45);
      } else {
        bg = c.cardElev;
        fg = c.ink2;
        border = c.border;
      }
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

    Widget content = DragTarget<_SeatDragData>(
      onWillAcceptWithDetails: (details) => details.data.seatId != seatId,
      onAcceptWithDetails: (details) => onDropped(details.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        final Color outlineColor = hovering ? c.warm : Colors.transparent;
        return AnimatedContainer(
          duration: UgamMotion.tapIn,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UgamRadius.seat + 4),
            border: Border.all(color: outlineColor, width: 2),
            color: Colors.transparent,
          ),
          child: tile(bg, border, _isBooked ? 0 : 1.2),
        );
      },
    );

    if (_isBooked && ownerId != null && name != null) {
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

// ─── Occupant detail dialog ────────────────────────────────────────────

/// Centred dialog shown when tapping a booked seat.
class _OccupantDialog extends StatelessWidget {
  final Passenger occupant;
  final String tappedSeatId;
  final String busId;
  final String busName;
  final Tour tour;
  final VoidCallback onSwitchToOccupant;
  final VoidCallback onCancelSeat;
  final VoidCallback onFreeSeat;
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
