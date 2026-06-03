import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/handler_manifest.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../services/customer_requests_store.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

String _money(num v) => '₹${v.toStringAsFixed(0)}';

/// Read-only full bus chart for a tour "handler" (group coordinator).
///
/// The handler is a customer the agent has flagged as the on-the-ground
/// point of contact. Unlike a regular customer — who only sees their own
/// seats — the handler can pull the WHOLE manifest (every bus + every
/// passenger) so they can find any seatmate and call them. This screen is
/// strictly read-only: no drag, no edit, no assignment. It mirrors the
/// agent's `TourSeatAssignmentScreen` look (bus pills + Ugam seat tiles)
/// but every tap on an occupied seat opens a call sheet instead.
///
/// Data comes from `CustomerRequestsStore.handlerTourManifest`, the same
/// singleton store the customer seat-layout viewer uses.
class HandlerBusChartScreen extends StatefulWidget {
  final String requestId;

  const HandlerBusChartScreen({super.key, required this.requestId});

  @override
  State<HandlerBusChartScreen> createState() => _HandlerBusChartScreenState();
}

class _HandlerBusChartScreenState extends State<HandlerBusChartScreen> {
  final _store = CustomerRequestsStore();

  bool _loading = true;
  String? _error;
  HandlerManifest? _manifest;
  String? _selectedBusId;

  /// Local, mutable collection cache keyed by '"$passengerId|$busId"'.
  /// Seeded from the manifest once loaded; updated in-place after each save so
  /// the chart recolors and the summary refreshes without a full reload.
  final Map<String, Collection> _collections = {};

  String _collectionKey(String passengerId, String busId, String seatId) =>
      '$passengerId|$busId|$seatId';

  /// Reads the local cache first, falling back to the manifest. Returns null
  /// when no money has been collected for that passenger on that bus.
  Collection? _collectionFor(String passengerId, String busId, String seatId) {
    final cached = _collections[_collectionKey(passengerId, busId, seatId)];
    if (cached != null) return cached;
    return _manifest?.collectionFor(passengerId, busId, seatId);
  }

