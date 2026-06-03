import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/handler_manifest.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

String _money(num v) => '₹${v.toStringAsFixed(0)}';

/// The passengers holding one seat, resolved by leg.
///
/// A single seat can now be LEG-SHARED: an `outboundOnly` passenger (the GO
/// leg) and a separate `returnOnly` passenger (the RETURN leg) can both hold
/// the same seatId on disjoint legs. A `roundTrip` passenger holds BOTH legs
/// exclusively (so [go] and [ret] are the same person). [primary] is the
/// passenger to show first / use for the single-occupant tile look.
class _SeatOccupants {
  /// The GO-leg occupant (outboundOnly or roundTrip), if any.
  final Passenger? go;

  /// The RETURN-leg occupant (returnOnly or roundTrip), if any.
  final Passenger? ret;

  const _SeatOccupants({this.go, this.ret});

  bool get isEmpty => go == null && ret == null;

  /// True when GO and RETURN are two DIFFERENT people sharing the seat across
  /// legs (an outbound-only + a return-only) — the leg-shared case.
  bool get isLegShared => go != null && ret != null && go!.id != ret!.id;

  /// The single passenger when the seat is held by one person (a round-trip,
  /// or a lone one-way leg); null when leg-shared or empty.
  Passenger? get sole {
    if (isEmpty) return null;
    if (isLegShared) return null;
    return go ?? ret;
  }

  /// Every DISTINCT passenger on this seat, GO first.
  List<Passenger> get all {
    final out = <Passenger>[];
    if (go != null) out.add(go!);
    if (ret != null && (go == null || ret!.id != go!.id)) out.add(ret!);
    return out;
  }
}

/// Builds a leg-resolved occupant view for [seatId] on [busId] from the
/// manifest's passengers. A whole-double (one passenger, two assignment
/// entries on the SAME seatId) still resolves to a single occupant; a
/// genuine leg-shared seat resolves to two distinct people on disjoint legs.
_SeatOccupants _occupantsForSeat(
  HandlerManifest manifest,
  String busId,
  String seatId,
) {
  Passenger? go;
  Passenger? ret;
  for (final p in manifest.passengers) {
    final holdsSeat = p.assignedSeats.any(
      (a) => a.busId == busId && a.seatId == seatId,
    );
    if (!holdsSeat) continue;
    if (p.tripType.usesOutbound && go == null) go = p;
    if (p.tripType.usesReturn && ret == null) ret = p;
  }
  return _SeatOccupants(go: go, ret: ret);
}

