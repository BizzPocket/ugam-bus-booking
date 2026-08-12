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

  /// Everything above the map: the leg tabs, the bus tabs and the sentence.
  ///
  /// Lifted OUT of the scroll view so the map below can be handed a bounded
  /// height. These three are short and fixed; the map is the thing that should
  /// absorb whatever height is left.
  Widget _headerBlock(UgamColorSet c, {required bool showSummary}) {
    final items = <Widget>[
      if (_tabs.length >= 2) _legTabs(c),
      if (_buses.length > 1) _busTabs(c),
      if (showSummary) _summaryBar(),
    ];
    if (items.isEmpty) return const SizedBox(height: UgamSpacing.sm);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: UgamSpacing.md),
            items[i],
          ],
        ],
      ),
    );
  }

  /// Which maps this party actually needs. A round-trip or go-only party fills
  /// the GO map; a return-only party fills the RETURN map. A party needing only
  /// one sees no strip at all.
  ///
  /// The tour having a return leg is folded in here rather than guarding the
  /// call site: without one there is no return map to show, whatever the intent
  /// says. One condition, one place.
  List<TripType> get _tabs {
    final go = widget.intent.roundTrip + widget.intent.outboundOnly > 0;
    final ret = widget.intent.returnOnly > 0 && _hasReturn;
    return [
      if (go) TripType.roundTrip,
      if (ret) TripType.returnOnly,
    ];
  }

  /// The two maps a mixed party moves between.
  ///
  /// These used to be leg PILLS that chose what the booking was, and switching
  /// one wiped the basket. Now the leg lives on each seat, so this is a view
  /// filter: it changes which map you are looking at and nothing else.
  ///
  /// The active tab is TONAL (accentFill + accent ink), not solid champagne.
  /// Solid gold is rationed to the one focal CTA per screen, which this screen
  /// already spends on Continue.
  Widget _legTabs(UgamColorSet c) {
    final tabs = _tabs;
    if (tabs.length < 2) return const SizedBox.shrink();

    Widget tab(TripType leg, Key key, String label) {
      final on = _viewLeg == leg;
      return Expanded(
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          // NOTE: no basket mutation here. That is the whole change.
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _viewLeg = leg);
          },
          child: AnimatedContainer(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            height: UgamScale.tap(context, 44),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? c.accentFill : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(
                color: on ? c.accent.withValues(alpha: 0.32) : c.border,
              ),
            ),
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: on ? c.accent : c.ink2),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(
          TripType.roundTrip,
          SeatSelectionScreen.goTabKey,
          tr('seat_pick.tab_go'),
        ),
        const SizedBox(width: UgamSpacing.sm),
        tab(
          TripType.returnOnly,
          SeatSelectionScreen.returnTabKey,
          tr('seat_pick.tab_return'),
        ),
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
      shortfall: _shortfall,
    );
  }

  Widget _busTabs(UgamColorSet c) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < _buses.length; i++) ...[
            GestureDetector(
              // The chip stays a chip; the HIT BOX around it is padded out to
              // the 44pt minimum, which the bare pill (≈24pt tall) missed.
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {
                // Deliberately does NOT clear: the basket is per bus, so
                // switching tabs now keeps what was picked on the other bus.
                // That is the whole point of the multi-bus checkout.
                _busIndex = i;
              }),
              child: SizedBox(
                height: UgamScale.tap(context, 44),
                child: Center(
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
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Height [CombinedSeatGrid] spends ABOVE its first row — the driver strip,
  /// its gap, the divider and the gap under it.
  ///
  /// Deliberately generous. It only feeds the "how much room does the map
  /// need" estimate below, and over-estimating costs a hair of growth while
  /// under-estimating would let the fit shrink a tall chart.
  static const double _gridChrome =
      UgamSpacing.xxl + UgamSpacing.sm + UgamSpacing.md + 1;

  /// The gap between seat slots, both axes.
  static const double _seatGap = UgamSpacing.sm;

  /// How far the map may be blown up past its natural size.
  ///
  /// Capped for two reasons: past this the seats stop reading as a bus and
  /// start reading as a keypad, and the grid's own chrome — the driver strip
  /// and the divider under it — needs real width to lay out in.
  static const double _maxMapGrowth = 1.35;

  /// Rows of the layout that actually carry a seat — what the grid draws.
  int _seatRowCount(BusLayout layout) {
    final rows = <int>{};
    for (final cell in layout.grid) {
      if (cell.hasSeat) rows.add(cell.row);
    }
    return rows.isEmpty ? 1 : rows.length;
  }

  /// Slots in the widest row the grid will draw.
  ///
  /// A normal row is the used lane columns plus the aisle; the back bench packs
  /// its berths flat with no aisle gap, so it can be one slot wider. Mirrors
  /// [CombinedSeatGrid]'s own placement rules — get this wrong and the map is
  /// merely scaled a little differently, never broken.
  int _widestRowSlots(BusLayout layout) {
    final lanes = <int>{};
    for (final cell in layout.grid) {
      if (cell.hasSeat && cell.col != SeatGridCols.aisle) lanes.add(cell.col);
    }
    final hasLeft = lanes.contains(SeatGridCols.singleUpper) ||
        lanes.contains(SeatGridCols.singleLower);
    final hasRight = lanes.contains(SeatGridCols.doubleUpper) ||
        lanes.contains(SeatGridCols.doubleLower);
    var widest = lanes.length + (hasLeft && hasRight ? 1 : 0);
    for (var r = 0; r < layout.rows; r++) {
      final pair = layout.balconyPair(r);
      if (!pair.upper.hasSeat && !pair.lower.hasSeat) continue;
      final n = layout.cellsInRow(r).length;
      if (n > widest) widest = n;
    }
    return widest < 1 ? 1 : widest;
  }

  /// The seat map. [width] and [height] are the card's inner content box,
  /// measured by the caller.
  ///
  /// *** TWO BUGS LIVED IN THE OLD THREE LINES OF GEOMETRY ***
  ///
  /// 1. BADGE BLEED. Every tile is pinned to [ChartSeatMetrics] (56x52) and the
  ///    grid drops it into its slot through a `BoxFit.scaleDown` fit. The slot
  ///    was 44x46 — SMALLER than the tile — so each tile was squeezed to
  ///    44x40.9 and sat flush against its slot's edges. A corner badge or a
  ///    Gujarati label whose matras overshoot the line box then had nowhere to
  ///    go but onto the row above. The slot is now the tile PLUS a reserved
  ///    margin, so a tile can never reach a neighbour across that margin and
  ///    the [_seatGap] between slots.
  ///
  /// 2. THE SCREEN ENDING AT 60%. The grid fits its rows with
  ///    `BoxFit.scaleDown`, which never grows, so a short chart drew at its
  ///    natural size at the top of the viewport and left the rest blank. Given
  ///    a bounded height it is now scaled UP to fill it — the seats were the
  ///    thing worth spending that space on, being both the tap target and the
  ///    thing being read.
  ///
  /// Growth is one `BoxFit.contain` rather than a bigger slot, because a bigger
  /// slot cannot make a tile bigger: the tile's own size is a const in
  /// [ChartSeatMetrics], and the grid only ever scales it DOWN into the slot.
  Widget _deck(
    UgamColorSet c,
    Bus bus,
    BusLayout layout, {
    required double width,
    required double height,
  }) {
    final e = UgamElevation.of(context);

    // Slot = tile + reserved margin, floored at the 44pt tap minimum.
    final slotW =
        UgamScale.tap(context, ChartSeatMetrics.width + UgamSpacing.xs);
    final slotH =
        UgamScale.tap(context, ChartSeatMetrics.height + UgamSpacing.sm);

    final rows = _seatRowCount(layout);
    final cols = _widestRowSlots(layout);
    final naturalW = cols * slotW + (cols - 1) * _seatGap;
    final naturalH = rows * slotH + (rows - 1) * _seatGap + _gridChrome;

    // Both floored at the map's own natural size, so a degenerate (or, for
    // height, unbounded) region can only ever mean "do not grow".
    final availW = math.max(width, naturalW);
    final availH = height.isFinite ? height : naturalH;
    final grow =
        math.min(availW / naturalW, availH / naturalH).clamp(1.0, _maxMapGrowth);

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
        // Level 1: the map is a plane lifted off the page, not a grey rectangle
        // painted on it. The legend rail below stays flush, so the two read as
        // two surfaces.
        boxShadow: e.rest,
      ),
      child: SizedBox(
        width: double.infinity,
        // Taller than the region only when the chart genuinely needs it, which
        // is what makes a long bus scroll instead of being shrunk to fit.
        height: math.max(availH, naturalH * grow),
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          child: SizedBox(
            // Pre-divided by the scale the fit is about to apply, so the grid
            // still lays out against the FULL content width. Cutting the box
            // to the seat rows alone starves the grid's own chrome — the
            // driver strip overflows and the divider under it collapses to
            // nothing.
            width: availW / grow,
            child: _grid(bus, layout, slotW, slotH),
          ),
        ),
      ),
    );
  }

  Widget _grid(Bus bus, BusLayout layout, double slotW, double slotH) {
    return CombinedSeatGrid(
      layout: layout,
      cellWidth: slotW,
      cellHeight: slotH,
      colGap: _seatGap,
      rowGap: _seatGap,
      tileBuilder: (ctx, cell) {
        final seatId = cell.seatId;
        final tile = ChartSeatTile(
          cell: cell,
          occupancy: seatId == null ? null : _occupancyFor(seatId),
          // The map being LOOKED AT drives what availability is painted.
          leg: _viewLeg,
          selectedBerths: seatId == null ? 0 : _berthsOn(seatId),
          // Band pricing used to be invisible until the footer total moved.
          berthPrice:
              cell.hasSeat ? _berthPrice(bus, cell, _bucketForTap()) : null,
          bothLegs: widget.intent.isMixed &&
              _basket
                      .entryFor(busId: bus.id, seatId: cell.seatId ?? '')
                      ?.leg ==
                  TripType.roundTrip,
        );
        if (!cell.hasSeat) return tile;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _tapSeat(cell),
          child: tile,
        );
      },
    );
  }

  /// The legend, as a rail pinned to the bottom of the screen.
  ///
  /// It is deliberately FLUSH — [UgamElevationSet.flat] — while the map above
  /// sits at rest. Two surfaces at two heights is what stops the screen reading
  /// as one flat sheet, and pinning it also gives the composition a bottom edge
  /// in the state where nothing is picked and there is no CTA yet.
  Widget _legendRail(UgamColorSet c) {
    final e = UgamElevation.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.tight,
      ),
      decoration: BoxDecoration(
        color: c.card,
        boxShadow: e.flat,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: _legend(c),
    );
  }

  Widget _legend(UgamColorSet c) {
    // Decorative swatch — it is never tapped, so px() and not tap().
    final swatch = UgamScale.px(context, UgamSpacing.lg);
    Widget item(Color bg, Color? border, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: swatch,
              height: swatch,
              decoration: BoxDecoration(
                color: bg,
                // A swatch stands for a SEAT, so it echoes the seat's corner
                // rather than becoming a dot. UgamRadius has no step this small
                // (seat = 14 on a 16px box is a circle), so the original 5 is
                // kept — see the report: the scale wants a `micro` step.
                borderRadius: BorderRadius.circular(5),
                border: border != null ? Border.all(color: border) : null,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
          ],
        );

    return Wrap(
      alignment: WrapAlignment.center,
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
                // Expanded, not a Spacer: the berth count is the one line here
                // that grows with the language and the accessibility scale, and
                // a Spacer let it push the total off the right edge instead of
                // giving way. The price must never be the thing that is lost.
                Expanded(
                  child: Text(
                    _selectedBerths == 1
                        ? tr('seat_pick.berth_one')
                        : tr('seat_pick.berth_many',
                            namedArgs: {'n': '$_selectedBerths'}),
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
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
