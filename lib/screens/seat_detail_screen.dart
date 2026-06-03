import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

/// SLICE 3a of the smart-seat UI: the per-bus seat-detail screen.
///
/// Renders ONE bus of a tour as a single [CombinedSeatGrid] (the shared
/// 5-column placement engine) with a clean, purpose-built tile look:
///
///   * FREE seat   — dashed ink3 hairline, transparent fill, a faint seat
///     glyph + the seat id.
///   * RESERVED    — dimmed card fill, a struck-through lock glyph and a
///     "Held" label; never shows an occupant (the engine never auto-fills
///     reserved seats).
///   * BOOKED      — occupant initials centred on a card/cardElev fill. A
///     deterministic colour RING when the occupant has a [Passenger.groupId]
///     (so a glance reads who travels together). A WARM ring + badge when the
///     occupant [Passenger.isPriorityApproved] OR the cell is [SeatCell.forward]
///     (the premium/priority forward zone).
///   * SHARED double — two unrelated passengers on one `doubleSofa` seatId:
///     the tile is split left/right with each occupant's initials.
///
/// Tapping a booked seat opens a bottom sheet (UgamRadius.sheet) with the
/// occupant's name, phone, a Call button, the requested-lines summary, a
/// group/priority indicator, and a "Free seat" action wired to the existing
/// [TourController.cancelOneSeat]. Move/Swap is a later slice — only READ +
/// Free is exposed here.
///
/// All colour comes from [UgamColors.of] — nothing hardcoded — and the
/// screen is dark-first per the locked design DNA. The chart is reactive:
/// an Obx on the controller's `tours` repaints whenever an assignment
/// changes (e.g. after Free seat).
class SeatDetailScreen extends StatelessWidget {
  final String tourId;
  final String busId;

  const SeatDetailScreen({
    super.key,
    required this.tourId,
    required this.busId,
  });

  TourController get _ctrl => Get.find<TourController>();

  /// Build a seatId → occupants map for [bus]. A `doubleSofa` cell may hold
  /// up to two DISTINCT passengers when the agent split the sofa between
  /// unrelated singles; every other seat holds at most one.
  ///
  /// Occupants are de-duplicated per passenger per seat: a WHOLE double is one
  /// passenger holding TWO `SeatAssignment` entries on the SAME seatId (see
  /// [TourController.consolidateOntoDouble]). Without de-duping it would read
  /// as a SHARED split tile with the same person on both halves and open a
  /// bogus chooser. After de-duping a whole double yields `[p]` (length 1 →
  /// booked tile) and a genuine shared double yields two distinct passengers
  /// (length 2 → split tile + chooser).
  static Map<String, List<Passenger>> _occupantsBySeat(
    dynamic tour,
    Bus bus,
  ) {
    final out = <String, List<Passenger>>{};
    for (final p in (tour.passengers as List<Passenger>)) {
      for (final a in p.assignedSeats) {
        if (a.busId == bus.id) {
          final list = out[a.seatId] ??= <Passenger>[];
          if (!list.any((x) => x.id == p.id)) list.add(p);
        }
      }
    }
    return out;
  }

