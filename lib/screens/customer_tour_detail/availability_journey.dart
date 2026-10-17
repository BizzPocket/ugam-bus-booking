part of '../customer_tour_detail_screen.dart';

/// Availability, in whichever of its four states applies.
///
/// This is the ONE status signal on the page, and it now covers the whole
/// lifecycle of the fetch rather than just its happy ending:
///
///  * in flight — a skeleton the size of the meter that replaces it;
///  * failed    — says so, and offers a retry (the RPC swallows its own
///                errors, so silence here used to be indistinguishable from
///                a tour that simply has no buses);
///  * counted   — a real capacity meter, because "68 / 80 · 12 free" is a
///                different decision from "12 SEATS LEFT" and the numbers were
///                already fetched;
///  * otherwise — the single lock / sold-out / open chip.
///
/// Lock beats sold-out beats a live seat count beats the generic open state —
/// the same order the CTA resolves in, so the two can never contradict.
class _AvailabilityBlock extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;
  final bool summaryFailed;
  final VoidCallback onRetry;

  const _AvailabilityBlock({
    required this.tour,
    required this.summary,
    required this.summaryFailed,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    if (tour.acceptsBookings && !summary.loaded) {
      if (summaryFailed) {
        return _SeatsUnavailable(onRetry: onRetry, c: c);
      }
      return const _SeatsSkeleton();
    }

    if (tour.acceptsBookings && summary.hasSeatCount && !summary.isSoldOut) {
      final left = summary.berthsFree;
      final taken = summary.berthsTotal - left;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('customer_tour_detail.label_seats'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Scarcity is worth saying out loud, but it is availability, not
              // "this is yours" — so it borrows the warm tone, never the accent.
              if (left <= 5)
                UgamReqChip(
                  label: tr(
                    'customer_tour_detail.chip_seats_left',
                    namedArgs: {'n': '$left'},
                  ),
                  variant: UgamChipVariant.warm,
                ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          // `berthsFree` is already limited by the BUSIER leg (see
          // summariseTourForPublic), so both legs carry the same figure here
          // and the meter collapses to the single honest bar.
          UgamCapacityMeter.tourCounts(
            capacity: summary.berthsTotal,
            goOccupied: taken,
            retOccupied: taken,
          ),
        ],
      );
    }

    // Left-anchored. There is nothing to balance it against now that the price
    // is gone, so a Row with a trailing Spacer would only push it into dead
    // space.
    return Align(
      alignment: Alignment.centerLeft,
      child: _AvailabilityChip(tour: tour, summary: summary),
    );
  }
}

/// Meter-shaped placeholder — a label bar over a bar the height of the real
/// one, so the card does not resize when the count lands.
class _SeatsSkeleton extends StatelessWidget {
  const _SeatsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            UgamSkeleton(height: 13, width: 64, radius: 4),
            Spacer(),
            UgamSkeleton(height: 13, width: 82, radius: 4),
          ],
        ),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 7, radius: UgamRadius.chip),
      ],
    );
  }
}

/// "We couldn't check the seats" + Retry. Replaces a permanently shimmering
/// meter on a dropped connection.
class _SeatsUnavailable extends StatelessWidget {
  final VoidCallback onRetry;
  final UgamColorSet c;

  const _SeatsUnavailable({required this.onRetry, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.cloud_off_rounded, size: 16, color: c.ink3),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Text(
            tr('customer_tour_detail.seats_unavailable'),
            style: UgamText.caption.copyWith(color: c.ink2),
            maxLines: 2,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onRetry();
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: UgamScale.tap(context, 44),
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
            alignment: Alignment.center,
            child: Text(
              tr('app.action.retry'),
              style: UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
        ),
      ],
    );
  }
}

/// The lock / sold-out / open fallback, for when there is no real seat count to
/// draw a meter from. [_AvailabilityBlock] owns the counted case and the
/// precedence between them.
class _AvailabilityChip extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;

  const _AvailabilityChip({required this.tour, required this.summary});

  @override
  Widget build(BuildContext context) {
    if (!tour.acceptsBookings) {
      return UgamReqChip(
        label: tr('customer_tour_detail.chip_bookings_closed'),
        variant: UgamChipVariant.warm,
      );
    }
    if (summary.isSoldOut) {
      return UgamReqChip(
        label: tr('customer_tour_detail.chip_tour_full'),
        variant: UgamChipVariant.warm,
      );
    }
    // `good`, not `accent`. Nothing on a public tour page is YOURS yet — you
    // haven't booked — and the accent is defined as exactly that claim. "Open
    // for requests" is a positive availability state, which is what mint means
    // everywhere else in the app.
    return UgamReqChip(
      label: tr('customer_tour_detail.chip_open_requests'),
      variant: UgamChipVariant.good,
    );
  }
}