  /// Aggregates collection figures across every passenger holding a seat on
  /// [bus], mirroring collection_screen's per-bus summary.
  _BusSummary _summaryForBus(HandlerManifest manifest, Bus bus) {
    double collected = 0;
    double toReturn = 0;
    double toCollect = 0;
    for (final p in manifest.passengers) {
      // Distinct seats only: a whole double-sofa = TWO entries on one seatId,
      // already full-priced by amountDueForSeat — iterate per distinct seatId
      // (not per entry) so it isn't counted twice.
      final seatIds = p.assignedSeats
          .where((a) => a.busId == bus.id)
          .map((a) => a.seatId)
          .toSet();
      for (final seatId in seatIds) {
        final due = bus.amountDueForSeat(p, seatId);
        final col = _collectionFor(p.id, bus.id, seatId);
        if (col != null) {
          collected += col.netCollected;
          toReturn += col.changeToReturn;
          toCollect += col.stillToCollect;
        } else {
          // No collection yet → this seat's due is still to collect.
          toCollect += due;
        }
      }
    }
    return _BusSummary(
      collected: collected,
      toReturn: toReturn,
      toCollect: toCollect,
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final manifest = await _store.handlerTourManifest(widget.requestId);
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _collections
          ..clear()
          ..addEntries(
            (manifest?.collections ?? const <Collection>[]).map(
              (col) => MapEntry(
                _collectionKey(col.passengerId, col.busId, col.seatId),
                col,
              ),
            ),
          );
        _selectedBusId = manifest?.buses.isNotEmpty == true
            ? manifest!.buses.first.id
            : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'We couldn\'t load the bus chart. Please try again.';
        _loading = false;
      });
    }
  }

  Bus? _selectedBus(HandlerManifest manifest) {
    if (manifest.buses.isEmpty) return null;
    final id = _selectedBusId;
    if (id != null) {
      final match = manifest.buses.where((b) => b.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    return manifest.buses.first;
  }

  void _onSeatTapped(Bus bus, String seatId, Passenger occupant) {
    _showOccupantSheet(bus, seatId, occupant);
  }

  Future<void> _showOccupantSheet(Bus bus, String seatId, Passenger passenger) {
    final due = bus.amountDueForSeat(passenger, seatId);
    final existing = _collectionFor(passenger.id, bus.id, seatId);
    // Resolve the tour id from the bus first, falling back to the passenger;
    // both manifest models carry tourId.
    final tourId = (bus.tourId?.isNotEmpty == true)
        ? bus.tourId!
        : passenger.tourId;

    return UgamSheet.show<void>(
      context,
      title: 'Collect',
      builder: (sheetCtx) => _CollectSheet(
        passenger: passenger,
        seatId: seatId,
        due: due,
        existing: existing,
        onSave: (received, returned, collectedBy, note) async {
          final base =
              existing ??
              Collection(
                tourId: tourId,
                busId: bus.id,
                passengerId: passenger.id,
                seatId: seatId,
              );
          final updated = base.copyWith(
            seatId: seatId,
            amountDue: due,
            amountReceived: received,
            amountRefunded: returned,
            collectedBy: collectedBy.isEmpty ? null : collectedBy,
            note: note.isEmpty ? null : note,
          );
          final saved = await _store.handlerUpsertCollection(
            widget.requestId,
            updated,
          );
          if (saved == null) {
            throw StateError('Handler collection save was rejected.');
          }
          if (!mounted) return;
          // Cache the server-returned row so ids/timestamps stay aligned with
          // the database after insert or conflict update.
          setState(() {
            _collections[_collectionKey(
                  saved.passengerId,
                  saved.busId,
                  saved.seatId,
                )] =
                saved;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(title: 'Bus chart', c: c),
            Expanded(child: _body(c)),
          ],
        ),
      ),
    );
  }

  Widget _body(UgamColorSet c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.cloud_off_rounded,
            title: 'Couldn\'t load chart',
            body: _error!,
          ),
        ),
      );
    }
    final manifest = _manifest;
    if (manifest == null || manifest.buses.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.event_seat_outlined,
            title: 'No bus chart yet',
            body:
                'The seat chart will appear here once the agent has set up '
                'the buses for this tour.',
          ),
        ),
      );
    }

    final bus = _selectedBus(manifest)!;
    final multiBus = manifest.buses.length > 1;
    final summary = _summaryForBus(manifest, bus);

    return Column(
      children: [
        if (multiBus)
          _BusPills(
            buses: manifest.buses,
            selectedBusId: bus.id,
            onTapBus: (id) => setState(() => _selectedBusId = id),
            c: c,
          ),
        if (multiBus) const SizedBox(height: UgamSpacing.md),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              multiBus ? 0 : UgamSpacing.md,
              UgamSpacing.gutter,
              UgamSpacing.xl,
            ),
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                _SummaryHeader(
                  collected: summary.collected,
                  toReturn: summary.toReturn,
                  toCollect: summary.toCollect,
                ),
                const SizedBox(height: UgamSpacing.lg),
                _SeatGrid(
                  bus: bus,
                  manifest: manifest,
                  collectionFor: (pId, seatId) =>
                      _collectionFor(pId, bus.id, seatId),
                  onTapOccupant: (seatId, p) => _onSeatTapped(bus, seatId, p),
                ),
                const SizedBox(height: UgamSpacing.lg),
                _Legend(c: c),
              ],
            ),
          ),
        ),
        SizedBox(
          height: MediaQuery.of(context).padding.bottom + UgamSpacing.xs,
        ),
      ],
    );
  }
}

// ─── Top bar ───────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title;
  final UgamColorSet c;

  const _TopBar({required this.title, required this.c});

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
          Container(
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
        ],
      ),
    );
  }
}

// ─── Bus pills ─────────────────────────────────────────────────────────

class _BusPills extends StatelessWidget {
  final List<Bus> buses;
  final String selectedBusId;
  final ValueChanged<String> onTapBus;
  final UgamColorSet c;