/// The two ways the handler reads the chart: the visual seat [grid] or the
/// call-first [list] (a roster of full name + mobile per seat).
enum _ViewMode { grid, list }

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

  /// Chart vs roster. The handler most often needs full names + mobiles to
  /// call people, so a List (roster) sits alongside the visual Grid.
  _ViewMode _viewMode = _ViewMode.grid;

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
    final manifest = _manifest;
    // A leg-shared seat (a GO occupant + a different RETURN occupant) needs a
    // chooser: the handler picks which person to call / collect from. A single
    // occupant goes straight to the collect sheet.
    final occ = manifest == null
        ? const _SeatOccupants()
        : _occupantsForSeat(manifest, bus.id, seatId);
    if (occ.isLegShared) {
      _showLegSharedChooser(bus, seatId, occ);
      return;
    }
    _showOccupantSheet(bus, seatId, occupant);
  }

  /// Leg-shared seat → a small chooser listing the GO occupant and the RETURN
  /// occupant (each with phone + Call), so the handler picks whom to act on
  /// before the collect sheet opens.
  Future<void> _showLegSharedChooser(
    Bus bus,
    String seatId,
    _SeatOccupants occ,
  ) {
    return UgamSheet.show<void>(
      context,
      title: 'Seat $seatId · shared',
      builder: (sheetCtx) => _LegSharedChooserSheet(
        seatId: seatId,
        go: occ.go,
        ret: occ.ret,
        onPick: (p) {
          Navigator.of(sheetCtx).pop();
          _showOccupantSheet(bus, seatId, p);
        },
      ),
    );
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

    final grid = _viewMode == _ViewMode.grid;

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
        Padding(
          padding: EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            multiBus ? 0 : UgamSpacing.md,
            UgamSpacing.gutter,
            UgamSpacing.sm,
          ),
          child: _ViewToggle(
            mode: _viewMode,
            onChanged: (m) => setState(() => _viewMode = m),
            c: c,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              0,
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
                if (grid) ...[
                  _SeatGrid(
                    bus: bus,
                    manifest: manifest,
                    collectionFor: (pId, seatId) =>
                        _collectionFor(pId, bus.id, seatId),
                    onTapOccupant: (seatId, p) => _onSeatTapped(bus, seatId, p),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  _Legend(c: c),
                ] else
                  _SeatRoster(
                    bus: bus,
                    manifest: manifest,
                    collectionFor: (pId, seatId) =>
                        _collectionFor(pId, bus.id, seatId),
                    onTapOccupant: (seatId, p) => _onSeatTapped(bus, seatId, p),
                  ),
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

// ─── Group colour ──────────────────────────────────────────────────────

// Group ring colours come from the shared `groupColorForId` util
// (lib/design/group_color.dart) — an infinite, golden-angle hue generator that
// never collides with the warm priority ring or the one-way tint. The old
// copied 6-hue `_GroupPalette` was deleted so the handler reads exactly the
// same colour the agent seat-detail screen shows for a given group.

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
          // Leg-aware: a seat may hold a GO occupant and a DIFFERENT RETURN
          // occupant (an outbound-only + a return-only sharing the seat on
          // disjoint legs). Resolve both so the tile can split + badge them.
          final occ = cell.seatId == null
              ? const _SeatOccupants()
              : _occupantsForSeat(manifest, bus.id, cell.seatId!);
          // The money dot follows the GO occupant first (then RETURN) — the
          // primary person whose due/collection drives the at-a-glance state.
          final primary = occ.go ?? occ.ret;
          final money = primary == null
              ? _MoneyState.uncollected
              : _moneyState(primary, cell.seatId!);
          return SizedBox(
            width: tileW,
            height: tileH,
            child: RepaintBoundary(
              child: _SeatTile(
                cell: cell,
                occupants: occ,
                money: money,
                onTap: primary == null
                    ? null
                    : () => onTapOccupant(cell.seatId!, primary),
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
  final _SeatOccupants occupants;
  final _MoneyState money;
  final VoidCallback? onTap;

  const _SeatTile({
    required this.cell,
    required this.occupants,
    required this.money,
    required this.onTap,
  });

  bool get _occupied => !occupants.isEmpty;

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
    if (occupants.isLegShared) {
      tile = _legSharedTile(c, occupants.go!, occupants.ret!);
    } else if (_occupied) {
      tile = _bookedTile(c, occupants.sole!);
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
  // a one-way GO/RET corner badge + cyan tint for a single-leg occupant, plus a
  // handler-only money dot in the bottom-left corner.
  Widget _bookedTile(UgamColorSet c, Passenger p) {
    final priority = p.isPriorityApproved || cell.forward;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    // INFINITE COLORS: shared golden-angle generator (never collides with the
    // warm priority ring or the one-way cyan tint).
    final groupColor = hasGroup ? groupColorForId(p.groupId!) : null;
    final oneWay = p.tripType.isOneWay;

    // The outer ring colour signals belonging. Priority (warm) is attention so
    // it always wins; then a one-way leg shows the cyan tint; then a group ring.
    final Color ringColor;
    final double ringWidth;
    if (priority) {
      ringColor = c.warm;
      ringWidth = 2;
    } else if (oneWay) {
      ringColor = kOneWayTint;
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
          // Priority warm badge, top-right (priority outranks the leg badge).
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            )
          // One-way GO/RET corner badge, top-right, when not priority.
          else if (oneWay)
            Positioned(
              top: 2,
              right: 2,
              child: _LegBadge(tripType: p.tripType),
            ),
          // Group dot badge (only when the group colour isn't already the ring,
          // i.e. a priority or one-way booking that ALSO belongs to a group).
          if ((priority || oneWay) && groupColor != null)
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

  // LEG-SHARED — a GO occupant and a DIFFERENT RETURN occupant on disjoint
  // legs. Split left (GO) / right (RET), each half showing initials, a GO/RET
  // badge and a group dot; the cyan one-way tint frames the whole tile.
  Widget _legSharedTile(UgamColorSet c, Passenger go, Passenger ret) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: kOneWayTint, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(child: _legHalf(c, go, TripType.outboundOnly)),
              Container(width: 1, color: c.border),
              Expanded(child: _legHalf(c, ret, TripType.returnOnly)),
            ],
          ),
          // Seat id, centred top.
          Positioned(
            top: 3,
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
          // Handler-only money dot (follows the GO occupant), bottom-left.
          Positioned(
            bottom: 3,
            left: 4,
            child: _Dot(color: money.color(c), size: 7),
          ),
        ],
      ),
    );
  }

  Widget _legHalf(UgamColorSet c, Passenger p, TripType leg) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColorForId(p.groupId!) : null;
    return Container(
      color: c.cardElev,
      alignment: Alignment.center,
      child: Stack(
        children: [
          Center(
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
                  const SizedBox(height: 2),
                  _Dot(color: groupColor, size: 6),
                ],
              ],
            ),
          ),
          Positioned(
            bottom: 1,
            right: 1,
            child: _LegBadge(tripType: leg, compact: true),
          ),
        ],
      ),
    );
  }
}