  /// Count every booked berth on [bus] from the RAW assignment entries — a
  /// whole double contributes 2 berths even though it resolves to one
  /// occupant tile, so this must NOT be derived from the de-duped occupant
  /// map (that would undercount whole doubles as 1).
  static int _assignedBerths(dynamic tour, Bus bus) {
    var n = 0;
    for (final p in (tour.passengers as List<Passenger>)) {
      for (final a in p.assignedSeats) {
        if (a.busId == bus.id) n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final tour = _ctrl.getTour(tourId);
          final bus = tour?.buses.firstWhereOrNull((b) => b.id == busId);
          if (tour == null || bus == null) {
            return Column(
              children: [
                _Header(title: 'Seat detail', subtitle: null, c: c),
                Expanded(
                  child: Center(
                    child: Text(
                      'Bus not found.',
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  ),
                ),
              ],
            );
          }

          final layout = bus.layout;
          final occupants = _occupantsBySeat(tour, bus);
          final total = layout?.totalSeats ?? 0;
          // Count raw berths (a whole double = 2 berths, one tile) so the
          // subtitle never undercounts consolidated doubles.
          final assigned = _assignedBerths(tour, bus);

          return Column(
            children: [
              _Header(
                title: bus.name,
                subtitle: '$assigned/$total assigned',
                c: c,
              ),
              Expanded(
                child: layout == null || layout.totalCells == 0
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(UgamSpacing.huge),
                          child: Text(
                            'This bus has no seat layout yet.',
                            textAlign: TextAlign.center,
                            style: UgamText.body.copyWith(color: c.ink2),
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.gutter,
                        ),
                        child: UgamCard.plain(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.md,
                            vertical: UgamSpacing.lg,
                          ),
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: CombinedSeatGrid(
                              layout: layout,
                              cellWidth: _tileW,
                              cellHeight: _tileH,
                              colGap: 6,
                              rowGap: 6,
                              tileBuilder: (ctx, cell) {
                                final seatOccupants = cell.seatId != null
                                    ? (occupants[cell.seatId] ??
                                        const <Passenger>[])
                                    : const <Passenger>[];
                                return RepaintBoundary(
                                  child: _SeatTile(
                                    cell: cell,
                                    occupants: seatOccupants,
                                    onTapBooked: () => _showOccupantSheet(
                                      ctx,
                                      cell: cell,
                                      occupants: seatOccupants,
                                      bus: bus,
                                      tourTitle: tour.title,
                                    ),
                                    onTapFree: () =>
                                        _showFreeSheet(ctx, cell, bus),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Legend(c: c),
              const SizedBox(height: UgamSpacing.md),
            ],
          );
        }),
      ),
    );
  }

  // ── Sheets ────────────────────────────────────────────────────────────

  /// Booked-seat bottom sheet: occupant name + phone + Call, requested
  /// lines, a group/priority indicator, and a "Free seat" action. A shared
  /// double surfaces a per-occupant chooser first, then opens this sheet for
  /// the chosen occupant.
  void _showOccupantSheet(
    BuildContext context, {
    required SeatCell cell,
    required List<Passenger> occupants,
    required Bus bus,
    required String tourTitle,
  }) {
    if (occupants.isEmpty) return;

    void open(Passenger occupant) {
      final c = UgamColors.of(context);
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: c.card,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(UgamRadius.sheet)),
        ),
        builder: (sheetCtx) => _OccupantSheet(
          occupant: occupant,
          cell: cell,
          bus: bus,
          tourTitle: tourTitle,
          isShared: occupants.length > 1,
          onFreeSeat: () async {
            Navigator.of(sheetCtx).pop();
            await _ctrl.cancelOneSeat(
              tourId: tourId,
              passengerId: occupant.id,
              busId: bus.id,
              seatId: cell.seatId!,
            );
          },
          // TODO(seat-ui): move/swap actions land in a later slice. Leave a
          // visible placeholder so the affordance has a home in the layout.
          onMove: null,
          onSwap: null,
        ),
      );
    }

    // Shared double → let the agent pick which of the two berth-holders to act
    // on before opening the detail sheet.
    if (occupants.length > 1) {
      final c = UgamColors.of(context);
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: c.card,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(UgamRadius.sheet)),
        ),
        builder: (sheetCtx) => _SharedChooserSheet(
          occupants: occupants,
          seatId: cell.seatId!,
          onPick: (p) {
            Navigator.of(sheetCtx).pop();
            open(p);
          },
        ),
      );
      return;
    }

    open(occupants.first);
  }

  /// Free-seat tap → a brief info sheet. No assignment happens here yet.
  void _showFreeSheet(BuildContext context, SeatCell cell, Bus bus) {
    final c = UgamColors.of(context);
    final held = cell.reserved;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(UgamRadius.sheet)),
      ),
      builder: (_) => Padding(
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
            const _SheetGrabber(),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: held ? c.cardElev : c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.input),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    held ? Icons.lock_outline_rounded : Icons.event_seat_rounded,
                    size: 18,
                    color: held ? c.ink3 : c.accent,
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        held
                            ? 'Seat ${cell.seatId} is held'
                            : 'Seat ${cell.seatId} is free',
                        style: UgamText.titleM.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        held
                            ? 'Reserved by you — the auto-fill skips it.'
                            : '${cell.typeLabel} · ${bus.name}',
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
            Text(
              held
                  ? 'Free this seat from the seat-assignment workbench to open '
                      'it up for booking.'
                  : 'Open the seat-assignment workbench to place a passenger '
                      'here.',
              style: UgamText.body.copyWith(color: c.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

// Tile sizing — a touch larger than the read-only chart so initials read
// cleanly. The grid FittedBox scales the whole chart down to fit width.
const double _tileW = 60;
const double _tileH = 60;

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final UgamColorSet c;

  const _Header({required this.title, required this.subtitle, required this.c});

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title.isEmpty ? 'Seat detail' : title,
                  style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink2),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Group colour palette ──────────────────────────────────────────────

/// Six pleasant hues that read well as a thin ring on the near-black dark
/// ground. A passenger's [Passenger.groupId] is hashed into this list so the
/// same group always draws the same colour within a session.
class _GroupPalette {
  const _GroupPalette._();

  // All six hues deliberately avoid the 25-45 deg warm-amber band (so a group
  // ring can never be mistaken for the `warm` priority ring) and the
  // low-saturation brown accent band. The former "peach" Color(0xFFFFB86B)
  // (H~31 deg) collided with `warm` and was swapped for a cool violet.
  static const List<Color> hues = [
    Color(0xFF6AA9FF), // sky blue
    Color(0xFF8E7BFF), // periwinkle
    Color(0xFF4FD1C5), // teal
    Color(0xFFF6A5C0), // rose
    Color(0xFFB892FF), // violet (was peach — warm-band collision)
    Color(0xFF9AE6B4), // mint
  ];

  static Color colorFor(String groupId) {
    final idx = groupId.hashCode.abs() % hues.length;
    return hues[idx];
  }
}

// ─── Seat tile ─────────────────────────────────────────────────────────

/// A single clean seat tile. Draws its own look (no DragTarget / Draggable —
/// those gestures belong to the assignment workbench) and shares only the
/// grid's placement. States: free / held (reserved) / booked / shared-double.
class _SeatTile extends StatelessWidget {
  final SeatCell cell;
  final List<Passenger> occupants;
  final VoidCallback onTapBooked;
  final VoidCallback onTapFree;

  const _SeatTile({
    required this.cell,
    required this.occupants,
    required this.onTapBooked,
    required this.onTapFree,
  });

  bool get _isBooked => occupants.isNotEmpty;
  bool get _isShared => occupants.length > 1;

  static String initials(String displayName) {
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

    if (_isShared) {
      return GestureDetector(
        onTap: onTapBooked,
        behavior: HitTestBehavior.opaque,
        child: _sharedTile(c),
      );
    }
    if (_isBooked) {
      return GestureDetector(
        onTap: onTapBooked,
        behavior: HitTestBehavior.opaque,
        child: _bookedTile(c, occupants.first),
      );
    }
    if (cell.reserved) {
      return GestureDetector(
        onTap: onTapFree,
        behavior: HitTestBehavior.opaque,
        child: _heldTile(c),
      );
    }
    return GestureDetector(
      onTap: onTapFree,
      behavior: HitTestBehavior.opaque,
      child: _freeTile(c),
    );
  }

  // FREE — dashed ink3 hairline, transparent fill, faint glyph + seat id.
  Widget _freeTile(UgamColorSet c) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: c.ink3.withValues(alpha: 0.55),
        radius: UgamRadius.seat,
      ),
      child: SizedBox(
        width: _tileW,
        height: _tileH,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_seat_outlined, size: 16, color: c.ink3),
            const SizedBox(height: 3),
            Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 9.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // RESERVED — dimmed fill, struck lock glyph, "Held" label.
  Widget _heldTile(UgamColorSet c) {
    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        color: c.cardElev.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: c.ink3),
          const SizedBox(height: 3),
          Text(
            'Held',
            style: UgamText.micro.copyWith(
              color: c.ink3,
              decoration: TextDecoration.lineThrough,
              decorationColor: c.ink3,
            ),
          ),
        ],
      ),
    );
  }

  // BOOKED — initials on card fill; group ring + warm priority ring/badge.
  Widget _bookedTile(UgamColorSet c, Passenger p) {
    final priority = p.isPriorityApproved || cell.forward;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? _GroupPalette.colorFor(p.groupId!) : null;

    // The outer ring colour signals belonging. Priority (warm) is attention,
    // so it always wins the ring; a group then shows as a small dot badge.
    final Color ringColor;
    final double ringWidth;
    if (priority) {
      ringColor = c.warm;
      ringWidth = 2;
    } else if (groupColor != null) {
      ringColor = groupColor;
      ringWidth = 2;
    } else {
      ringColor = c.border;
      ringWidth = 1;
    }

    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: ringColor, width: ringWidth),
      ),
      child: Stack(
        children: [
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                initials(p.displayName),
                style: UgamText.bodyStrong.copyWith(
                  color: c.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          // Seat id, top-left.
          Positioned(
            top: 4,
            left: 5,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(
                  color: c.ink3,
                  fontSize: 8,
                ),
              ),
            ),
          ),
          // Priority warm badge, top-right.
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(
                Icons.star_rounded,
                size: 12,
                color: c.warm,
              ),
            ),
          // Group dot badge (only when not already the ring colour, i.e. a
          // priority booking that ALSO belongs to a group).
          if (priority && groupColor != null)
            Positioned(
              bottom: 4,
              right: 4,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: groupColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // SHARED double — split left/right, both initials.
  Widget _sharedTile(UgamColorSet c) {
    final a = occupants[0];
    final b = occupants[1];
    final priority = a.isPriorityApproved || b.isPriorityApproved || cell.forward;
    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(
          color: priority ? c.warm : c.border,
          width: priority ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(child: _half(c, a)),
              Container(width: 1, color: c.border),
              Expanded(child: _half(c, b)),
            ],
          ),
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                cell.seatId ?? '',
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
                ),
              ),
            ),
          ),
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            ),
        ],
      ),
    );
  }

  Widget _half(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? _GroupPalette.colorFor(p.groupId!) : null;
    return Container(
      color: c.cardElev,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              initials(p.displayName),
              style: UgamText.bodyStrong.copyWith(
                color: c.ink,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (groupColor != null) ...[
            const SizedBox(height: 3),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: groupColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Paints a dashed rounded-rectangle border for the FREE tile. Kept local so
/// the free look stays distinct from the solid-bordered booked/held tiles.
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 4.0;
    const gap = 3.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

// ─── Legend ────────────────────────────────────────────────────────────

class _Legend extends StatelessWidget {
  final UgamColorSet c;
  const _Legend({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Wrap(
        spacing: UgamSpacing.md,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          _LegendItem(swatch: _LegendSwatch.dashed, label: 'Free', c: c),
          _LegendItem(swatch: _LegendSwatch.filled, label: 'Booked', c: c),
          _LegendItem(
            swatch: _LegendSwatch.warmRing,
            label: 'Priority / forward',
            c: c,
          ),
          _LegendItem(swatch: _LegendSwatch.held, label: 'Held', c: c),
        ],
      ),
    );
  }
}

enum _LegendSwatch { dashed, filled, warmRing, held }

class _LegendItem extends StatelessWidget {
  final _LegendSwatch swatch;
  final String label;
  final UgamColorSet c;

  const _LegendItem({
    required this.swatch,
    required this.label,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    Widget dot;
    switch (swatch) {
      case _LegendSwatch.dashed:
        dot = CustomPaint(
          painter: _DashedBorderPainter(
            color: c.ink3.withValues(alpha: 0.7),
            radius: 3,
          ),
          child: const SizedBox(width: 12, height: 12),
        );
      case _LegendSwatch.filled:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
        );
      case _LegendSwatch.warmRing:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.warm, width: 2),
          ),
        );
      case _LegendSwatch.held:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.lock_outline_rounded, size: 8, color: c.ink3),
        );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
      ],
    );
  }
}

