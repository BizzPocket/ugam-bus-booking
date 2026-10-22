part of '../tour_detail_screen.dart';

// ─── PASSENGERS TAB ───────────────────────────────────────────────────

class _PassengersTab extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;

  const _PassengersTab({required this.tour, required this.c});

  @override
  State<_PassengersTab> createState() => _PassengersTabState();
}

class _PassengersTabState extends State<_PassengersTab> {
  TravelerFilter _filter = TravelerFilter.all;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tour = widget.tour;
    final c = widget.c;
    final all = tour.passengers;

    if (all.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.lg),
          child: _PassengersEmptyState(tour: tour),
        ),
      );
    }

    final needsSeatCount = all.where(passengerNeedsSeat).length;
    final seatedCount = all.length - needsSeatCount;
    var filtered = filterTravelers(
      all,
      filter: _filter,
      query: _query,
    );
    // Needs-seat first so the agent sees work before the completed roster.
    if (_filter == TravelerFilter.all && _query.trim().isEmpty) {
      filtered = [
        ...filtered.where(passengerNeedsSeat),
        ...filtered.where((p) => !passengerNeedsSeat(p)),
      ];
    }

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _RosterHeader(
          count: all.length,
          c: c,
          onAdd: () => _openTourRequests(context, tour.id),
        ),
        if (needsSeatCount > 0) ...[
          const SizedBox(height: UgamSpacing.sm),
          _TravelersProgressStrip(
            c: c,
            seated: seatedCount,
            open: needsSeatCount,
            total: all.length,
          ),
        ],
        const SizedBox(height: UgamSpacing.sm),
        UgamSearchField(
          hint: tr('tour_detail.search_travelers_hint'),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: UgamSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: tr('tour_detail.filter_all'),
                count: all.length,
                selected: _filter == TravelerFilter.all,
                c: c,
                onTap: () => setState(() => _filter = TravelerFilter.all),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.filter_needs_seat'),
                count: needsSeatCount,
                selected: _filter == TravelerFilter.needsSeat,
                c: c,
                onTap: () =>
                    setState(() => _filter = TravelerFilter.needsSeat),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.filter_sl'),
                selected: _filter == TravelerFilter.single,
                c: c,
                onTap: () => setState(() => _filter = TravelerFilter.single),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.filter_dl'),
                selected: _filter == TravelerFilter.double_,
                c: c,
                onTap: () => setState(() => _filter = TravelerFilter.double_),
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
            child: UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('tour_detail.no_matches_title'),
              body: tr('tour_detail.no_matches_body'),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++) ...[
            _PassengerRow(passenger: filtered[i], tour: tour, c: c),
            if (i != filtered.length - 1)
              const SizedBox(height: 6),
          ],
      ]),
    );
  }
}

class _TravelersProgressStrip extends StatelessWidget {
  final UgamColorSet c;
  final int seated;
  final int open;
  final int total;

