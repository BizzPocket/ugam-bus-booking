import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/seat_layout.dart';
import '../models/tour.dart';
import '../models/tour_seat_snapshot.dart';
import '../utils/app_nav.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_occupants.dart';

/// Canonical history seat-tile size, matching the app's `kSeatTileW/H` so the
/// read-only chart reads at the same scale as every live chart.
const double _kSeatTileW = 60;
const double _kSeatTileH = 60;

/// READ-ONLY seat chart for a PAST (completed) tour.
///
/// The live editor recycles GO seats for the return leg, destroying the
/// outbound chart, so a per-leg [TourSeatSnapshot] is frozen at completion (see
/// the design doc, Part B). This screen reads those snapshots back and paints
/// them with the SAME [CombinedSeatGrid] placement the live charts use, plus a
/// minimal static [_SnapshotSeatTile] — no tap-to-edit, no live passenger
/// dependency, no sticky CTA.
///
/// Behaviour:
///   * Both legs captured → a GO / RETURN segmented toggle (default GO).
///   * One leg captured → that leg renders with no toggle.
///   * Neither captured (legacy tour, or capture failed) → FALLBACK to the live
///     passenger chart, read-only, with a small "showing current seating" note.
///   * No buses / no seating at all → an empty state.
class PastTourSeatHistoryScreen extends StatefulWidget {
  final String tourId;

  const PastTourSeatHistoryScreen({super.key, required this.tourId});

  @override
  State<PastTourSeatHistoryScreen> createState() =>
      _PastTourSeatHistoryScreenState();
}

class _PastTourSeatHistoryScreenState extends State<PastTourSeatHistoryScreen> {
  TourController get _ctrl => Get.find<TourController>();

  bool _loading = true;
  List<TourSeatSnapshot> _snapshots = const [];