// ─── Sheets ────────────────────────────────────────────────────────────

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// The booked-seat detail sheet. Name + phone + Call, the seat context, the
/// requested lines, a group/priority indicator, and a "Free seat" action.
class _OccupantSheet extends StatelessWidget {
  final Passenger occupant;
  final SeatCell cell;
  final Bus bus;
  final String tourTitle;
  final bool isShared;
  final Future<void> Function() onFreeSeat;

  // TODO(seat-ui): move/swap wiring arrives in a later slice; the buttons
  // render disabled placeholders when these are null.
  final VoidCallback? onMove;
  final VoidCallback? onSwap;

  const _OccupantSheet({
    required this.occupant,
    required this.cell,
    required this.bus,
    required this.tourTitle,
    required this.isShared,
    required this.onFreeSeat,
    required this.onMove,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final priority = occupant.isPriorityApproved || cell.forward;
    final hasGroup = occupant.groupId != null && occupant.groupId!.isNotEmpty;
    final requestSummary = occupant.requestSummary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          // Name + phone + Call.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      occupant.displayName,
                      style: UgamText.titleM.copyWith(color: c.ink),
                    ),
                    if (occupant.phone.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        occupant.phone,
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (occupant.phone.isNotEmpty) ...[
                const SizedBox(width: UgamSpacing.sm),
                Semantics(
                  button: true,
                  label: 'Call ${occupant.phone}',
                  child: GestureDetector(
                    onTap: () => PhoneDialer.call(occupant.phone),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 42,
                      height: 42,
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
                ),
              ],
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // Seat context chip.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.md,
              vertical: UgamSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
              border: Border.all(color: c.accent.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.event_seat_rounded, size: 18, color: c.accent),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Seat ${cell.seatId}'
                        '${isShared ? ' (shared)' : ''}',
                        style: UgamText.titleS.copyWith(color: c.accent),
                      ),
                      Text(
                        '${bus.name} · $tourTitle',
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
          // Requested lines summary.
          const SizedBox(height: UgamSpacing.md),
          _SheetRow(
            label: 'Requested',
            value: requestSummary,
            c: c,
          ),
          // Group / priority indicators.
          if (priority || hasGroup) ...[
            const SizedBox(height: UgamSpacing.sm + 2),
            Wrap(
              spacing: UgamSpacing.sm,
              runSpacing: UgamSpacing.sm,
              children: [
                if (priority)
                  _IndicatorChip(
                    icon: Icons.star_rounded,
                    label: occupant.isPriorityApproved
                        ? 'Priority'
                        : 'Forward zone',
                    fill: c.warmFill,
                    tint: c.warm,
                  ),
                if (hasGroup)
                  _IndicatorChip(
                    icon: Icons.group_rounded,
                    label: 'Group ${occupant.groupId}',
                    fill: c.cardElev,
                    tint: c.ink2,
                    dot: _GroupPalette.colorFor(occupant.groupId!),
                  ),
              ],
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          // Free seat — the one mutating action in this slice.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onFreeSeat,
              icon: const Icon(Icons.event_seat_outlined, size: 16),
              label: const Text('Free seat'),
              style: OutlinedButton.styleFrom(
                foregroundColor: c.danger,
                side: BorderSide(color: c.danger.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
          // Close.
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: c.ink2),
              child: const Text('Close'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A shared-double picker: lists the two berth-holders so the agent chooses
/// whom to act on before the detail sheet opens.
class _SharedChooserSheet extends StatelessWidget {
  final List<Passenger> occupants;
  final String seatId;
  final ValueChanged<Passenger> onPick;

  const _SharedChooserSheet({
    required this.occupants,
    required this.seatId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          Text(
            'Seat $seatId is shared',
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'Two passengers share this Double Sofa. Pick one to view.',
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (final p in occupants)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: GestureDetector(
                onTap: () => onPick(p),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
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
                          _SeatTile.initials(p.displayName),
                          style: UgamText.bodyStrong.copyWith(
                            color: c.onAccent,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: Text(
                          p.displayName,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _SheetRow({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _IndicatorChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color fill;
  final Color tint;
  final Color? dot;

  const _IndicatorChip({
    required this.icon,
    required this.label,
    required this.fill,
    required this.tint,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ] else ...[
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: UgamText.micro.copyWith(
              color: tint,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
