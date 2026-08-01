import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../components/chart_seat_tile.dart';
import '../components/combined_seat_grid.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/seat_layout.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/seat_chart_booking_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/chart_seat_availability.dart';
import '../utils/chart_selection.dart';
import '../utils/formatters.dart';
import 'seat_booking_confirm_screen.dart';

/// Customer seat chart — the tap-a-seat flow.
///
/// *** THE LEG COMES FIRST, ON PURPOSE ***
/// The customer picks Round trip / Go only / Return only BEFORE the chart is
/// drawn, and the chart is then filtered for that leg. Every real system works
/// this way — QwikBus's segment "seat sharing", Turnit's O&D inventory,
/// redBus's route-scoped seat layout — because it makes "open" always mean
/// "open for you". Painting per-leg state onto a tile has no precedent
/// anywhere, and is the same mistake as putting a leg chip on the admin tile.
///
/// Availability is POLLED, not realtime: `passengers` has no anon SELECT policy
/// (deliberately — it would leak the roster of any public tour), so an
/// anonymous customer cannot subscribe. A stale chart is harmless because
/// `chart_claim_seats` re-validates every seat inside an advisory lock; the
/// loser gets a clean conflict rather than a double booking.
class SeatSelectionScreen extends StatefulWidget {
  final Tour tour;

  const SeatSelectionScreen({super.key, required this.tour});

  @override
  State<SeatSelectionScreen> createState() => _SeatSelectionScreenState();
}

class _SeatSelectionScreenState extends State<SeatSelectionScreen> {
  final _service = SeatChartBookingService();

  static const _maxSeats = 6; // matches the server-side cap in migration 048
  static const _pollEvery = Duration(seconds: 20);

  bool _loading = true;
  String? _error;

  List<Bus> _buses = const [];
  Map<String, SeatAvailability> _availability = const {};
  Timer? _poll;

  TripType _leg = TripType.roundTrip;
  int _busIndex = 0;

  /// seatId -> berths taken of that cell, for the CURRENT bus only. A claim is
  /// per bus (one `p_bus_id`), so a selection never spans two.
  final Map<String, int> _picks = {};

  Bus? get _bus => _buses.isEmpty ? null : _buses[_busIndex.clamp(0, _buses.length - 1)];

