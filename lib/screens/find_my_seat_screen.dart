import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../design/components/ugam_tappable.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/handler_tour_ref.dart';
import '../models/seat_ticket.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../utils/formatters.dart';
import 'handler/handler_shell.dart';

/// The one glyph that means "your seat on the bus", used by every surface that
/// opens this flow. Deliberately NOT `event_seat`: that bare-seat glyph is the
/// seat-chart's own vocabulary (a tile you can tap), so reusing it for the
/// entry point made the button look like chart furniture. A reclining
/// passenger reads as a person IN a seat — which is what is being looked up.
const IconData kFindMySeatIcon = Icons.airline_seat_recline_normal_rounded;

/// Digits only — the server matches on the last 10, so `+91`, spaces and
/// dashes are noise everywhere this is used.
String digitsOfPhone(String raw) => raw.replaceAll(RegExp(r'\D'), '');

/// `9876543210` → `98765 43210`. Falls back to the raw digits when there
/// aren't exactly ten, so a half-typed number still renders.
String prettyPhone(String raw) {
  final d = digitsOfPhone(raw);
  final last10 = d.length > 10 ? d.substring(d.length - 10) : d;
  if (last10.length != 10) return last10;
  return '${last10.substring(0, 5)} ${last10.substring(5)}';
}

/// "Find my seat by phone" — a booking-request-free way for ANY passenger to
/// see their seat once the organiser has locked the tour. Enter a mobile
/// number, get back every seat held under it (matched on the last 10 digits,
/// so +91 / spaces never matter) with the bus diagram and seat numbers.
///
/// This exists because passengers the agent added manually have no in-app
/// ticket (the "My Requests" view is keyed on booking_requests), so they could
/// never see their seat in the app — only via WhatsApp.
class FindMySeatScreen extends StatefulWidget {
  /// Pre-fills the number field, and runs the lookup on open when it already
  /// carries a full number. The home-screen entry passes what the rider typed
  /// there, so pressing "Find" lands on the seat rather than on a second,
  /// identical, empty form.
  final String? initialPhone;

  const FindMySeatScreen({super.key, this.initialPhone});

  @override
  State<FindMySeatScreen> createState() => _FindMySeatScreenState();
}

class _FindMySeatScreenState extends State<FindMySeatScreen> {
  final _store = CustomerRequestsStore();
  final _phoneCtrl = TextEditingController();
  final _phoneFocus = FocusNode();

  bool _searching = false;
  bool _searched = false;

  /// Once a lookup has actually found something the entry form folds away to a
  /// one-line "showing seats for …" summary: the seat diagram is the reason
  /// the rider is here, and it should not open half a screen down.
  bool _formCollapsed = false;

  /// The number the results on screen belong to — held separately from the
  /// controller so editing the field doesn't relabel results already shown.
  String _resultPhone = '';

  String? _error;
  List<SeatTicket> _tickets = const [];
  List<HandlerTourRef> _handlerTours = const [];

  @override
  void initState() {
    super.initState();
    // Post-frame, not inline: with an `initialPhone` in hand `_seedPhone`
    // reaches `_search` without ever awaiting, and `_search` touches
    // `FocusScope.of(context)` — an inherited lookup that asserts in initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedPhone());
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _phoneFocus.dispose();
    super.dispose();
  }

  /// Opens on the rider's number when we know it: the one they just typed on
  /// the home screen, else the one their last successful lookup used. A
  /// manually-added passenger has no booking in the app, so this remembered
  /// number is the only thread back to their seat — reeling it in for them is
  /// the difference between "look up my seat" and "show me my seat".
  Future<void> _seedPhone() async {
    final passed = widget.initialPhone?.trim() ?? '';
    final seed = passed.isNotEmpty
        ? passed
        : (await _store.lastSeatLookupPhone() ?? '');
    if (!mounted) return;
    if (seed.isEmpty) {
      // Nothing to go on — open on the keyboard rather than on a dead form.
      _phoneFocus.requestFocus();
      return;
    }
    _phoneCtrl.text = seed;
    if (digitsOfPhone(seed).length >= 10) {
      await _search();
    } else {
      _phoneCtrl.selection = TextSelection.collapsed(offset: seed.length);
      _phoneFocus.requestFocus();
    }
  }