// ─── JOURNEY BLOCK ────────────────────────────────────────────────────

/// The whole journey in ONE block: where it leaves from, where it goes, and
/// when it comes back — cities and schedule together.
///
/// This replaced a label/value "trip summary" table sitting directly above a
/// timeline that restated the same dates. Neither was wrong on its own; having
/// both meant the page said everything twice. The rail carries the cities now,
/// so it is the single place the journey is described.
class _JourneyBlock extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _JourneyBlock({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final stops = <_JourneyStop>[
      _JourneyStop(
        icon: Icons.directions_bus_rounded,
        label: tr('customer_tour_detail.label_departure'),
        place: tour.fromCity,
        date: tour.departureDate,
        timeLabel: formatHhMm(tour.departureTime),
      ),
      _JourneyStop(
        icon: Icons.place_rounded,
        label: tr('customer_tour_detail.label_destination'),
        place: tour.toCity,
        // Deliberately no date or time. An arrival time is never recorded, and
        // inventing one is exactly how the old "arrive in {city}" row came to
        // state a fact the app does not have. As a WAYPOINT it needs no clock.
      ),
      if (tour.returnDate != null)
        _JourneyStop(
          icon: Icons.flag_rounded,
          label: tr('customer_tour_detail.label_return'),
          place: tour.fromCity,
          date: tour.returnDate!,
          timeLabel: formatHhMm(tour.returnTime),
        ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
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
          for (var i = 0; i < stops.length; i++)
            _JourneyStopRow(
              stop: stops[i],
              isFirst: i == 0,
              isLast: i == stops.length - 1,
              c: c,
            ),
        ],
      ),
    );
  }
}

class _JourneyStop {
  final IconData icon;

  /// Eyebrow above the place — "Departure" / "Destination" / "Return".
  final String label;

  /// The city. This is the headline of the row: the journey is a sequence of
  /// PLACES, and the dates qualify them.
  final String place;

  /// Null for the destination waypoint, which has no recorded schedule.
  final DateTime? date;
  final String? timeLabel;

  const _JourneyStop({
    required this.icon,
    required this.label,
    required this.place,
    this.date,
    this.timeLabel,
  });
}

/// One stop: node and connector on the left, eyebrow / place / when on the
/// right.
///
/// The node sits near the TOP of its row rather than centred, so it lines up
/// with the eyebrow no matter how tall the row grows when a long city name
/// wraps. The connector is a fixed stub above the node plus a flexible run
/// below it, which keeps the line continuous between rows of unequal height.
class _JourneyStopRow extends StatelessWidget {
  final _JourneyStop stop;
  final bool isFirst;
  final bool isLast;
  final UgamColorSet c;

  const _JourneyStopRow({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                SizedBox(
                  height: 10,
                  child: isFirst
                      ? null
                      : Center(
                          child: Container(width: 2, height: 10, color: c.border),
                        ),
                ),
                // Neutral, not amber. Three copper-ringed nodes on a public
                // page is the accent spent on decoration: nothing in this rail
                // is the customer's — they have not booked yet — and amber is
                // defined as "this is yours". Weight and the connector line
                // carry the structure instead.
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: c.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.border, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(stop.icon, size: 13, color: c.ink2),
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
                top: UgamSpacing.xs,
                bottom: isLast ? UgamSpacing.xs : UgamSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // caption, not the micro eyebrow. "નીકળવાની તારીખ" at 10 px
                  // with 1.4 letter-spacing is barely legible, and micro is the
                  // UPPERCASE style — which does nothing at all in Gujarati.
                  Text(
                    stop.label,
                    style: UgamText.caption.copyWith(color: c.ink3),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    stop.place,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (stop.date != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      _whenLabel(stop),
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _whenLabel(_JourneyStop s) {
    final date = _formatLongDate(s.date!);
    return s.timeLabel != null ? '$date · ${s.timeLabel}' : date;
  }
}