  /// Selected leg when both snapshots exist. Defaults to outbound (GO).
  SnapshotLeg _leg = SnapshotLeg.outbound;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snaps = await _ctrl.loadSeatSnapshots(widget.tourId);
    if (!mounted) return;
    setState(() {
      _snapshots = snaps;
      _loading = false;
    });
  }

  TourSeatSnapshot? _snapshotFor(SnapshotLeg leg) {
    for (final s in _snapshots) {
      if (s.leg == leg) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tour = _ctrl.getTour(widget.tourId);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              title: tr('seat_history.title'),
              subtitle: tour?.route,
              onBack: () => AppNav.pop(context),
            ),
            Expanded(child: _body(c, tour)),
          ],
        ),
      ),
    );
  }

  Widget _body(UgamColorSet c, Tour? tour) {
    if (_loading) {
      return _loadingSkeleton();
    }

    if (tour == null) {
      return _empty(c);
    }

    final outbound = _snapshotFor(SnapshotLeg.outbound);
    final ret = _snapshotFor(SnapshotLeg.return_);

    // No snapshot at all → fall back to the live passenger chart, read-only.
    if (outbound == null && ret == null) {
      return _fallbackLiveChart(c, tour);
    }

    final bothLegs = outbound != null && ret != null;
    // With a single leg, force the selection onto whichever one we have.
    final selected = bothLegs
        ? (_leg == SnapshotLeg.return_ ? ret : outbound)
        : (outbound ?? ret)!;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const BouncingScrollPhysics(),
      children: [
        if (bothLegs) ...[
          UgamTabPills(
            items: [
              UgamTabItem(label: tr('seat_history.leg_go')),
              UgamTabItem(label: tr('seat_history.leg_return')),
            ],
            currentIndex: _leg == SnapshotLeg.return_ ? 1 : 0,
            onChanged: (i) => setState(
              () => _leg = i == 1 ? SnapshotLeg.return_ : SnapshotLeg.outbound,
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
        ],
        ..._snapshotSections(c, tour, selected),
      ],
    );
  }

  /// One section per snapshot bus that still has a matching live [Bus] layout.
  /// A bus deleted after completion has no layout to render, so its section is
  /// skipped (the snapshot is keyed by the live busId).
  List<Widget> _snapshotSections(
    UgamColorSet c,
    Tour tour,
    TourSeatSnapshot snapshot,
  ) {
    final sections = <Widget>[];
    for (final snapBus in snapshot.buses) {
      final bus = _busById(tour, snapBus.busId);
      final layout = bus?.layout;
      if (bus == null || layout == null) continue;

      sections.add(_busHeader(c, bus));
      sections.add(const SizedBox(height: UgamSpacing.md));
      sections.add(
        CombinedSeatGrid(
          layout: layout,
          tileBuilder: (context, cell) {
            final occ = snapBus.occupant(cell.seatId ?? '');
            return _SnapshotSeatTile(cell: cell, name: occ?.name);
          },
        ),
      );
      sections.add(const SizedBox(height: UgamSpacing.xl));
    }

    // Every snapshot bus was deleted → nothing to draw.
    if (sections.isEmpty) {
      return [_empty(c, inline: true)];
    }
    return sections;
  }

  /// Read-only render of the LIVE seating when no snapshot was captured. Builds
  /// per-seat occupants from the live passengers via [seatOccupantsForBus] and
  /// shows the GO (or RET) holder. A thin caption notes this is current data.
  Widget _fallbackLiveChart(UgamColorSet c, Tour tour) {
    final buses = tour.buses.where((b) => b.layout != null).toList();
    if (buses.isEmpty || tour.passengers.isEmpty) {
      return _empty(c);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const BouncingScrollPhysics(),
      children: [
        _fallbackBanner(c),
        const SizedBox(height: UgamSpacing.lg),
        for (final bus in buses) ...[
          _busHeader(c, bus),
          const SizedBox(height: UgamSpacing.md),
          Builder(
            builder: (context) {
              final occupants = seatOccupantsForBus(tour.passengers, bus.id);
              return CombinedSeatGrid(
                layout: bus.layout!,
                tileBuilder: (context, cell) {
                  final seatId = cell.seatId ?? '';
                  final o = occupants[seatId];
                  // Live fallback shows the GO holder, else the RET holder.
                  final p = o?.go ?? o?.ret;
                  return _SnapshotSeatTile(cell: cell, name: p?.displayName);
                },
              );
            },
          ),
          const SizedBox(height: UgamSpacing.xl),
        ],
      ],
    );
  }

  Widget _fallbackBanner(UgamColorSet c) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: c.ink3),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr('seat_history.fallback_note'),
              style: UgamText.caption.copyWith(color: c.ink2, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  /// Per-bus section header: a bus glyph + the bus name.
  Widget _busHeader(UgamColorSet c, Bus bus) {
    return Row(
      children: [
        Icon(Icons.directions_bus_rounded, size: 16, color: c.ink3),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Text(
            bus.name,
            style: UgamText.titleS.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// One canonical empty state for every fallback path (no tour, no buses, no
  /// renderable snapshot bus). [inline] pads it for use inside a [ListView].
  Widget _empty(UgamColorSet c, {bool inline = false}) {
    final empty = UgamEmpty(
      icon: Icons.event_seat_outlined,
      title: tr('seat_history.empty'),
    );
    return inline
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
            child: empty,
          )
        : empty;
  }

  /// Loading placeholder — soft skeletons in place of a spinner, matching the
  /// app's load pattern (see the dashboard shimmer).
  Widget _loadingSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 42, radius: UgamRadius.input),
        SizedBox(height: UgamSpacing.lg),
        UgamSkeleton.text(width: 120),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 240, radius: UgamRadius.card),
      ],
    );
  }

  Bus? _busById(Tour tour, String busId) {
    for (final b in tour.buses) {
      if (b.id == busId) return b;
    }
    return null;
  }
}

/// A read-only seat tile for the history chart. Shows the seat id and, when
/// occupied, the occupant name (truncated). Borderless and soft per the design
/// language: occupied reads as a tonal copper fill, empty as a quiet recessed
/// surface — depth from fill, not strokes (≤1 occupant per seat, no tap, no
/// flags).
class _SnapshotSeatTile extends StatelessWidget {
  final SeatCell cell;

  /// Occupant name when the seat was taken on this leg; null when it was empty.
  final String? name;

  const _SnapshotSeatTile({required this.cell, this.name});

  bool get _occupied => (name ?? '').trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return _occupied ? _bookedTile(c) : _freeTile(c);
  }

  Widget _bookedTile(UgamColorSet c) {
    return Container(
      width: _kSeatTileW,
      height: _kSeatTileH,
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(3, 12, 3, 6),
              child: Text(
                name!.trim(),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            left: 5,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _freeTile(UgamColorSet c) {
    return Container(
      width: _kSeatTileW,
      height: _kSeatTileH,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
      ),
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
    );
  }
}