/// A tiny GO / RET corner pill marking a one-way leg on a seat tile, tinted
/// with [kOneWayTint]. [compact] shrinks it for the split leg-shared halves.
class _LegBadge extends StatelessWidget {
  final TripType tripType;
  final bool compact;

  const _LegBadge({required this.tripType, this.compact = false});

  String get _label => tripType.usesReturn && !tripType.usesOutbound
      ? 'RET'
      : 'GO';

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 3 : 4,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: kOneWayTint,
        borderRadius: BorderRadius.circular(4),
      ),
      // Dark ground reads as crisp ink on the bright cyan tint (no hardcoded
      // hex — kOneWayTint is the only fixed colour, supplied by the util).
      child: Text(
        _label,
        style: UgamText.micro.copyWith(
          color: c.bg,
          fontSize: compact ? 7 : 8,
          height: 1,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w900,
        ),
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
        _LegendItem(swatch: _LegendSwatch.oneWay, label: 'One-way (GO/RET)', c: c),
        _LegendItem(swatch: _LegendSwatch.paidDot, label: 'Paid', c: c),
        _LegendItem(swatch: _LegendSwatch.owingDot, label: 'Owing', c: c),
      ],
    );
  }
}

enum _LegendSwatch { dashed, filled, warmRing, held, oneWay, paidDot, owingDot }

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
      case _LegendSwatch.oneWay:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kOneWayTint, width: 2),
          ),
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

// ─── Grid / List toggle ────────────────────────────────────────────────

/// A two-segment pill switching the chart between the visual seat [grid] and
/// the call-first [list] (roster). DNA: accent fill on the selected segment,
/// cardElev track.
class _ViewToggle extends StatelessWidget {
  final _ViewMode mode;
  final ValueChanged<_ViewMode> onChanged;
  final UgamColorSet c;

