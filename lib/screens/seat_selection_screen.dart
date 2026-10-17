import 'dart:async';
import 'dart:math' as math;

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

part 'seat_selection/seat_selection_sections.dart';

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

  static const goTabKey = Key('chart_tab_go');
  static const returnTabKey = Key('chart_tab_return');

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

  /// WHICH MAP IS ON SCREEN — not what is being bought.
  ///
  /// This used to be the booking's trip type: changing it changed what the
  /// customer was buying AND wiped their selection. With a leg on every seat it
  /// is a view filter, and switching it must never touch the basket.
  late TripType _viewLeg = widget.intent.activeLegs.isEmpty
      ? TripType.roundTrip
      : widget.intent.activeLegs.first;
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

  /// [setState] for the section extension in `seat_selection/` — an extension
  /// is not a [State] subclass, so it may not call the protected member
  /// directly. Plain pass-through.
  void _update(VoidCallback fn) => setState(fn);

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

  /// Berths the picker could not place, PER LEG. Drives the summary bar's
  /// shortfall line, so an under-filled chart explains itself instead of
  /// looking broken.
  ///
  /// Replaces a single `_noRoom` flag, which could only say "nothing fits" —
  /// useless for a mixed party whose outbound leg is seated and whose return
  /// leg is not.
  Map<TripType, int> _shortfall = const {};

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
      intent: widget.intent,
    );

    setState(() {
      _shortfall = proposed.shortfall;
      for (final selection in proposed.selections) {
        for (final pick in selection.picks) {
          _basket.setBerths(
            busId: selection.bus.id,
            seatId: pick.seatId,
            berths: pick.berths,
            leg: pick.leg,
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
        if (cell.position == SeatPosition.lower) n += entry.value.berths;
      }
    }
    return n;
  }

  /// Names of the buses the selection touches, in tab order.
  List<String> get _selectedBusNames => [
        for (final bus in _buses)
          if (_basket.forBus(bus.id).isNotEmpty) bus.name,
      ];

  /// What one berth of [cell] costs on [bus] for [leg]. A one-way berth pays
  /// half — so a mixed basket cannot be priced off one screen-level factor.
  double _berthPrice(Bus bus, SeatCell cell, TripType leg) =>
      bus.berthPriceFor(cell.seatType!, cell.row) * Bus.tripFactor(leg);

  /// Which leg bucket the next tap on the visible map fills.
  ///
  /// On the GO map, round-trip is filled before go-only: a round-trip berth
  /// needs BOTH legs free, so it has the fewest candidates and must claim them
  /// first. The RETURN map only ever fills return-only.
  TripType _bucketForTap() {
    if (_viewLeg == TripType.returnOnly) return TripType.returnOnly;
    if (_basket.berthsForLeg(TripType.roundTrip) < widget.intent.roundTrip) {
      return TripType.roundTrip;
    }
    return TripType.outboundOnly;
  }

  /// Berths still to place in the bucket a tap would fill. Drives the sofa rule.
  int get _remainingInBucket {
    final leg = _bucketForTap();
    return widget.intent.countFor(leg) - _basket.berthsForLeg(leg);
  }

  /// Berths picked on the bus currently on screen, AS SEEN FROM THE VISIBLE MAP.
  ///
  /// A round-trip berth is one berth on both legs, so it shows on both tabs and
  /// giving it back on either releases it. A one-way berth belongs to its own
  /// map alone — showing a go-only seat as taken on the return map would claim
  /// a berth the customer never bought.
  int _berthsOn(String seatId) {
    final b = _bus;
    if (b == null) return 0;
    final entry = _basket.entryFor(busId: b.id, seatId: seatId);
    if (entry == null) return 0;
    final showsHere = _viewLeg == TripType.returnOnly
        ? entry.leg.usesReturn
        : entry.leg.usesOutbound;
    return showsHere ? entry.berths : 0;
  }

  /// Tapping a cell takes it, or gives it back.
  ///
  /// A single berth is a plain on/off. A double sofa takes both berths in one
  /// tap when the bucket being filled still needs two; when only one berth is
  /// left to place, the share sheet asks whole-or-half in words, with both
  /// prices, before any money moves. Half a sofa is the market default rather
  /// than an edge case: Bitla had to ship a dedicated COVID feature to BLOCK
  /// the second half, which you only build if it otherwise sells.
  Future<void> _tapSeat(SeatCell cell) async {
    final seatId = cell.seatId;
    final bus = _bus;
    if (seatId == null || bus == null) return;
    final occ = _occupancyFor(seatId);
    // Probed against the bucket being FILLED, not the map being looked at: a
    // round-trip berth taken from the go map needs both legs free.
    final free = freeBerths(cell: cell, occupancy: occ, leg: _bucketForTap());
    if (free <= 0) return; // taken or held back — not tappable

    // Deliberately the UNFILTERED count: a round-trip berth shown on the return
    // map is still the same berth, and one tap must give it back on both.
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
      // *** WHY THIS IS NOT ALWAYS A SHEET ***
      // A hidden tap-cycle used to commit the customer to a stranger silently;
      // replacing it with a sheet fixed that, and introduced a new cost — a
      // family taking a whole sofa answered a question whose answer the party
      // size already implied.
      //
      // The sheet now survives exactly one case: the bucket being filled has a
      // single berth left, so whole-or-half is genuinely open.
      final canTakeHalf = widget.intent.shareOk && free >= 1;
      final canTakeWhole = free >= 2;
      if (!canTakeHalf && !canTakeWhole) return;

      if (canTakeWhole && !canTakeHalf) {
        // Only one honest option — do not spend a sheet asking a question with
        // a single answer.
        wanted = 2;
      } else if (canTakeWhole && _remainingInBucket >= 2) {
        // They need both berths here. Asking would be asking nothing.
        wanted = 2;
      } else {
        final choice = await showSofaShareSheet(
          context,
          halfPrice: _berthPrice(bus, cell, _bucketForTap()),
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

    final leg = _bucketForTap();
    setState(
      () => _basket.setBerths(
        busId: bus.id,
        seatId: seatId,
        berths: wanted,
        leg: leg,
      ),
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
        // Priced off the SEAT's leg, not the screen's. A one-way berth pays
        // half, so charging a mixed basket at the visible tab's rate would
        // over- or under-quote every seat on the other leg.
        sum += bus.berthPriceFor(cell.seatType!, cell.row) *
            entry.value.berths *
            Bus.tripFactor(entry.value.leg);
      }
    }
    return sum;
  }

  List<ChartPick> _picksFor(Bus bus) {
    final layout = bus.layout;
    if (layout == null) return const [];
    final out = <ChartPick>[];
    for (final e in _basket.forBus(bus.id).entries) {
      final cell = layout.grid.firstWhere(
        (c) => c.seatId == e.key,
        orElse: () => const SeatCell(row: 0, col: 0),
      );
      if (cell.hasSeat) {
        out.add(ChartPick(cell: cell, berths: e.value.berths, leg: e.value.leg));
      }
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

  /// Lateral padding for the map region. Shared by the loading and loaded
  /// frames so the skeleton and the real deck occupy the same box — the body's
  /// structure must not change underneath the push transition, which is what
  /// used to read as a janky push.
  static const EdgeInsets _mapPad = EdgeInsets.fromLTRB(
    UgamSpacing.gutter,
    0,
    UgamSpacing.gutter,
    UgamSpacing.md,
  );

  /// *** WHY THIS IS A COLUMN AND NOT ONE LONG LIST ***
  /// The whole screen used to be a single ListView, so the map was laid out at
  /// its natural size at the TOP of an unbounded scroll view and roughly 40% of
  /// the viewport under it stayed blank. Splitting it into a fixed header, an
  /// [Expanded] map region and a pinned legend rail gives the map a BOUNDED
  /// height — which is the only thing that lets it grow into the space it has
  /// (see [_deck]) — and gives the screen a deliberate bottom edge even in the
  /// nothing-selected state, where there is no CTA yet.
  Widget _body(UgamColorSet c) {
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headerBlock(c, showSummary: false),
          Expanded(
            child: SingleChildScrollView(
              padding: _mapPad,
              child: const ChartSeatSkeleton(),
            ),
          ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerBlock(c, showSummary: true),
        Expanded(
          child: RefreshIndicator(
            // Chrome, not ownership — the pull spinner is neutral ink2 in
            // every screen, so it never changes hue between tabs. Load-bearing
            // here: the chart under it paints the accent on the seats the user
            // has picked, so an amber spinner read as a second "yours".
            // (Unset used to mean `colorScheme.primary`, i.e. the accent.)
            color: c.ink2,
            onRefresh: _refreshAvailability,
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                // Always scrollable so pull-to-refresh survives a short chart
                // that no longer overflows its region.
                physics: const AlwaysScrollableScrollPhysics(),
                padding: _mapPad,
                child: _deck(
                  c,
                  bus,
                  layout,
                  // The deck card's INNER content box: the region less the
                  // gutters/seam and the card's own padding.
                  width: box.maxWidth -
                      _mapPad.horizontal -
                      UgamSpacing.sm * 2,
                  height: box.maxHeight -
                      _mapPad.bottom -
                      UgamSpacing.sm * 2,
                ),
              ),
            ),
          ),
        ),
        _legendRail(c),
      ],
    );
  }
}
