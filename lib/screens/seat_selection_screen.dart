import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../components/chart_seat_skeleton.dart';
import '../components/chart_seat_tile.dart';
import '../components/combined_seat_grid.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/seat_chart_booking_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/chart_seat_availability.dart';
import '../utils/chart_basket.dart';
import '../utils/chart_selection.dart';
import '../utils/formatters.dart';
import '../utils/party_fit.dart';
import '../utils/seat_autopick.dart';
import '../widgets/chart_summary_bar.dart';
import '../widgets/sofa_share_sheet.dart';
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

  /// Data sources, injectable so the chart can be widget-tested without a
  /// network. Both default to the real RPC-backed service.
  final Future<List<Bus>> Function(String tourId)? loadBuses;
  final Future<Map<String, SeatAvailability>> Function(String tourId)?
      loadAvailability;

  /// What the customer told the party gate. Defaults to a solo traveller so
  /// every existing entry point into the chart (deep link, tour list, tour
  /// detail) keeps working untouched.
  final PartyIntent intent;

  const SeatSelectionScreen({
    super.key,
    required this.tour,
    this.loadBuses,
    this.loadAvailability,
    this.intent = PartyIntent.solo,
  });

  @override
  State<SeatSelectionScreen> createState() => _SeatSelectionScreenState();
}

class _SeatSelectionScreenState extends State<SeatSelectionScreen> {
  final _service = SeatChartBookingService();

  /// Booking cap, counted in BERTHS (people), not cells.
  ///
  /// Migration 048 caps `jsonb_array_length(p_seats) > 6`, which counts CELLS —
  /// so a direct RPC call could book six DOUBLES, i.e. twelve berths. The app
  /// cannot reach that because this cap is stricter, but the two are not the
  /// same rule and should not be described as if they were.
  static const _maxSeats = 6;
  static const _pollEvery = Duration(seconds: 20);

  bool _loading = true;
  String? _error;

  List<Bus> _buses = const [];
  Map<String, SeatAvailability> _availability = const {};
  Timer? _poll;

  TripType _leg = TripType.roundTrip;
  int _busIndex = 0;

  /// The selection, keyed by bus.
  ///
  /// This used to be a flat `seatId -> berths` map that was CLEARED on every
  /// bus-tab change, because a claim took one `p_bus_id`. Migration 068 added a
  /// multi-bus claim, so a party willing to split can now hold seats on two
  /// buses at once and check out in one all-or-nothing transaction.
  final ChartBasket _basket = ChartBasket();

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
      final buses = await (widget.loadBuses ?? _service.tourBuses)(
        widget.tour.id,
      );
      final avail = await (widget.loadAvailability ?? _service.availability)(
        widget.tour.id,
      );
      if (!mounted) return;
      setState(() {
        _buses = buses;
        _availability = avail;
        _loading = false;
        if (buses.isEmpty) _error = tr('seat_pick.err_no_bus');
      });
      _prefill();
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
      final avail = await (widget.loadAvailability ?? _service.availability)(
        widget.tour.id,
      );
      if (!mounted) return;
      // Only rebuild when occupancy actually moved. Polling every 20s and
      // calling setState regardless rebuilt the whole grid on a quiet tour for
      // nothing — and a rebuild mid-tap is exactly when a jump is noticed.
      if (availabilityEquals(_availability, avail)) return;
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

  /// True once the picker has run and found nothing. Drives the summary bar's
  /// "no room" line, so an empty chart explains itself instead of looking broken.
  bool _noRoom = false;

  /// Run the picker and put its answer straight into the basket.
  ///
  /// THE POINT OF THE WHOLE REDESIGN: the chart opens ALREADY ANSWERED. Facing
  /// 36 unlabelled cells and being asked to solve them is what defeated
  /// non-technical customers — not the styling.
  ///
  /// Only ever runs on first load. A poll must never yank seats out from under
  /// a customer who has started adjusting them.
  void _prefill() {
    if (_prefilled || _buses.isEmpty) return;
    _prefilled = true;

    final proposed = autoPick(
      buses: _buses,
      availability: _availability,
      leg: _leg,
      people: widget.intent.people,
      shareOk: widget.intent.shareOk,
    );

    setState(() {
      _noRoom = proposed.isEmpty;
      for (final selection in proposed) {
        for (final pick in selection.picks) {
          _basket.setBerths(
            busId: selection.bus.id,
            seatId: pick.seatId,
            berths: pick.berths,
          );
        }
      }
    });
  }

  bool _prefilled = false;

  /// Berths picked across EVERY bus — what the cap and the footer count.
  int get _selectedBerths => _basket.totalBerths;

  /// Lower berths in the current selection, for the summary line. This is what
  /// makes the picker's silent lower-berth preference visible — and it is why
  /// the gate could drop the "any elders?" question.
  int get _selectedLowerBerths {
    var n = 0;
    for (final bus in _buses) {
      final layout = bus.layout;
      if (layout == null) continue;
      for (final entry in _basket.forBus(bus.id).entries) {
        final cell = layout.grid.firstWhere(
          (c) => c.seatId == entry.key,
          orElse: () => const SeatCell(row: 0, col: 0),
        );
        if (cell.position == SeatPosition.lower) n += entry.value;
      }
    }
    return n;
  }