  const _ViewToggle({
    required this.mode,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        children: [
          _segment(
            icon: Icons.grid_view_rounded,
            label: 'Grid',
            selected: mode == _ViewMode.grid,
            onTap: () => onChanged(_ViewMode.grid),
          ),
          _segment(
            icon: Icons.format_list_bulleted_rounded,
            label: 'List',
            selected: mode == _ViewMode.list,
            onTap: () => onChanged(_ViewMode.list),
          ),
        ],
      ),
    );
  }

  Widget _segment({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? c.onAccent : c.ink2,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: UgamText.caption.copyWith(
                    color: selected ? c.onAccent : c.ink2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Seat roster (List view) ────────────────────────────────────────────

/// The call-first roster: one row per booked berth in seat order, showing the
/// seat id, the occupant's FULL name + mobile (tap to call), a trip badge
/// (round-trip / GO / RET), a group dot, and the per-seat collection status.
/// A leg-shared seat emits TWO rows (the GO occupant and the RETURN occupant).
/// Read-only + collect: tapping the row (or the money chip) opens the same
/// collect sheet the grid uses.
class _SeatRoster extends StatelessWidget {
  final Bus bus;
  final HandlerManifest manifest;
  final Collection? Function(String passengerId, String seatId) collectionFor;
  final void Function(String seatId, Passenger passenger) onTapOccupant;

  const _SeatRoster({
    required this.bus,
    required this.manifest,
    required this.collectionFor,
    required this.onTapOccupant,
  });

  _MoneyState _moneyState(Passenger passenger, String seatId) {
    final due = bus.amountDueForSeat(passenger, seatId);
    final col = collectionFor(passenger.id, seatId);
    if (col == null) {
      return due > 0 ? _MoneyState.owing : _MoneyState.uncollected;
    }
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

    // Walk every seat cell in placement order; emit a row per distinct
    // occupant. `grid` is the flat seat list (only [hasSeat] cells stored).
    final rows = <Widget>[];
    for (final cell in layout.grid) {
      final seatId = cell.seatId;
      if (seatId == null) continue;
      final occ = _occupantsForSeat(manifest, bus.id, seatId);
      if (occ.isEmpty) continue;
      for (final p in occ.all) {
        rows.add(
          _RosterRow(
            seatId: seatId,
            passenger: p,
            money: _moneyState(p, seatId),
            onTap: () => onTapOccupant(seatId, p),
            c: c,
          ),
        );
      }
    }

    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
        alignment: Alignment.center,
        child: Text(
          'No passengers seated on ${bus.name} yet.',
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
      child: Column(children: rows),
    );
  }
}

/// One roster line: seat id chip, full name + mobile + group dot + trip badge,
/// and a tap-to-call action plus the collection-status chip.
class _RosterRow extends StatelessWidget {
  final String seatId;
  final Passenger passenger;
  final _MoneyState money;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _RosterRow({
    required this.seatId,
    required this.passenger,
    required this.money,
    required this.onTap,
    required this.c,
  });

  String get _moneyLabel {
    switch (money) {
      case _MoneyState.paid:
        return 'Paid';
      case _MoneyState.owing:
        return 'Owing';
      case _MoneyState.returnDue:
        return 'Return due';
      case _MoneyState.uncollected:
        return 'Not collected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColorForId(p.groupId!) : null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        child: Row(
          children: [
            // Seat id chip.
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
                border: Border.all(color: c.border),
              ),
              child: Text(
                seatId,
                style: UgamText.tabular(
                  UgamText.caption.copyWith(
                    color: c.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            // Name + mobile + badges.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.displayName,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (groupColor != null) ...[
                        const SizedBox(width: 6),
                        _Dot(color: groupColor, size: 8),
                      ],
                      const SizedBox(width: 6),
                      _TripBadge(tripType: p.tripType, c: c),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasPhone ? p.phone : 'No mobile',
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(
                        color: hasPhone ? c.ink2 : c.ink3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _Dot(color: money.color(c), size: 7),
                      const SizedBox(width: 5),
                      Text(
                        _moneyLabel,
                        style: UgamText.micro.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Tap-to-call.
            if (hasPhone) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: 'Call ${p.phone}',
                child: GestureDetector(
                  onTap: () => PhoneDialer.call(p.phone),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.call_rounded, size: 17, color: c.accent),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A small trip-type pill. Round-trip is muted (the common case); a one-way
/// leg uses the reserved [kOneWayTint] with a GO / RET label so it matches the
/// grid's leg badge.
class _TripBadge extends StatelessWidget {
  final TripType tripType;
  final UgamColorSet c;

  const _TripBadge({required this.tripType, required this.c});

  @override
  Widget build(BuildContext context) {
    final oneWay = tripType.isOneWay;
    final label = !oneWay
        ? 'RT'
        : (tripType.usesReturn && !tripType.usesOutbound ? 'RET' : 'GO');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: oneWay ? kOneWayTint : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        border: oneWay ? null : Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: UgamText.micro.copyWith(
          // Dark ground on the bright cyan; muted ink on the neutral pill.
          color: oneWay ? c.bg : c.ink2,
          fontSize: 8,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ─── Leg-shared chooser sheet ───────────────────────────────────────────

/// A chooser for a leg-shared seat: lists the GO occupant and the RETURN
/// occupant, each with phone + a Call button, so the handler picks whom to
/// collect from / call before the collect sheet opens.
class _LegSharedChooserSheet extends StatelessWidget {
  final String seatId;
  final Passenger? go;
  final Passenger? ret;
  final ValueChanged<Passenger> onPick;

  const _LegSharedChooserSheet({
    required this.seatId,
    required this.go,
    required this.ret,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Two passengers share this seat across legs. Pick one to view or '
          'collect.',
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (go != null)
          _LegSharedTile(
            passenger: go!,
            leg: TripType.outboundOnly,
            onPick: () => onPick(go!),
            c: c,
          ),
        if (go != null && ret != null) const SizedBox(height: UgamSpacing.sm),
        if (ret != null)
          _LegSharedTile(
            passenger: ret!,
            leg: TripType.returnOnly,
            onPick: () => onPick(ret!),
            c: c,
          ),
      ],
    );
  }
}

class _LegSharedTile extends StatelessWidget {
  final Passenger passenger;
  final TripType leg;
  final VoidCallback onPick;
  final UgamColorSet c;

  const _LegSharedTile({
    required this.passenger,
    required this.leg,
    required this.onPick,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    return GestureDetector(
      onTap: onPick,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            _TripBadge(tripType: leg, c: c),
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
                    hasPhone ? p.phone : 'No mobile',
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(
                        color: hasPhone ? c.ink2 : c.ink3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (hasPhone) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: 'Call ${p.phone}',
                child: GestureDetector(
                  onTap: () => PhoneDialer.call(p.phone),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.call_rounded, size: 17, color: c.accent),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
      ),
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