  Future<void> _search() async {
    final phone = _phoneCtrl.text.trim();
    // Need enough digits to identify a number; the server matches the last 10.
    final digits = digitsOfPhone(phone);
    if (digits.length < 10) {
      setState(() => _error = tr('find_seat.error_short'));
      return;
    }
    if (mounted) FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _store.seatsByPhone(phone),
        _store.handlerRequestsByPhone(phone),
      ]);
      if (!mounted) return;
      // "Live" is keyed on lifecycle status (see [SeatTicket.isLive]), never
      // the departure date — a still-locked tour is the CURRENT trip even the
      // day after it departed, so a rider can always find their seat mid-trip.
      final tickets =
          (results[0] as List<SeatTicket>).where((t) => t.isLive).toList();
      final handlerTours =
          (results[1] as List<HandlerTourRef>).where((h) => h.isLive).toList();
      final found = tickets.isNotEmpty || handlerTours.isNotEmpty;
      setState(() {
        _tickets = tickets;
        _handlerTours = handlerTours;
        _resultPhone = phone;
        _formCollapsed = found;
        _searched = true;
        _searching = false;
      });
      // Only a number that actually resolved is worth remembering — a typo
      // must never become the one this screen opens on tomorrow.
      if (found) await _store.rememberSeatLookupPhone(phone);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr('find_seat.error_load');
        _searching = false;
      });
    }
  }

  /// Unfolds the entry form again ("Change" / "Try another number").
  void _editNumber() {
    HapticFeedback.selectionClick();
    setState(() {
      _formCollapsed = false;
      _error = null;
    });
    _phoneCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _phoneCtrl.text.length,
    );
    _phoneFocus.requestFocus();
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
              title: tr('find_seat.title'),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSize(
                      duration: UgamMotion.tab,
                      curve: UgamMotion.easeOut,
                      alignment: Alignment.topCenter,
                      child: _formCollapsed
                          ? _QueryChip(
                              c: c,
                              phone: _resultPhone,
                              onChange: _editNumber,
                            )
                          : _form(c),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    _results(c),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The number-entry form. Shown until a lookup succeeds, and again whenever
  /// the rider taps "Change" / "Try another number".
  Widget _form(UgamColorSet c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('find_seat.intro'),
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.lg),
        Container(
          padding: const EdgeInsets.all(UgamSpacing.xl),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(UgamRadius.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              UgamInput(
                label: tr('find_seat.phone_label'),
                controller: _phoneCtrl,
                focusNode: _phoneFocus,
                hint: tr('find_seat.phone_hint'),
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                ],
                // Clearing the number clears the stale "too short" complaint
                // rather than leaving it under a field being retyped.
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _search(),
              ),
              if (_error != null) ...[
                const SizedBox(height: UgamSpacing.sm),
                Text(
                  _error!,
                  style: UgamText.caption.copyWith(color: c.danger),
                ),
              ],
              const SizedBox(height: UgamSpacing.lg),
              UgamCTA(
                label: _searching
                    ? tr('find_seat.searching')
                    : tr('find_seat.find_btn'),
                leadingIcon: kFindMySeatIcon,
                loading: _searching,
                onPressed: _searching ? null : _search,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _results(UgamColorSet c) {
    if (_searching) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UgamSkeleton(height: 132, radius: UgamRadius.card),
          SizedBox(height: UgamSpacing.lg),
          UgamSkeleton(height: 132, radius: UgamRadius.card),
        ],
      );
    }
    if (!_searched) return const SizedBox.shrink();
    if (_tickets.isEmpty && _handlerTours.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: UgamSpacing.lg),
        child: UgamEmpty(
          icon: kFindMySeatIcon,
          title: tr('find_seat.empty_title'),
          body: tr('find_seat.empty_body'),
          // A dead end otherwise: the commonest cause of "no seat found" is a
          // mistyped digit, and there was nothing here to act on.
          cta: UgamCTA(
            label: tr('find_seat.try_another'),
            leadingIcon: Icons.edit_rounded,
            onPressed: _editNumber,
          ),
        ),
      );
    }

    // Map tourId -> handler requestId so a seated handler's ticket card can
    // surface the "Manage as handler" CTA inline.
    final handlerByTour = <String, HandlerTourRef>{
      for (final h in _handlerTours)
        if (h.tourId.isNotEmpty) h.tourId: h,
    };
    final ticketTourIds = <String>{
      for (final t in _tickets) t.tourId,
    };
    // Handler tours with no matching seat ticket get their own entry card.
    final handlerOnly = [
      for (final h in _handlerTours)
        if (!ticketTourIds.contains(h.tourId)) h,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in _tickets) ...[
          _TicketCard(
            ticket: t,
            handlerRequestId: handlerByTour[t.tourId]?.requestId,
          ),
          const SizedBox(height: UgamSpacing.lg),
        ],
        for (final h in handlerOnly) ...[
          _HandlerEntryCard(ref: h),
          const SizedBox(height: UgamSpacing.lg),
        ],
      ],
    );
  }
}