  /// Names of the buses the selection touches, in tab order.
  List<String> get _selectedBusNames => [
        for (final bus in _buses)
          if (_basket.forBus(bus.id).isNotEmpty) bus.name,
      ];

  /// What one berth of [cell] costs on [bus], adjusted for the chosen leg.
  double _berthPrice(Bus bus, SeatCell cell) =>
      bus.berthPriceFor(cell.seatType!, cell.row) * Bus.tripFactor(_leg);

  /// Berths picked on the bus currently on screen.
  int _berthsOn(String seatId) {
    final b = _bus;
    if (b == null) return 0;
    return _basket.berthsFor(busId: b.id, seatId: seatId);
  }

  /// Tapping cycles through how much of a cell you're taking.
  ///
  /// A single berth is a plain on/off. A double sofa goes 1 -> 2 -> off, so a
  /// solo traveller can take HALF a sofa and share it. That is the market
  /// default, not an edge case: Bitla had to ship a dedicated COVID feature to
  /// BLOCK the second half, which you only build if it otherwise sells.
  Future<void> _tapSeat(SeatCell cell) async {
    final seatId = cell.seatId;
    final bus = _bus;
    if (seatId == null || bus == null) return;
    final occ = _occupancyFor(seatId);
    final free = freeBerths(cell: cell, occupancy: occ, leg: _leg);
    if (free <= 0) return; // taken or held back — not tappable

    final current = _basket.berthsFor(busId: bus.id, seatId: seatId);
    HapticFeedback.selectionClick();

    // Already ours — one tap gives it back. True for every seat type, so
    // undoing is the one gesture that never needs explaining.
    if (current > 0) {
      setState(() => _basket.setBerths(busId: bus.id, seatId: seatId, berths: 0));
      return;
    }

    final capacity = berthsOfCell(cell);
    int wanted;

    if (capacity == 2) {
      // *** THE CHANGE THAT MATTERS ***
      // This used to be a hidden cycle: one tap silently took HALF the sofa,
      // committing the customer to sleeping beside a stranger, and a second tap
      // took it whole. Nobody discovers that. Now it is asked, in words, with
      // both prices, before any money moves.
      final canTakeHalf = widget.intent.shareOk && free >= 1;
      final canTakeWhole = free >= 2;
      if (!canTakeHalf && !canTakeWhole) return;

      if (canTakeWhole && !canTakeHalf) {
        // Only one honest option — do not spend a sheet asking a question with
        // a single answer.
        wanted = 2;
      } else {
        final choice = await showSofaShareSheet(
          context,
          halfPrice: _berthPrice(bus, cell),
          canTakeWhole: canTakeWhole,
          canTakeHalf: canTakeHalf,
          someoneAlreadyThere: free < capacity,
        );
        if (choice == null || !mounted) return; // dismissed — book nothing
        wanted = choice;
      }
    } else {
      wanted = 1;
    }

    if (wanted > free) return;

    // The cap spans the WHOLE basket, not just this bus — otherwise a party
    // could take six berths on each of two buses.
    if (_selectedBerths + wanted > _maxSeats) {
      AppSnackBar.warning(
        tr('seat_pick.warn_max', namedArgs: {'n': '$_maxSeats'}),
      );
      return;
    }

    setState(
      () => _basket.setBerths(busId: bus.id, seatId: seatId, berths: wanted),
    );
  }

  /// Price of the current selection, in rupees, using the SAME function the
  /// organiser bills from — so the quote can never drift from the invoice.
  /// Totals across EVERY bus in the basket, each seat priced by its own bus —
  /// two buses on one tour can carry different fares, so pricing a split party
  /// off the visible bus alone would misquote them.
  double get _total {
    var sum = 0.0;
    for (final bus in _buses) {
      final layout = bus.layout;
      if (layout == null) continue;
      for (final entry in _basket.forBus(bus.id).entries) {
        final cell = layout.grid.firstWhere(
          (c) => c.seatId == entry.key,
          orElse: () => const SeatCell(row: 0, col: 0),
        );
        if (!cell.hasSeat) continue;
        sum += bus.berthPriceFor(cell.seatType!, cell.row) *
            entry.value *
            Bus.tripFactor(_leg);
      }
    }
    return sum;
  }

  /// What one whole berth costs on this bus, for the leg pills. Uses the
  /// cheapest cell so the pill reads as a "from" price rather than promising
  /// the dearest berth.
  ///
  /// Delegates to [Bus.fromBerthPrice] — the same function the public tour page
  /// quotes from, so the "from ₹X" a customer saw before opening the chart is
  /// the one they see on the leg pills. Keeps the 0 fallback this call site
  /// already relied on.
  double _fromPriceFor(TripType leg) => _bus?.fromBerthPrice(leg) ?? 0;

