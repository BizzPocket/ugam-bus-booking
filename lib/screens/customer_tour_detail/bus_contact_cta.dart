part of '../customer_tour_detail_screen.dart';

// ─── BUS CARD ─────────────────────────────────────────────────────────

/// One bus, as the customer may see it. Fed from `public_tour_buses`, so the
/// driver/owner phones and the owner's rent are never in this object at all.
class _BusCard extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;

  const _BusCard({required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    final departure = _busDeparture(bus.boardingPoint);
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            bus.customerLabel,
            style: UgamText.titleS.copyWith(color: c.ink),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            bus.busType,
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          if (departure != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.place_outlined, size: 13, color: c.ink3),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    departure,
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              if (bus.isAC) ...[
                UgamReqChip(label: tr('customer_tour_detail.bus_ac')),
                const SizedBox(width: 5),
              ],
              UgamReqChip(
                label: tr(
                  'customer_tour_detail.chip_seats',
                  namedArgs: {'count': bus.totalSeats.toString()},
                ),
                variant: UgamChipVariant.neutral,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Per-bus boarding place, or null to hide the line.
  ///
  /// The TIME is deliberately not here. The journey section above already
  /// prints the tour's departure time, and a bus row carrying its own
  /// `departure_time` put two different times on one screen ("5:30 AM" in the
  /// journey, "5:30 PM" on the bus card) — a pilgrim cannot tell which bus to
  /// be at. One screen, one departure time: the tour's.
  static String? _busDeparture(String boardingPoint) {
    final place = boardingPoint.trim();
    return place.isEmpty ? null : place;
  }
}

// ─── CONTACT ──────────────────────────────────────────────────────────

/// Tappable "Contact organiser on WhatsApp" row, shown when the tour carries an
/// organiser number ([Tour.createdBy]) — the same number the booking flow sends
/// requests to. Hidden entirely when the tour has none.
class _ContactOrganiserButton extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ContactOrganiserButton({required this.tour, required this.c});

  Future<void> _open() async {
    HapticFeedback.selectionClick();
    final phone = tour.createdBy?.trim() ?? '';
    if (phone.isEmpty) return;
    final ok = await WhatsAppService().openChat(
      phone: phone,
      message: tr(
        'customer_tour_detail.contact_greeting',
        namedArgs: {
          'tour': tour.title,
          'code': WhatsAppService.tourCode(tour.id),
        },
      ),
    );
    if (!ok) {
      AppSnackBar.error(
        tr('customer_tour_detail.contact_error_body'),
        title: tr('customer_tour_detail.contact_error_title'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _open,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.lg),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.card),
          ),
          child: Row(
            children: [
              // Neutral medallion. This is a control, and the accent is
              // explicitly not the button colour — the label already says
              // WhatsApp, so the copper added nothing but noise.
              Container(
                width: UgamScale.px(context, 42),
                height: UgamScale.px(context, 42),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 20,
                  color: c.ink2,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Both lines wrap. The Gujarati title is "આયોજક સાથે
                    // WhatsApp પર સંપર્ક કરો" — it does not fit one line at
                    // 375 pt next to a medallion and an arrow.
                    Text(
                      tr('customer_tour_detail.contact_organiser'),
                      style: UgamText.bodyStrong.copyWith(color: c.ink),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('customer_tour_detail.contact_organiser_subtitle'),
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 3,
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, size: 18, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── STICKY CTA ───────────────────────────────────────────────────────

class _StickyBookCta extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;

  const _StickyBookCta({required this.tour, required this.summary});

  @override
  Widget build(BuildContext context) {
    final String label;
    final IconData icon;
    final VoidCallback? onTap;

    // Same precedence as _AvailabilityChip: locked > sold out > open.
    if (!tour.acceptsBookings) {
      label = tr('customer_tour_detail.cta_bookings_closed');
      icon = Icons.lock_outline_rounded;
      onTap = null;
    } else if (tour.bookingMode.isChart && summary.loaded && !summary.hasBuses) {
      // Chart mode with no sellable bus. Only asserted once the RPC has
      // ANSWERED — while pending we let the customer through to
      // SeatSelectionScreen, which has its own empty state. Note this gate
      // reads the public RPC, never `tour.chartNeedsBus`: that getter reads
      // `tour.buses`, which is always empty for anon, so it could never pass.
      label = tr('customer_tour_detail.cta_seats_not_open');
      icon = Icons.event_seat_outlined;
      onTap = null;
    } else if (summary.isSoldOut) {
      label = tr('customer_tour_detail.cta_join_waitlist');
      icon = Icons.hourglass_top_rounded;
      onTap = () => Get.to(
        () => CustomerBookingRequestScreen(tour: tour),
        transition: Transition.cupertino,
      );
    } else if (tour.bookingMode.isChart) {
      label = tr('customer_tour_detail.cta_pick_seats');
      icon = Icons.event_seat_rounded;
      // Through the party gate, not straight to the chart: it asks how many are
      // travelling (and, on a multi-bus tour, whether they must stay together)
      // so the chart can answer "does this bus fit us" instead of leaving the
      // customer to work it out tile by tile.
      onTap = () => Get.to(
        () => PartyGateScreen(tour: tour),
        transition: Transition.cupertino,
      );
    } else {
      label = tr('customer_tour_detail.cta_request_to_book');
      icon = Icons.send_rounded;
      onTap = () => Get.to(
        () => CustomerBookingRequestScreen(tour: tour),
        transition: Transition.cupertino,
      );
    }

    return UgamStickyCTA(
      child: UgamCTA(label: label, leadingIcon: icon, onPressed: onTap),
    );
  }
}

// ─── SHARED BITS ──────────────────────────────────────────────────────

/// Section heading. See the note on `customer_more_screen._SectionLabel`: the
/// uppercase `UgamText.micro` eyebrow is a device that does not exist in
/// Gujarati or Hindi, so on the primary language it left a 10 px ink3 whisper
/// with 1.4 letter-spacing wedged between the conjuncts. Weight plus colour
/// works in every script.
class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;

  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.bodyStrong.copyWith(color: c.ink2));
  }
}

/// Bus-card-shaped placeholder for the window between the page appearing and
/// `public_tour_buses` answering.
class _BusCardSkeleton extends StatelessWidget {
  const _BusCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UgamSkeleton(height: 16, width: 150, radius: 6),
          SizedBox(height: 6),
          UgamSkeleton(height: 13, width: 96, radius: 6),
          SizedBox(height: UgamSpacing.tight),
          UgamSkeleton(height: 13, width: 190, radius: 6),
          SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              UgamSkeleton(height: 16, width: 34, radius: 6),
              SizedBox(width: 5),
              UgamSkeleton(height: 16, width: 62, radius: 6),
            ],
          ),
        ],
      ),
    );
  }
}