  const _BusPills({
    required this.buses,
    required this.selectedBusId,
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
              alignment: Alignment.center,
              child: Text(
                bus.name,
                style: UgamText.bodyStrong.copyWith(
                  color: selected ? c.onAccent : c.ink,
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

// ─── Group colour palette ──────────────────────────────────────────────

/// Six pleasant hues that read well as a thin ring on the near-black dark
/// ground. A passenger's [Passenger.groupId] is hashed into this list so the
/// same group always draws the same colour within a session.
///
/// Mirrors the agent seat-detail screen's group palette EXACTLY (the
/// seat-detail class is private to that file, so the hue list and hashing are
/// copied here verbatim) so the handler reads the same group colour the agent
/// sees for a given group.
class _GroupPalette {
  const _GroupPalette._();

  static const List<Color> hues = [
    Color(0xFF6AA9FF), // sky blue
    Color(0xFF8E7BFF), // periwinkle
    Color(0xFF4FD1C5), // teal
    Color(0xFFF6A5C0), // rose
    Color(0xFFB892FF), // violet
    Color(0xFF9AE6B4), // mint
  ];

  static Color colorFor(String groupId) {
    final idx = groupId.hashCode.abs() % hues.length;
    return hues[idx];
  }
}

/// The per-seat collection state, derived from the manifest's collection row
/// (if any) against what the seat owes. Drives a small corner indicator on the
/// occupied tile so the handler reads paid / owing / return-due at a glance —
/// the agent seat-detail tile has no money state, so this is the handler's
/// extra layer over the SAME tile look.
enum _MoneyState { uncollected, paid, owing, returnDue }

extension _MoneyStateView on _MoneyState {
  /// The dot colour for this money state. `uncollected` reads as a neutral
  /// hairline so it never competes with the group/priority ring.
  Color color(UgamColorSet c) {
    switch (this) {
      case _MoneyState.paid:
        return c.good;
      case _MoneyState.owing:
        return c.danger;
      case _MoneyState.returnDue:
        return c.warm;
      case _MoneyState.uncollected:
        return c.ink3;
    }
  }
}

// ─── Seat grid card ────────────────────────────────────────────────────

class _SeatGrid extends StatelessWidget {
  final Bus bus;
  final HandlerManifest manifest;
  final Collection? Function(String passengerId, String seatId) collectionFor;
  final void Function(String seatId, Passenger passenger) onTapOccupant;

  const _SeatGrid({
    required this.bus,
    required this.manifest,
    required this.collectionFor,
    required this.onTapOccupant,
  });

  /// The collection state for an occupied seat, mirroring collection_screen's
  /// _PassengerRow chip logic: return-due (warm) wins, then a shortfall is
  /// owing (danger), then a squared-off collection with cash in is paid (good),
  /// otherwise nothing has been collected yet.
  _MoneyState _moneyState(Passenger passenger, String seatId) {
    final due = bus.amountDueForSeat(passenger, seatId);
    final col = collectionFor(passenger.id, seatId);
    if (col == null) return due > 0 ? _MoneyState.owing : _MoneyState.uncollected;
    if (col.isReturnDue) return _MoneyState.returnDue;
    if (col.balance < 0) return _MoneyState.owing;
    if (col.isSquare && col.amountReceived > 0) return _MoneyState.paid;
    return _MoneyState.uncollected;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
        alignment: Alignment.center,
        child: Text(
          'This bus has no seat layout yet.',
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    // A touch larger than the legacy tile so initials read cleanly, matching
    // the agent seat-detail tile size. The grid FittedBox scales to fit width.
    const double tileW = 58;
    const double tileH = 58;

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: CombinedSeatGrid(
        layout: layout,
        cellWidth: tileW,
        cellHeight: tileH,
        colGap: 8,
        rowGap: 8,
        driverLabel: 'Driver',
        tileBuilder: (ctx, cell) {
          final occupant = cell.seatId == null
              ? null
              : manifest.seatOccupant(bus.id, cell.seatId!);
          final money = occupant == null
              ? _MoneyState.uncollected
              : _moneyState(occupant, cell.seatId!);
          return SizedBox(
            width: tileW,
            height: tileH,
            child: RepaintBoundary(
              child: _SeatTile(
                cell: cell,
                occupant: occupant,
                money: money,
                onTap: occupant == null
                    ? null
                    : () => onTapOccupant(cell.seatId!, occupant),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A single read-only handler tile, styled to MATCH the agent seat-detail
/// tile — occupant initials on a card fill, a group-colour ring when grouped,
/// a warm ring + star when priority/forward, a dashed look when free, and a
/// "Held" look when reserved. The handler-only addition is a small corner
/// money dot (paid / owing / return-due) so the handler reads collection state
/// at a glance. Tapping an occupied tile opens the collect / call sheet; free
/// and held tiles are inert (the handler never edits seats).
class _SeatTile extends StatelessWidget {
  final SeatCell cell;
  final Passenger? occupant;
  final _MoneyState money;
  final VoidCallback? onTap;

  const _SeatTile({
    required this.cell,
    required this.occupant,
    required this.money,
    required this.onTap,
  });

  bool get _occupied => occupant != null;

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

    final Widget tile;
    if (_occupied) {
      tile = _bookedTile(c, occupant!);
    } else if (cell.reserved) {
      tile = _heldTile(c);
    } else {
      tile = _freeTile(c);
    }

    if (onTap == null) return tile;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }

  // FREE — dashed ink3 hairline, transparent fill, faint glyph + seat id.
  Widget _freeTile(UgamColorSet c) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: c.ink3.withValues(alpha: 0.55),
        radius: UgamRadius.seat,
      ),
      child: Center(
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

  // BOOKED — initials on card fill; group ring + warm priority ring/badge,
  // plus a handler-only money dot in the bottom-left corner.
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
                UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
              ),
            ),
          ),
          // Priority warm badge, top-right.
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            ),
          // Group dot badge (only when the group colour isn't already the
          // ring, i.e. a priority booking that ALSO belongs to a group).
          if (priority && groupColor != null)
            Positioned(
              bottom: 4,
              right: 4,
              child: _Dot(color: groupColor, size: 8),
            ),
          // Handler-only money dot, bottom-left, so collection state never
          // collides with the group/priority signals on the right.
          Positioned(
            bottom: 4,
            left: 5,
            child: _Dot(color: money.color(c), size: 8),
          ),
        ],
      ),
    );
  }
}

/// A small filled circle used for group / money badges on a seat tile.
class _Dot extends StatelessWidget {
  final Color color;
  final double size;

  const _Dot({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Paints a dashed rounded-rectangle border for the FREE tile. Kept local so
/// the free look stays distinct from the solid-bordered booked/held tiles —
/// mirrors the agent seat-detail screen's free-tile border.
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

/// Reads the chart for the handler: the seat-state swatches (matching the
/// agent seat-detail legend) plus the handler-only money dots.
class _Legend extends StatelessWidget {
  final UgamColorSet c;
  const _Legend({required this.c});

  @override
  Widget build(BuildContext context) {
    return Wrap(
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
        _LegendItem(swatch: _LegendSwatch.paidDot, label: 'Paid', c: c),
        _LegendItem(swatch: _LegendSwatch.owingDot, label: 'Owing', c: c),
      ],
    );
  }
}

enum _LegendSwatch { dashed, filled, warmRing, held, paidDot, owingDot }

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
      case _LegendSwatch.paidDot:
        dot = _Dot(color: c.good, size: 12);
      case _LegendSwatch.owingDot:
        dot = _Dot(color: c.danger, size: 12);
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

// ─── Summary header ────────────────────────────────────────────────────

/// Aggregated collection figures for the selected bus.
class _BusSummary {
  final double collected;
  final double toReturn;
  final double toCollect;

  const _BusSummary({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
  });
}

class _SummaryHeader extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;

  const _SummaryHeader({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: UgamStatTile(
            icon: Icons.payments_rounded,
            value: _money(collected),
            label: 'Collected',
            variant: UgamStatVariant.good,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: UgamStatTile(
            icon: Icons.undo_rounded,
            value: _money(toReturn),
            label: 'To return',
            variant: UgamStatVariant.warm,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: UgamStatTile(
            icon: Icons.account_balance_wallet_rounded,
            value: _money(toCollect),
            label: 'To collect',
            variant: UgamStatVariant.accent,
          ),
        ),
      ],
    );
  }
}

// ─── Collect sheet ─────────────────────────────────────────────────────

/// Per-passenger collect form, mirroring collection_screen._openCollectSheet.
/// Keeps the call header (name + handler chip + age + phone + Call) and adds
/// the money form below. [onSave] persists the collection and updates the
/// chart; this widget owns the field controllers and pops on success.
class _CollectSheet extends StatefulWidget {
  final Passenger passenger;
  final String seatId;
  final double due;
  final Collection? existing;
  final Future<void> Function(
    double received,
    double returned,
    String collectedBy,
    String note,
  )
  onSave;

  const _CollectSheet({
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.existing,
    required this.onSave,
  });

  @override
  State<_CollectSheet> createState() => _CollectSheetState();
}

class _CollectSheetState extends State<_CollectSheet> {
  late final TextEditingController _receivedCtrl;
  late final TextEditingController _returnedCtrl;
  late final TextEditingController _collectedByCtrl;
  late final TextEditingController _noteCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final col = widget.existing;
    _receivedCtrl = TextEditingController(
      text: (col?.amountReceived ?? 0) == 0
          ? ''
          : col!.amountReceived.toStringAsFixed(0),
    );
    _returnedCtrl = TextEditingController(
      text: (col?.amountRefunded ?? 0) == 0
          ? ''
          : col!.amountRefunded.toStringAsFixed(0),
    );
    _collectedByCtrl = TextEditingController(text: col?.collectedBy ?? '');
    _noteCtrl = TextEditingController(text: col?.note ?? '');
  }

  @override
  void dispose() {
    _receivedCtrl.dispose();
    _returnedCtrl.dispose();
    _collectedByCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double _parse(TextEditingController ctl) =>
      double.tryParse(ctl.text.trim()) ?? 0;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _parse(_receivedCtrl),
        _parse(_returnedCtrl),
        _collectedByCtrl.text.trim(),
        _noteCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error('Couldn\'t save the collection. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = widget.passenger;
    final hasPhone = passenger.phone.trim().isNotEmpty;
    final due = widget.due;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: avatar, name, handler chip, age group ──
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  passenger.name.trim().isNotEmpty
                      ? passenger.name.trim()[0].toUpperCase()
                      : '?',
                  style: UgamText.titleL.copyWith(color: c.accent),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            passenger.name.trim().isNotEmpty
                                ? passenger.name
                                : 'Passenger',
                            style: UgamText.titleL.copyWith(color: c.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (passenger.isHandler) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: c.warmFill,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'HANDLER',
                              style: UgamText.micro.copyWith(
                                color: c.warm,
                                fontSize: 9,
                                letterSpacing: 0.6,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      passenger.ageGroup.displayName,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Phone + Call ──
          Container(
            padding: const EdgeInsets.all(UgamSpacing.md),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.phone_outlined, size: 18, color: c.ink2),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    hasPhone ? passenger.phone : 'No phone number',
                    style: UgamText.body.copyWith(
                      color: hasPhone ? c.ink : c.ink3,
                    ),
                  ),
                ),
                if (hasPhone)
                  GestureDetector(
                    onTap: () => PhoneDialer.call(passenger.phone),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.md,
                        vertical: UgamSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(UgamRadius.chip),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.call_rounded, size: 15, color: c.onAccent),
                          const SizedBox(width: 6),
                          Text(
                            'Call',
                            style: UgamText.caption.copyWith(
                              color: c.onAccent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Collect form ──
          _ReadOnlyLine(label: 'Seat', value: widget.seatId),
          const SizedBox(height: UgamSpacing.sm),
          _ReadOnlyLine(label: 'Amount due', value: _money(due)),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: 'Received',
            controller: _receivedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: 'Returned to customer',
            controller: _returnedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(label: 'Collected by', controller: _collectedByCtrl),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(label: 'Note', controller: _noteCtrl),
          const SizedBox(height: UgamSpacing.lg),
          // ── Live balance pill ──
          Builder(
            builder: (_) {
              final balance =
                  _parse(_receivedCtrl) - _parse(_returnedCtrl) - due;
              final (String balLabel, Color balColor) = balance > 0
                  ? ('Change to return: ${_money(balance)}', c.warm)
                  : balance < 0
                  ? ('Still to collect: ${_money(-balance)}', c.danger)
                  : ('Settled', c.good);
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.lg,
                  vertical: UgamSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: balColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                ),
                child: Text(
                  balLabel,
                  style: UgamText.bodyStrong.copyWith(color: balColor),
                ),
              );
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving ? 'Saving…' : 'Save',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyLine extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: UgamText.body.copyWith(color: c.ink2)),
        Text(
          value,
          style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}