  List<ChartPick> _picksFor(Bus bus) {
    final layout = bus.layout;
    if (layout == null) return const [];
    final out = <ChartPick>[];
    for (final e in _basket.forBus(bus.id).entries) {
      final cell = layout.grid.firstWhere(
        (c) => c.seatId == e.key,
        orElse: () => const SeatCell(row: 0, col: 0),
      );
      if (cell.hasSeat) out.add(ChartPick(cell: cell, berths: e.value));
    }
    return out;
  }

  /// Every bus the customer has picked something on, in tab order.
  List<ChartBusSelection> get _selections => [
        for (final bus in _buses)
          if (_basket.forBus(bus.id).isNotEmpty)
            ChartBusSelection(bus: bus, picks: _picksFor(bus)),
      ];

  Future<void> _continue() async {
    final selections = _selections;
    if (selections.isEmpty) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SeatBookingConfirmScreen(
          tour: widget.tour,
          leg: _leg,
          selections: selections,
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
      _basket.clear();
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
      // Slides up on the first pick rather than snapping into existence. The
      // AnimatedSize keeps the scroll view's bottom inset in step with it, so
      // the chart does not jump when the bar appears.
      bottomNavigationBar: AnimatedSize(
        duration: UgamMotion.sheet,
        curve: UgamMotion.easeOut,
        alignment: Alignment.topCenter,
        child: _basket.isEmpty
            // NOT a zero-height box: Scaffold strips the body's bottom padding
            // whenever bottomNavigationBar is non-null, whether or not the bar
            // has height. Reserving the system inset here gives that padding
            // back in the empty-basket state — which is the entire first-use
            // state of the customer booking flow.
            ? SizedBox(
                width: double.infinity,
                height: MediaQuery.paddingOf(context).bottom,
              )
            : _footer(c),
      ),
    );
  }

  /// The scroll shell both the loading and loaded frames use.
  ///
  /// Sharing it is the point: the screen used to render a bare centred spinner
  /// and then swap in a whole ListView + grid once the RPC landed, usually
  /// while the push transition was still animating. The body's structure
  /// changed underneath the animation, which is what read as a janky push.
  Widget _scrollShell({required List<Widget> children}) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      children: children,
    );
  }

  Widget _body(UgamColorSet c) {
    if (_loading) {
      return _scrollShell(
        children: [
          if (_hasReturn) ...[
            _legPills(c),
            const SizedBox(height: UgamSpacing.md),
          ],
          const ChartSeatSkeleton(),
        ],
      );
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
      child: _scrollShell(
        children: [
          if (_hasReturn) ...[
            _legPills(c),
            const SizedBox(height: UgamSpacing.md),
          ],
          if (_buses.length > 1) ...[
            _busTabs(c),
            const SizedBox(height: UgamSpacing.md),
          ],
          _summaryBar(),
          const SizedBox(height: UgamSpacing.md),
          _deck(c, bus, layout),
          const SizedBox(height: UgamSpacing.md),
          _legend(c),
        ],
      ),
    );
  }

  Widget _legPills(UgamColorSet c) {
    // Deliberately NOT UgamSelectorPills: that control is single-line and would
    // drop the "from" price, which is the most useful thing on this row.
    //
    // The active pill is TONAL (accentFill + accent ink), not solid champagne.
    // Solid gold is rationed to the one focal CTA per screen — and this screen
    // already spends it on Continue, so a solid pill put two of them on screen.
    Widget pill(TripType leg, String label) {
      final on = _leg == leg;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (on) return;
            HapticFeedback.selectionClick();
            setState(() {
              _leg = leg;
              // Availability is leg-scoped, so a selection made for one leg
              // means nothing on another — this clear is still correct.
              _basket.clear();
            });
          },
          child: AnimatedContainer(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
            decoration: BoxDecoration(
              color: on ? c.accentFill : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(
                color: on ? c.accent.withValues(alpha: 0.32) : c.border,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  style: UgamText.caption.copyWith(
                    color: on ? c.accent : c.ink2,
                    fontWeight: FontWeight.w700,
                  ),
                  child: Text(label),
                ),
                AnimatedDefaultTextStyle(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(color: on ? c.accent : c.ink3),
                  ),
                  child: Text(Formatters.formatMoneyInr(_fromPriceFor(leg))),
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

  /// The sentence above the map.
  ///
  /// A seat map answers "which cells exist"; a customer arrives asking "are we
  /// sorted, together, and what does it cost?". That is a sentence, not a
  /// diagram — so it gets said, in words, above the deck.
  Widget _summaryBar() {
    return ChartSummaryBar(
      people: widget.intent.people,
      pickedBerths: _selectedBerths,
      lowerBerths: _selectedLowerBerths,
      total: _total,
      busNames: _selectedBusNames,
      noRoom: _noRoom && _basket.isEmpty,
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
                // Deliberately does NOT clear: the basket is per bus, so
                // switching tabs now keeps what was picked on the other bus.
                // That is the whole point of the multi-bus checkout.
                _busIndex = i;
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
            selectedBerths: seatId == null ? 0 : _berthsOn(seatId),
            // Band pricing used to be invisible until the footer total moved.
            berthPrice: cell.hasSeat ? _berthPrice(bus, cell) : null,
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
