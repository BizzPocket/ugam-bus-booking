part of '../customer_booking_request_screen.dart';

// ─── TRIP BRIEF CARD ──────────────────────────────────────────────────

/// One fact in the brief's strip: a micro label, the value, and an optional
/// quieter detail beneath it (the departure time under the departure date).
class _TripFact {
  final String label;
  final String value;
  final String? detail;
  const _TripFact({required this.label, required this.value, this.detail});
}

/// The trip, as the customer needs it BEFORE committing to seats.
///
/// This was a thumbnail + title + route strip on a flat `c.card` rectangle:
/// three lines of context in front of a form that asks for money, with the
/// departure date hidden in a 9.5px badge on the photo. Everything the
/// customer would otherwise have to go back to the tour page for — when the
/// bus leaves, what one berth costs, when it comes back — now sits on the same
/// surface, and that surface is a real [UgamCard], so it carries the app's
/// level-1 elevation instead of reading as a tinted rectangle.
///
/// The date badge is gone because the date is now stated properly (with its
/// time) in the strip; nothing that was on screen has left it.
class _TripBriefCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _TripBriefCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final locale = context.locale.languageCode;
    // Decorative thumbnail — never a tap target, so px() (not tap()).
    final thumb = UgamScale.px(context, 88);

    final facts = <_TripFact>[
      _TripFact(
        label: tr('customer_booking.brief_departs'),
        value: Formatters.formatDateShort(tour.departureDate, locale: locale),
        detail: formatHhMm(tour.departureTime),
      ),
      // A tour with no price set would otherwise advertise "₹0 per seat".
      if (tour.pricePerSeat > 0)
        _TripFact(
          label: tr('customer_booking.brief_per_seat'),
          value: Formatters.formatMoneyInr(tour.pricePerSeat),
        ),
      if (tour.returnDate != null)
        _TripFact(
          label: tr('customer_booking.brief_returns'),
          value: Formatters.formatDateShort(tour.returnDate!, locale: locale),
          detail: formatHhMm(tour.returnTime),
        ),
    ];

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md - 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(UgamRadius.photo),
                child: SizedBox(
                  width: thumb,
                  height: thumb,
                  child: UgamBusBackdrop(
                    seed: tour.id,
                    label: customerRouteInitials(tour.fromCity, tour.toCity),
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tour.title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Hairline seam — the same one-pixel border the rest of the system
          // uses to divide a surface without spending vertical space on air.
          Container(
            margin: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
            height: 1,
            color: c.border,
          ),
          // Two per row, never three: at the Gujarati string lengths a third
          // column ellipsises the value, which is the one part that must stay
          // readable. Three facts therefore run 2 + 1, and the odd row's empty
          // half keeps the grid aligned instead of centring the last cell.
          for (var i = 0; i < facts.length; i += 2) ...[
            if (i > 0) const SizedBox(height: UgamSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _TripFactCell(fact: facts[i], c: c)),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: i + 1 < facts.length
                      ? _TripFactCell(fact: facts[i + 1], c: c)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TripFactCell extends StatelessWidget {
  final _TripFact fact;
  final UgamColorSet c;
  const _TripFactCell({required this.fact, required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          fact.label.toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink3),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(
          fact.value,
          style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (fact.detail != null)
          Text(
            fact.detail!,
            style: UgamText.tabular(UgamText.caption.copyWith(color: c.ink2)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

// ─── WHAT HAPPENS NEXT ────────────────────────────────────────────────

/// The three steps between tapping Submit and having a berth.
///
/// Two problems, one block. The page used to end at the last form field with
/// most of the viewport left over, so it read as unfinished; and nothing in
/// the flow ever told the customer that this is a *request* — that WhatsApp
/// opens, that a human answers, and that the answer arrives later. The steps
/// are the honest description of what the submit button does, so they earn the
/// space rather than filling it.
///
/// Deliberately flush (level 0): supporting text, not an object on the page.
/// The brief above is the card.
class _NextStepsBlock extends StatelessWidget {
  final bool isEditing;
  final UgamColorSet c;
  const _NextStepsBlock({required this.isEditing, required this.c});

  @override
  Widget build(BuildContext context) {
    final steps = <(String, String)>[
      (
        tr(
          isEditing
              ? 'customer_booking.next_s1_title_edit'
              : 'customer_booking.next_s1_title',
        ),
        tr(
          isEditing
              ? 'customer_booking.next_s1_body_edit'
              : 'customer_booking.next_s1_body',
        ),
      ),
      (
        tr('customer_booking.next_s2_title'),
        tr('customer_booking.next_s2_body'),
      ),
      (
        tr('customer_booking.next_s3_title'),
        tr('customer_booking.next_s3_body'),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('customer_booking.next_title').toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (var i = 0; i < steps.length; i++)
            _NextStepRow(
              index: i + 1,
              title: steps[i].$1,
              body: steps[i].$2,
              isLast: i == steps.length - 1,
              c: c,
            ),
        ],
      ),
    );
  }
}

/// One numbered step with a connector running to the next — the same rail
/// idiom the customer tour detail's journey block uses, so a sequence looks
/// like a sequence on both screens.
class _NextStepRow extends StatelessWidget {
  final int index;
  final String title;
  final String body;
  final bool isLast;
  final UgamColorSet c;

  const _NextStepRow({
    required this.index,
    required this.title,
    required this.body,
    required this.isLast,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // Decorative node — nothing here is tappable.
    final node = UgamScale.px(context, 26);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: node,
            child: Column(
              children: [
                Container(
                  width: node,
                  height: node,
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.accent, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$index',
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.accent),
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(child: Container(width: 2, color: c.border)),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: 2,
                bottom: isLast ? 0 : UgamSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SECTION EYEBROW ──────────────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink3),
      ),
    );
  }
}