  /// Whether this tour actually has a return leg to sell.
  bool get _hasReturn => widget.tour.returnDate != null;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(_pollEvery, (_) => _refreshAvailability());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final buses = await _service.tourBuses(widget.tour.id);
      final avail = await _service.availability(widget.tour.id);
      if (!mounted) return;
      setState(() {
        _buses = buses;
        _availability = avail;
        _loading = false;
        if (buses.isEmpty) _error = tr('seat_pick.err_no_bus');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = tr('seat_pick.err_load');
      });
    }
  }

  Future<void> _refreshAvailability() async {
    try {
      final avail = await _service.availability(widget.tour.id);
      if (!mounted) return;
      setState(() => _availability = avail);
    } catch (_) {
      // A failed poll is not worth interrupting a selection for — the claim
      // re-validates server-side anyway.
    }
  }

  SeatAvailability? _occupancyFor(String seatId) {
    final b = _bus;
    if (b == null) return null;
    return _availability[SeatAvailability.keyFor(b.id, seatId)];
  }

  int get _selectedBerths =>
      _picks.values.fold(0, (sum, n) => sum + n);

  /// Tapping cycles through how much of a cell you're taking.
  ///
  /// A single berth is a plain on/off. A double sofa goes 1 -> 2 -> off, so a
  /// solo traveller can take HALF a sofa and share it. That is the market
  /// default, not an edge case: Bitla had to ship a dedicated COVID feature to
  /// BLOCK the second half, which you only build if it otherwise sells.
  void _tapSeat(SeatCell cell) {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final occ = _occupancyFor(seatId);
    final free = freeBerths(cell: cell, occupancy: occ, leg: _leg);
    if (free <= 0) return; // taken or held back — not tappable

    final current = _picks[seatId] ?? 0;
    final capacity = berthsOfCell(cell);
    final maxHere = free < capacity ? free : capacity;

    setState(() {
      if (current >= maxHere) {
        _picks.remove(seatId);
        return;
      }
      final next = current + 1;
      if (_selectedBerths - current + next > _maxSeats) {
        AppSnackBar.warning(
          tr('seat_pick.warn_max', namedArgs: {'n': '$_maxSeats'}),
        );
        return;
      }
      _picks[seatId] = next;
    });
  }

  /// Price of the current selection, in rupees, using the SAME function the
  /// organiser bills from — so the quote can never drift from the invoice.
  double get _total {
    final b = _bus;
    final layout = b?.layout;
    if (b == null || layout == null) return 0;
    var sum = 0.0;
    for (final entry in _picks.entries) {
      final cell = layout.grid.firstWhere(
        (c) => c.seatId == entry.key,
        orElse: () => const SeatCell(row: 0, col: 0),
      );
      if (!cell.hasSeat) continue;
      sum += b.berthPriceFor(cell.seatType!, cell.row) *
          entry.value *
          Bus.tripFactor(_leg);
    }
    return sum;
  }

  /// What one whole berth costs on this bus, for the leg pills. Uses the
  /// cheapest cell so the pill reads as a "from" price rather than promising
  /// the dearest berth.
  double _fromPriceFor(TripType leg) {
    final b = _bus;
    final layout = b?.layout;
    if (b == null || layout == null) return 0;
    double? min;
    for (final c in layout.grid) {
      if (!c.hasSeat || c.reserved) continue;
      final p = b.berthPriceFor(c.seatType!, c.row) * Bus.tripFactor(leg);
      if (min == null || p < min) min = p;
    }
    return min ?? 0;
  }

  List<ChartPick> get _chartPicks {
    final layout = _bus?.layout;
    if (layout == null) return const [];
    final out = <ChartPick>[];
    for (final e in _picks.entries) {
      final cell = layout.grid.firstWhere(
        (c) => c.seatId == e.key,
        orElse: () => const SeatCell(row: 0, col: 0),
      );
      if (cell.hasSeat) out.add(ChartPick(cell: cell, berths: e.value));
    }
    return out;
  }

  Future<void> _continue() async {
    final b = _bus;
    if (b == null || _picks.isEmpty) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SeatBookingConfirmScreen(
          tour: widget.tour,
          bus: b,
          leg: _leg,
          picks: _chartPicks,
          totalRupees: _total,
        ),
      ),
    );
    if (!mounted) return;
    if (result == true) {
      // Booked — leave the chart entirely.
      Navigator.of(context).pop(true);
    } else {
      // Came back (cancelled, or lost a seat to someone else). Re-read the
      // chart so a lost berth is visible immediately.
      _picks.clear();
      await _refreshAvailability();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              showBack: true,
              title: tr('seat_pick.title'),
            ),
            Expanded(child: _body(c)),
          ],
        ),
      ),
      bottomNavigationBar: _picks.isEmpty ? null : _footer(c),
    );
  }

  Widget _body(UgamColorSet c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: UgamText.body.copyWith(color: c.ink2),
              ),
              const SizedBox(height: UgamSpacing.md),
              UgamButton(
                label: tr('seat_pick.retry'),
                kind: UgamButtonKind.neutral,
                onPressed: _load,
              ),
            ],
          ),
        ),
      );
    }

    final bus = _bus!;
    final layout = bus.layout!;

    return RefreshIndicator(
      onRefresh: _refreshAvailability,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.sm,
          UgamSpacing.gutter,
          UgamSpacing.xl,
        ),
        children: [
          if (_hasReturn) ...[
            _legPills(c),
            const SizedBox(height: UgamSpacing.md),
          ],
          if (_buses.length > 1) ...[
            _busTabs(c),
            const SizedBox(height: UgamSpacing.md),
          ],
          _deck(c, bus, layout),
          const SizedBox(height: UgamSpacing.md),
          _legend(c),
        ],
      ),
    );
  }

  Widget _legPills(UgamColorSet c) {
    Widget pill(TripType leg, String label) {
      final on = _leg == leg;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _leg = leg;
            _picks.clear(); // availability differs per leg
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
            decoration: BoxDecoration(
              color: on ? c.accent : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: on ? null : Border.all(color: c.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: UgamText.caption.copyWith(
                    color: on ? c.onAccent : c.ink2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  Formatters.formatMoneyInr(_fromPriceFor(leg)),
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(
                      color: on
                          ? c.onAccent.withValues(alpha: 0.75)
                          : c.ink3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(TripType.roundTrip, tr('seat_pick.leg_round')),
        const SizedBox(width: UgamSpacing.xs),
        pill(TripType.outboundOnly, tr('seat_pick.leg_go')),
        const SizedBox(width: UgamSpacing.xs),
        pill(TripType.returnOnly, tr('seat_pick.leg_return')),
      ],
    );
  }

  Widget _busTabs(UgamColorSet c) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < _buses.length; i++) ...[
            GestureDetector(
              onTap: () => setState(() {
                _busIndex = i;
                _picks.clear(); // a claim is per bus
              }),
              child: Container(
                margin: const EdgeInsets.only(right: UgamSpacing.xs),
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: i == _busIndex ? c.cardElev : Colors.transparent,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                  border: Border.all(
                    color: i == _busIndex ? c.ink3 : c.border,
                  ),
                ),
                child: Text(
                  _buses[i].name,
                  style: UgamText.caption.copyWith(
                    color: i == _busIndex ? c.ink : c.ink2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deck(UgamColorSet c, Bus bus, BusLayout layout) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: CombinedSeatGrid(
        layout: layout,
        cellWidth: 44,
        cellHeight: 46,
        tileBuilder: (ctx, cell) {
          final seatId = cell.seatId;
          final tile = ChartSeatTile(
            cell: cell,
            occupancy: seatId == null ? null : _occupancyFor(seatId),
            leg: _leg,
            selectedBerths: seatId == null ? 0 : (_picks[seatId] ?? 0),
          );
          if (!cell.hasSeat) return tile;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _tapSeat(cell),
            child: tile,
          );
        },
      ),
    );
  }

  Widget _legend(UgamColorSet c) {
    Widget item(Color bg, Color? border, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(5),
                border: border != null ? Border.all(color: border) : null,
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
          ],
        );

    return Wrap(
      spacing: UgamSpacing.md,
      runSpacing: UgamSpacing.xs,
      children: [
        item(c.cardElev, c.border, tr('seat_pick.legend_open')),
        item(c.accent, null, tr('seat_pick.legend_yours')),
        item(c.bg, c.border, tr('seat_pick.legend_taken')),
        item(c.warmFill, null, tr('seat_pick.legend_lady')),
      ],
    );
  }

  Widget _footer(UgamColorSet c) {
    return UgamStickyCTA(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
            child: Row(
              children: [
                Text(
                  _selectedBerths == 1
                      ? tr('seat_pick.berth_one')
                      : tr('seat_pick.berth_many',
                          namedArgs: {'n': '$_selectedBerths'}),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
                const Spacer(),
                Text(
                  Formatters.formatMoneyInr(_total),
                  style: UgamText.tabular(
                    UgamText.titleS.copyWith(color: c.ink),
                  ),
                ),
              ],
            ),
          ),
          UgamCTA(
            label: tr('seat_pick.continue'),
            leadingIcon: Icons.arrow_forward_rounded,
            onPressed: _continue,
          ),
        ],
      ),
    );
  }
}