  const _TravelersProgressStrip({
    required this.c,
    required this.seated,
    required this.open,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total == 0 ? 0.0 : seated / total;
    return Row(
      children: [
        Expanded(
          child: Text(
            tr('tour_detail.travelers_progress', namedArgs: {
              'seated': '$seated',
              'open': '$open',
            }),
            style: UgamText.caption.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        SizedBox(
          width: 72,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: c.cardElev,
              // Ink, not amber — a fill ratio is a measurement, not something
              // the user picked. Matches the identical bar on the Charts tab.
              color: c.ink2,
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.c,
    required this.onTap,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    final text = count == null ? label : '$label $count';
    // KEEP the accent: "the currently-selected value" is precisely what it is
    // for, and this is the only such control on the screen.
    //
    // DEMOTED from a solid amber slab to the TONAL treatment [UgamSelectorPills]
    // already ships (accentFill + accent ink + a hairline accent border). A
    // solid fill is the app's single focal weight; spending it on a filter chip
    // — and then on a second one in the Activity tab's own row — put two solid
    // amber slabs on a screen whose primary button carries none.
    return Material(
      color: selected ? c.accentFill : c.cardElev,
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        child: Container(
          // The border lives on a Container INSIDE the InkWell, not on the
          // Material: the ripple has to paint over it, and a selected chip must
          // not shift its neighbours by a pixel when the border appears.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            border: Border.all(
              color: selected
                  ? c.accent.withValues(alpha: 0.32)
                  : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            text,
            style: UgamText.caption.copyWith(
              color: selected ? c.accent : c.ink2,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty Passengers tab. ONE primary action — "Share on WhatsApp to collect
/// riders" — wired to the SAME broadcast send the Overview Broadcast card uses
/// (via shared [_TourBroadcast.send], no duplicated message-building). "Copy
/// broadcast message" and the manual "Add riders" path are demoted to
/// full-width neutral buttons (>=48dp tap targets) below the empty state.
class _PassengersEmptyState extends StatefulWidget {
  final Tour tour;

  const _PassengersEmptyState({required this.tour});

  @override
  State<_PassengersEmptyState> createState() => _PassengersEmptyStateState();
}

class _PassengersEmptyStateState extends State<_PassengersEmptyState> {
  bool _sending = false;

  Future<void> _share() => _TourBroadcast.send(
        widget.tour,
        isSending: _sending,
        setSending: (v) => setState(() => _sending = v),
        isMounted: () => mounted,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        UgamEmpty(
          icon: Icons.people_outline_rounded,
          title: tr('tour_detail.no_passengers_title'),
          body: tr('tour_detail.no_passengers_body'),
          // PRIMARY: share the tour on WhatsApp to collect riders.
          cta: UgamCTA(
            label: _sending
                ? tr('tour_detail.sending_broadcast')
                : tr('tour_detail.share_to_collect_riders'),
            leadingIcon: Icons.send_rounded,
            loading: _sending,
            onPressed: _share,
          ),
        ),
        const SizedBox(height: UgamSpacing.lg),
        // Secondary, demoted: copy the same message to the clipboard. Promoted
        // from a sub-44dp inline text link to a full-width neutral button so it
        // hits the 48dp+ tap-target rule.
        UgamButton(
          label: tr('tour_detail.copy_broadcast_message'),
          icon: Icons.copy_rounded,
          kind: UgamButtonKind.neutral,
          expand: true,
          onPressed: () => _TourBroadcast.copy(widget.tour),
        ),
        const SizedBox(height: UgamSpacing.sm),
        // Quiet manual path: add a rider on behalf of a customer (with the
        // phone-contacts picker) even before anyone has booked.
        UgamButton(
          label: tr('tour_detail.add_riders'),
          icon: Icons.person_add_alt_1_rounded,
          kind: UgamButtonKind.neutral,
          expand: true,
          onPressed: () => _openTourRequests(context, widget.tour.id),
        ),
      ],
    );
  }
}

/// Slim header for the populated Passengers tab: a "Riders" label + live count
/// on the left and a compact "+ Add" pill on the right that opens the per-tour
/// requests manager. Replaces the old full-width _ManageRequestsButton card so
/// the roster itself leads the tab rather than a navigation button. The pill
/// stays NEUTRAL — the sticky "Assign seats" CTA is the tab's one focal
/// control, and it carries `action` ink, not the accent.
class _RosterHeader extends StatelessWidget {
  final int count;
  final UgamColorSet c;
  final VoidCallback onAdd;

  const _RosterHeader({
    required this.count,
    required this.c,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          tr('tour_detail.roster_header'),
          style: UgamText.titleS.copyWith(color: c.ink),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.badgeH,
            vertical: UgamSpacing.badgeV,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            '$count',
            style: UgamText.tabular(
              UgamText.caption.copyWith(
                color: c.ink2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const Spacer(),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onAdd();
            },
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            // The only "add a rider" entry on a populated roster was a ~33pt
            // pill. The Center is load-bearing: without it the minHeight
            // propagates into the Container and inflates the painted pill.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Center(
                widthFactor: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: UgamSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_add_alt_1_rounded,
                          size: 16, color: c.ink),
                      const SizedBox(width: 6),
                      Text(
                        tr('tour_detail.add'),
                        style: UgamText.bodyStrong
                            .copyWith(color: c.ink, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Quick-action sheet for a single rider, opened by tapping their roster row.
/// Three first-class actions for a WhatsApp-run tour desk: message the rider
/// (request-received / seat-confirmed ack), call them, or jump to edit their
/// request. Reuses [_HeroActionRow] for the row styling and the shared
/// [WhatsAppService.sendAck] / [PhoneDialer] paths used elsewhere in the app.
void _showPassengerActions(
  BuildContext context,
  Passenger passenger,
  Tour tour,
  UgamColorSet c,
) {
  UgamSheet.show<void>(
    context,
    title: passenger.name,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeroActionRow(
          icon: Icons.chat_rounded,
          label: tr('tour_detail.msg_whatsapp'),
          c: c,
          onTap: () {
            // Pop on the sheet's own (root) navigator first, then fire the
            // ack send — mirrors the hero actions sheet's close-then-act order.
            AppNav.pop(ctx);
            _messageRiderOnWhatsApp(passenger, tour);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _HeroActionRow(
          icon: Icons.call_rounded,
          label: tr('tour_detail.call'),
          c: c,
          onTap: () {
            AppNav.pop(ctx);
            PhoneDialer.call(passenger.phone);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _HeroActionRow(
          icon: Icons.edit_note_rounded,
          label: tr('tour_detail.edit_request'),
          c: c,
          onTap: () {
            AppNav.pop(ctx);
            _openTourRequests(context, tour.id);
          },
        ),
      ],
    ),
  );
}

/// The per-tour requests manager — the roster's "+ Add", the empty state's
/// "Add riders" and a rider's "Edit request" all land here.
void _openTourRequests(BuildContext context, String tourId) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => RequestsScreen(initialTourId: tourId)),
  );
}

/// Opens WhatsApp addressed to [passenger] with the contextual ack pre-filled
/// (request-received before seats, seat-confirmed once assigned). Surfaces a
/// warning toast only if WhatsApp can't be opened.
Future<void> _messageRiderOnWhatsApp(Passenger passenger, Tour tour) async {
  final ok = await WhatsAppService().sendAck(passenger: passenger, tour: tour);
  if (!ok) AppSnackBar.warning(tr('tour_detail.whatsapp_open_failed'));
}

/// Opens a blank WhatsApp chat to the bus driver (same path used by the bus &
/// handler screens). Warning toast only on failure.
Future<void> _contactDriverOnWhatsApp(Bus bus) async {
  final ok =
      await WhatsAppService().openChat(phone: bus.driverPhone, message: '');
  if (!ok) AppSnackBar.warning(tr('tour_detail.whatsapp_open_failed'));
}

class _PassengerRow extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final UgamColorSet c;

  const _PassengerRow({
    required this.passenger,
    required this.tour,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final needsSeat = passengerNeedsSeat(passenger);
    final seated = passenger.isFullyAssigned;

    // "Still needs a seat" is a STATE — outstanding work on the agent's
    // roster — not "this row is yours", so it takes the warm/pending tone that
    // the re-notify highlight and [UgamButtonKind.warmTonal] already use for
    // exactly this meaning. It pairs with the `good` tick on a seated rider
    // below, so the roster reads green = done / rose = open, and the amber is
    // left to the seat chart, where a berth genuinely belongs to someone.
    return Material(
      color: needsSeat ? c.warmFill : c.card,
      borderRadius: BorderRadius.circular(UgamRadius.row),
      child: InkWell(
        onTap: () => _showPassengerActions(context, passenger, tour, c),
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: needsSeat
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                  border: Border.all(color: c.warm.withValues(alpha: 0.35)),
                )
              : null,
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: needsSeat ? c.warm.withValues(alpha: 0.18) : c.cardElev,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(passenger.name),
                  style: UgamText.micro.copyWith(
                    color: needsSeat ? c.warm : c.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      passenger.name,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _seatMeta(passenger, tour),
                            style: UgamText.caption.copyWith(
                              color: c.ink2,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          seated
                              ? '✓ ${passenger.totalSeatsAssigned}/${passenger.seatBerths}'
                              : passenger.progressLabel,
                          style: UgamText.tabular(
                            UgamText.micro.copyWith(
                              color: seated
                                  ? c.good
                                  : needsSeat
                                      ? c.warm
                                      : c.ink3,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _ago(passenger.createdAt),
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3),
                ),
              ),
              if (needsSeat) ...[
                const SizedBox(width: 6),
                // A real per-row control, so it gets press feedback and a 44pt
                // target — it was an ~18pt bare label, and a near-miss fell
                // through to the row's own tap and opened the actions sheet
                // instead. The Center(widthFactor: 1) keeps the PAINTED label
                // its original size while the box grows.
                UgamTappable(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SeatsScreen(
                          tourId: tour.id,
                          initialMode: SeatsMode.summary,
                        ),
                      ),
                    );
                  },
                  pressedScale: 0.93,
                  semanticLabel: tr('tour_detail.assign_row'),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: UgamScale.tap(context, 44),
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Text(
                          // `action` ink, not amber: this is the button on the
                          // row, and the app's primary control deliberately
                          // carries no brand hue. It stays legible on the warm
                          // fill and reads as the one thing here to press.
                          // [UgamText.label], not `micro`: this is a
                          // TRANSLATED control label, and micro is Sora 10 with
                          // +1.4 tracking — a no-op caps device, a broken
                          // conjunct and an 8.5pt render in Gujarati.
                          tr('tour_detail.assign_row'),
                          style: UgamText.label.copyWith(color: c.action),
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                Icon(Icons.chevron_right_rounded, size: 16, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }

  String _seatMeta(Passenger p, Tour tour) {
    final req = p.requestSummary;
    if (p.assignedSeats.isEmpty) {
      return '$req · ${tr('tour_detail.seat_meta_none')}';
    }
    final seatIds = p.assignedSeats.map((a) => a.seatId).join(', ');
    final busId = p.assignedSeats.first.busId;
    final bus = tour.buses.where((b) => b.id == busId).firstOrNull;
    final busLabel = bus?.displayLabel;
    if (busLabel != null && busLabel.isNotEmpty) {
      return '$req · $busLabel · $seatIds';
    }
    return '$req · ${tr('tour_detail.seat_meta_placed', namedArgs: {'seats': seatIds})}';
  }

  String _initials(String name) {
    final trimmed = name.trim();
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first.characters.first}${parts.last.characters.first}'.toUpperCase();
    }
    // Test the TRIMMED name: an all-whitespace name must fall back to '?',
    // not render a blank avatar.
    return trimmed.isNotEmpty ? trimmed.characters.first.toUpperCase() : '?';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return tr('tour_detail.ago_now');
  }
}
