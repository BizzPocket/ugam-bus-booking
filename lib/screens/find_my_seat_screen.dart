import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/handler_tour_ref.dart';
import '../models/seat_ticket.dart';
import '../services/customer_requests_store.dart';
import 'handler_bus_chart_screen.dart';

/// "Find my seat by phone" — a booking-request-free way for ANY passenger to
/// see their seat once the organiser has locked the tour. Enter a mobile
/// number, get back every seat held under it (matched on the last 10 digits,
/// so +91 / spaces never matter) with the bus diagram and seat numbers.
///
/// This exists because passengers the agent added manually have no in-app
/// ticket (the "My Requests" view is keyed on booking_requests), so they could
/// never see their seat in the app — only via WhatsApp.
class FindMySeatScreen extends StatefulWidget {
  const FindMySeatScreen({super.key});

  @override
  State<FindMySeatScreen> createState() => _FindMySeatScreenState();
}

class _FindMySeatScreenState extends State<FindMySeatScreen> {
  final _store = CustomerRequestsStore();
  final _phoneCtrl = TextEditingController();

  bool _searching = false;
  bool _searched = false;
  String? _error;
  List<SeatTicket> _tickets = const [];
  List<HandlerTourRef> _handlerTours = const [];

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final phone = _phoneCtrl.text.trim();
    // Need enough digits to identify a number; the server matches the last 10.
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) {
      setState(() => _error = tr('find_seat.error_short'));
      return;
    }
    FocusScope.of(context).unfocus();
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
      setState(() {
        _tickets = results[0] as List<SeatTicket>;
        _handlerTours = results[1] as List<HandlerTourRef>;
        _searched = true;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr('find_seat.error_load');
        _searching = false;
      });
    }
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
                    Text(
                      tr('find_seat.intro'),
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('find_seat.phone_label'),
                      controller: _phoneCtrl,
                      hint: tr('find_seat.phone_hint'),
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                      ],
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
                      leadingIcon: Icons.event_seat_rounded,
                      onPressed: _searching ? null : _search,
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

  Widget _results(UgamColorSet c) {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UgamSpacing.xxl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_searched) return const SizedBox.shrink();
    if (_tickets.isEmpty && _handlerTours.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: UgamSpacing.lg),
        child: UgamEmpty(
          icon: Icons.event_seat_outlined,
          title: tr('find_seat.empty_title'),
          body: tr('find_seat.empty_body'),
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
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ticket.tourTitle,
            style: UgamText.titleS.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            '${ticket.fromCity} → ${ticket.toCity}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Icon(Icons.person_rounded, size: 14, color: c.ink3),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  ticket.passengerName,
                  style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (ticket.seatIds.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: 6,
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
          for (final bus in ticket.buses) ...[
            const SizedBox(height: UgamSpacing.lg),
            _BusDiagram(
              bus: bus,
              mySeatIds: ticket.seatIdsForBus(bus.id),
            ),
          ],
          if (handlerRequestId != null) ...[
            const SizedBox(height: UgamSpacing.lg),
            UgamCTA(
              label: tr('find_seat.manage_as_handler'),
              leadingIcon: Icons.manage_accounts_rounded,
              onPressed: () => Get.to(
                () => HandlerBusChartScreen(requestId: handlerRequestId!),
                transition: Transition.cupertino,
              ),
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
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ref.tourTitle,
            style: UgamText.titleS.copyWith(color: c.ink),
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
              () => HandlerBusChartScreen(requestId: ref.requestId),
              transition: Transition.cupertino,
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
  final Set<String> mySeatIds;

  const _BusDiagram({required this.bus, required this.mySeatIds});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.directions_bus_rounded, size: 18, color: c.accent),
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
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.border),
            ),
            child: CombinedSeatGrid(
              layout: layout,
              cellWidth: kSeatTileW,
              cellHeight: kSeatTileH,
              driverLabel: tr('find_seat.driver'),
              tileBuilder: (ctx, cell) {
                final isMine =
                    cell.seatId != null && mySeatIds.contains(cell.seatId);
                return SeatChartTile(
                  cell: cell,
                  occupants: const [],
                  groupColors: const GroupColorResolver({}),
                  anonymous: true,
                  mine: isMine,
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