/// One resolved ticket: tour header + passenger name + seat-number summary,
/// then the bus diagram(s) with this passenger's seats highlighted.
class _TicketCard extends StatelessWidget {
  final SeatTicket ticket;

  /// When this phone is also the designated handler for this ticket's tour,
  /// the booking_request id used to open the full handler chart. Null = the
  /// rider is a plain passenger, so no handler CTA is shown.
  final String? handlerRequestId;

  const _TicketCard({required this.ticket, this.handlerRequestId});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      padding: const EdgeInsets.all(UgamSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ticket.tourTitle,
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            // The date belongs on the ticket: a rider holding seats on two
            // trips needs to know which card is this weekend's.
            ticket.departureDate == null
                ? '${ticket.fromCity} → ${ticket.toCity}'
                : '${ticket.fromCity} → ${ticket.toCity} · '
                    '${Formatters.formatDateMedium(ticket.departureDate!)}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.person_rounded, size: 15, color: c.ink3),
              ),
              const SizedBox(width: UgamSpacing.xs + 2),
              Expanded(
                child: Text(
                  ticket.passengerName,
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                  // Names wrap before they ellipse — a rider must be able to
                  // read their own name in full to trust the ticket is theirs.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (ticket.seatIds.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.sm),
            // THE accent site on this screen, and the textbook one: "the berth
            // you picked". Everything else here — the tour title, the route,
            // the bus header, the rider's own name — is context; this chip and
            // the `mine` seat tiles below are the only marks that answer the
            // question the rider opened the screen to ask. Keep.
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Text(
                tr(
                  'find_seat.your_seats',
                  namedArgs: {'seats': ticket.seatIds.join(', ')},
                ),
                style: UgamText.caption.copyWith(
                  color: c.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          // The handler's way in sits ABOVE the diagram, not below it. A
          // handler opens this screen to work the bus, and the CTA used to be
          // parked past a full-height seat chart — a scroll they had to know
          // was worth making. Their job is the first thing on the card now.
          if (handlerRequestId != null) ...[
            const SizedBox(height: UgamSpacing.lg),
            UgamCTA(
              label: tr('find_seat.manage_as_handler'),
              leadingIcon: Icons.manage_accounts_rounded,
              onPressed: () => Get.to(
                () => HandlerShell(requestId: handlerRequestId!),
                transition: Transition.cupertino,
              ),
            ),
            const SizedBox(height: UgamSpacing.xs),
            Text(
              tr('find_seat.handler_hint'),
              style: UgamText.micro.copyWith(color: c.ink3),
            ),
          ],
          for (final bus in ticket.buses) ...[
            const SizedBox(height: UgamSpacing.lg),
            _BusDiagram(
              bus: bus,
              mySeatLegs: ticket.seatLegsForBus(bus.id),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact entry for a tour the queried phone handles but holds no seat in.
/// Mirrors [_TicketCard]'s container + header, then a single "Manage as
/// handler" CTA into the full handler chart.
class _HandlerEntryCard extends StatelessWidget {
  final HandlerTourRef ref;

  const _HandlerEntryCard({required this.ref});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      padding: const EdgeInsets.all(UgamSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ref.tourTitle,
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            '${ref.fromCity} → ${ref.toCity}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: tr('find_seat.manage_as_handler'),
            leadingIcon: Icons.manage_accounts_rounded,
            onPressed: () => Get.to(
              () => HandlerShell(requestId: ref.requestId),
              transition: Transition.cupertino,
            ),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('find_seat.handler_hint'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }
}

/// The folded-away entry form: one line stating whose seats are on screen,
/// with the way back into the field. Shown instead of the full form once a
/// lookup has found something, so the diagram starts at the top of the page.
class _QueryChip extends StatelessWidget {
  final UgamColorSet c;
  final String phone;
  final VoidCallback onChange;

  const _QueryChip({
    required this.c,
    required this.phone,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.sm,
        UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        children: [
          Icon(Icons.phone_iphone_rounded, size: 16, color: c.ink3),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr(
                'find_seat.showing_for',
                namedArgs: {'phone': prettyPhone(phone)},
              ),
              style: UgamText.tabular(
                UgamText.caption.copyWith(color: c.ink2),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // The only way back into the number field, and it was a ~28pt pill.
          // The ConstrainedBox raises the TARGET to the 44pt floor while the
          // Center(widthFactor: 1) keeps the PAINTED pill its original size —
          // without it the minHeight propagates into the Container and the
          // chip inflates to fill the row.
          UgamTappable(
            onTap: onChange,
            pressedScale: 0.93,
            semanticLabel: tr('find_seat.change_number'),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: UgamScale.tap(context, 44),
              ),
              child: Center(
                widthFactor: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    tr('find_seat.change_number'),
                    style: UgamText.caption.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single bus diagram with the passenger's own seats highlighted; every other
/// seat renders as a neutral anonymous tile (other riders' identities are never
/// shown — matching the customer "Your seat" sheet's privacy mode).
class _BusDiagram extends StatelessWidget {
  final Bus bus;
  /// seatId → the leg the customer holds it for (drives the half render for a
  /// one-way seat). The keys are the customer's own seats on this bus.
  final Map<String, TripType> mySeatLegs;

  const _BusDiagram({required this.bus, required this.mySeatLegs});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Section glyph, NOT an ownership mark. Every bus rendered on this
            // card is one the rider holds a seat on, so an amber bus icon
            // distinguishes nothing — and it competed with the seats below it,
            // which are the only thing on this screen that is genuinely
            // "yours". The accent is spent on the seat tiles and the
            // "Your seats: …" chip; the header glyph stays neutral.
            Icon(Icons.directions_bus_rounded, size: 18, color: c.ink3),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                bus.customerLabel,
                style: UgamText.bodyStrong.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (layout == null || layout.totalCells == 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
            child: Text(
              tr('find_seat.layout_unavailable'),
              style: UgamText.body.copyWith(color: c.ink2),
            ),
          )
        else ...[
          const SizedBox(height: UgamSpacing.md),
          Container(
            padding: const EdgeInsets.all(UgamSpacing.md),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            child: CombinedSeatGrid(
              layout: layout,
              cellWidth: kSeatTileW,
              cellHeight: kSeatTileH,
              driverLabel: tr('find_seat.driver'),
              tileBuilder: (ctx, cell) {
                final isMine = cell.seatId != null &&
                    mySeatLegs.containsKey(cell.seatId);
                return SeatChartTile(
                  cell: cell,
                  occupants: const [],
                  groupColors: const GroupColorResolver({}),
                  anonymous: true,
                  mine: isMine,
                  mineLeg: isMine ? mySeatLegs[cell.seatId] : null,
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
