import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/content_block_view.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import '../services/seat_chart_booking_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_nav.dart';
import '../utils/app_snackbar.dart';
import '../utils/time_format.dart';
import '../utils/tour_public_summary.dart';
import 'customer_booking_request_screen.dart';
import 'party_gate_screen.dart';

/// Public-facing tour detail — the page that has to sell the trip.
///
///   [Header — photo strip when the tour has one, otherwise nothing at all]
///   [Summary card — title / route / countdown / price / availability]
///   [Journey rail — departure and return, always visible]
///   [About / Bus / Contact]
///   [Sticky CTA]
///
/// THREE things this layout deliberately does NOT do, each of which it used to:
///
/// 1. **No 320px illustration.** The hero was a fixed-height generated bus
///    backdrop that carried no information, so the price and the CTA started
///    below the fold on every phone. A real photo earns its space; a
///    placeholder does not. Same call the admin page already made.
/// 2. **No tabs.** An About/Schedule split hid three rows behind a tap, and the
///    Schedule tab's only unique row was an "arrive in {city}" event with no
///    time — a fabricated fact. The rail is now always visible.
/// 3. **No repeated facts.** Route and date appeared three times (hero
///    monogram, summary card, trip-summary table) and the return date twice.
///    The card is the glance, the rail is the detail, and the trip-summary
///    table is gone.
///
/// Price and availability come from [SeatChartBookingService.publicSummary],
/// NOT from `tour.buses` — that list is always empty for an anonymous customer,
/// which is why this page showed no price and a permanent "open for requests".
class CustomerTourDetailScreen extends StatefulWidget {
  final Tour tour;

  const CustomerTourDetailScreen({super.key, required this.tour});

  @override
  State<CustomerTourDetailScreen> createState() =>
      _CustomerTourDetailScreenState();
}

class _CustomerTourDetailScreenState extends State<CustomerTourDetailScreen> {
  TourPublicSummary _summary = TourPublicSummary.pending;

  /// The fetch came back without answering. Distinguishes "still in flight"
  /// (draw a skeleton) from "we asked and got nothing" (offer a retry) — both
  /// of which look identical on [TourPublicSummary] itself, because
  /// `publicSummary` swallows its own errors and returns `pending` either way.
  /// Without this the seats block would shimmer forever on a dropped
  /// connection, which is a worse lie than an error.
  bool _summaryFailed = false;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  /// Never throws: [SeatChartBookingService.publicSummary] answers
  /// [TourPublicSummary.pending] on any failure, so an offline customer or an
  /// environment without migration 052 simply sees the page without a price
  /// and seat count rather than an error.
  Future<void> _loadSummary() async {
    if (_summaryFailed) setState(() => _summaryFailed = false);
    final summary = await SeatChartBookingService().publicSummary(
      widget.tour.id,
    );
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _summaryFailed = !summary.loaded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final t = widget.tour;
    final hasDescription = (t.description ?? '').trim().isNotEmpty;
    final hasOrganiser = (t.createdBy ?? '').trim().isNotEmpty;
    // The RPC is still in flight. Distinct from "it answered and there are no
    // buses" (render nothing) and from "it failed" (the summary card already
    // says so and offers the retry — no need for a second complaint here).
    final busesLoading = !_summary.loaded && !_summaryFailed;

    return UgamScaffold(
      extendBody: true,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              tour: t,
              summary: _summary,
              summaryFailed: _summaryFailed,
              onRetrySummary: _loadSummary,
              onBack: () => AppNav.pop(context),
              onShare: () async {
                HapticFeedback.lightImpact();
                await WhatsAppService().copyAnnouncementToClipboard(tour: t);
              },
            ),
          ),
          // Below the hero header, above the detail. Zero-height unless
          // something is published for this slot.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.md,
                UgamSpacing.gutter,
                0,
              ),
              child: const ContentSlot(ContentSlots.customerTourDetailTop),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              0,
              UgamSpacing.gutter,
              UgamSpacing.dockClearance,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate.fixed([
                // Order is deliberate and set by the operator: describe the
                // trip, state its facts, offer a way to ASK about it, and only
                // then lay out when it runs. Contact sits above the timeline on
                // purpose — a customer with a question should reach the
                // organiser before scrolling past the itinerary, not after it.
                if (hasDescription) ...[
                  _SectionEyebrow(
                    label: tr('customer_tour_detail.section_about_tour'),
                    c: c,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(UgamSpacing.lg),
                    decoration: BoxDecoration(
                      color: c.cardElev,
                      borderRadius: BorderRadius.circular(UgamRadius.card),
                    ),
                    child: Text(
                      t.description!.trim(),
                      style: UgamText.body.copyWith(color: c.ink),
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                ],
                _SectionEyebrow(
                  label: tr('customer_tour_detail.section_journey'),
                  c: c,
                ),
                const SizedBox(height: UgamSpacing.md),
                _JourneyBlock(tour: t, c: c),
                if (hasOrganiser) ...[
                  const SizedBox(height: UgamSpacing.xl),
                  _SectionEyebrow(
                    label: tr('customer_tour_detail.section_contact'),
                    c: c,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  _ContactOrganiserButton(tour: t, c: c),
                ],
                // Buses come from the public RPC, never from `tour.buses` —
                // that list is empty for anon, which is why this section never
                // rendered for a customer before.
                //
                // The section now holds its shape while the RPC is in flight
                // instead of appearing out of nowhere a beat after the page
                // does: a bus card either exists or it doesn't, and the reader
                // should not have to watch the page decide.
                if (busesLoading || _summary.hasBuses) ...[
                  const SizedBox(height: UgamSpacing.xl),
                  _SectionEyebrow(
                    label: tr('customer_tour_detail.section_bus'),
                    c: c,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  if (busesLoading)
                    const _BusCardSkeleton()
                  else
                    for (final bus in _summary.buses) ...[
                      _BusCard(bus: bus, c: c),
                      if (bus != _summary.buses.last)
                        const SizedBox(height: UgamSpacing.sm),
                    ],
                ],
                // The code the customer quotes when they message the organiser
                // — the same one the WhatsApp greeting embeds. It was reachable
                // only by sending a message; stating it here closes the page
                // with a fact instead of with dead space.
                const SizedBox(height: UgamSpacing.xxl),
                Center(
                  child: Text(
                    '${tr('customer_tour_detail.label_tour_id')}'
                    '  ·  ${WhatsAppService.tourCode(t.id)}',
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink3),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _StickyBookCta(tour: t, summary: _summary),
    );
  }
}

// ─── HEADER ───────────────────────────────────────────────────────────

/// Photo strip + summary card, or — when the tour has no photo — just the
/// summary card under a bare chrome row.
class _Header extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;
  final bool summaryFailed;
  final VoidCallback onRetrySummary;
  final VoidCallback onBack;
  final VoidCallback onShare;

  const _Header({
    required this.tour,
    required this.summary,
    required this.summaryFailed,
    required this.onRetrySummary,
    required this.onBack,
    required this.onShare,
  });

  /// Decode the photo at the width we actually paint. The picker stores at
  /// maxWidth 1600, so without this a 200pt strip decodes a ~6.8 MB bitmap.
  /// Same guard the admin hero uses.
  static int _decodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final physical = (mq.size.width * mq.devicePixelRatio).round();
    if (physical <= 0) return 800;
    return physical > 1600 ? 1600 : physical;
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final hasPhoto = (tour.broadcastImageUrl ?? '').trim().isNotEmpty;
    final card = _SummaryCard(
      tour: tour,
      summary: summary,
      summaryFailed: summaryFailed,
      onRetrySummary: onRetrySummary,
    );

    if (!hasPhoto) {
      // The 99% case. No photo means no illustration — a generated backdrop
      // conveys nothing and costs the whole top of the screen, so the card
      // starts right under the chrome and the price is above the fold.
      return Padding(
        padding: EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          topInset + UgamSpacing.sm,
          UgamSpacing.gutter,
          UgamSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ChromeRow(onBack: onBack, onShare: onShare, onPhoto: false),
            const SizedBox(height: UgamSpacing.lg),
            card,
          ],
        ),
      );
    }

    final photoHeight = UgamScale.px(context, 200);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: photoHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                tour.broadcastImageUrl!.trim(),
                fit: BoxFit.cover,
                cacheWidth: _decodeWidth(context),
                // While loading, or if the object is missing, fall back to the
                // backdrop so the strip never flashes raw or broken.
                loadingBuilder: (ctx, child, progress) => progress == null
                    ? child
                    : UgamBusBackdrop(
                        seed: tour.id,
                        label: _routeInitials(tour.fromCity, tour.toCity),
                      ),
                errorBuilder: (_, _, _) => UgamBusBackdrop(
                  seed: tour.id,
                  label: _routeInitials(tour.fromCity, tour.toCity),
                ),
              ),
              // Scrim only where the chrome sits — enough to keep the back and
              // share controls legible over any photo.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x8C000000), Color(0x00000000)],
                    stops: [0.0, 0.55],
                  ),
                ),
              ),
              Positioned(
                left: UgamSpacing.gutter,
                right: UgamSpacing.gutter,
                top: topInset + UgamSpacing.sm,
                child: _ChromeRow(
                  onBack: onBack,
                  onShare: onShare,
                  onPhoto: true,
                ),
              ),
            ],
          ),
        ),
        // Pulled up so the card reads as one unit with the photo. Transform
        // does not affect layout, so the Column still reserves the card's full
        // height and the pull simply becomes the gap below it — no overlap
        // with the body, and no magic clearance constant to keep in sync.
        Transform.translate(
          offset: const Offset(0, -UgamSpacing.xl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.gutter,
            ),
            child: card,
          ),
        ),
      ],
    );
  }
}

class _ChromeRow extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onShare;

  /// Over a photo the controls need a dark scrim and white glyphs; on the page
  /// they take the card fill and normal ink, or they read as floating blobs.
  final bool onPhoto;

  const _ChromeRow({
    required this.onBack,
    required this.onShare,
    required this.onPhoto,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ChromeCircle(
          icon: Icons.arrow_back_rounded,
          onTap: onBack,
          onPhoto: onPhoto,
        ),
        const Spacer(),
        _ChromeCircle(
          icon: Icons.ios_share_rounded,
          onTap: onShare,
          onPhoto: onPhoto,
        ),
      ],
    );
  }
}

class _ChromeCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool onPhoto;

  const _ChromeCircle({
    required this.icon,
    required this.onTap,
    required this.onPhoto,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: UgamScale.tap(context, 44),
        height: UgamScale.tap(context, 44),
        decoration: BoxDecoration(
          // Over a photo neither of these can be a token: the control floats on
          // an arbitrary uploaded image, so its contrast cannot come from the
          // theme. Off the photo it is fully tokenized.
          color: onPhoto ? const Color(0x73000000) : c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 19,
          color: onPhoto ? Colors.white : c.ink,
        ),
      ),
    );
  }
}

// ─── SUMMARY CARD ─────────────────────────────────────────────────────

/// The glance: what it is, where and when it goes, and whether there is room.
/// Everything a customer needs to decide whether to keep reading, in one card
/// above the fold.
///
/// No price. This operator settles the fare over WhatsApp, so the page states
/// what the trip IS and leaves what it costs to the conversation.
class _SummaryCard extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;
  final bool summaryFailed;
  final VoidCallback onRetrySummary;

  const _SummaryCard({
    required this.tour,
    required this.summary,
    required this.summaryFailed,
    required this.onRetrySummary,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final countdown = departureCountdownLabel(tour.departureDate);

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // titleL, not titleM. This page has no app-bar title, so the tour
          // name IS the page heading and was being set two ladder steps below
          // the one the system reserves for a page title.
          Text(
            tour.title,
            style: UgamText.titleL.copyWith(color: c.ink),
            // Two lines before ellipsing: a tour title carries the festival
            // name AND the date, and truncating it to one line loses which
            // trip this is.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UgamSpacing.xs),
          // Wraps. "અમદાવાદ → અંબાજી" and its Hindi equivalent run well past
          // the width a single clamped line allows on a 375 pt phone, and the
          // route is not a fact this page can afford to clip.
          Text(
            '${tour.fromCity} → ${tour.toCity}',
            style: UgamText.bodyStrong.copyWith(color: c.ink2),
            maxLines: 2,
          ),
          if (countdown != null) ...[
            const SizedBox(height: 2),
            Text(
              countdown,
              style: UgamText.tabular(
                UgamText.caption.copyWith(color: c.ink3),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.md),
          _AvailabilityBlock(
            tour: tour,
            summary: summary,
            summaryFailed: summaryFailed,
            onRetry: onRetrySummary,
          ),
        ],
      ),
    );
  }
}

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


// ─── BUS CARD ─────────────────────────────────────────────────────────

/// One bus, as the customer may see it. Fed from `public_tour_buses`, so the
/// driver/owner phones and the owner's rent are never in this object at all.
class _BusCard extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;

  const _BusCard({required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    final departure = _busDeparture(bus.boardingPoint, bus.departureTime);
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

  /// Per-bus boarding place + departure time as `<place> · <time>`. Either part
  /// is omitted when empty; null when both are, so the caller hides the line.
  static String? _busDeparture(String boardingPoint, String? departureTime) {
    final place = boardingPoint.trim();
    final time = formatHhMm(departureTime);
    final parts = [
      if (place.isNotEmpty) place,
      ?time,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
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

/// Localized 3-letter month abbreviation, shared across customer screens.
String _monthShort(int month) {
  const keys = [
    'app.month.short.jan',
    'app.month.short.feb',
    'app.month.short.mar',
    'app.month.short.apr',
    'app.month.short.may',
    'app.month.short.jun',
    'app.month.short.jul',
    'app.month.short.aug',
    'app.month.short.sep',
    'app.month.short.oct',
    'app.month.short.nov',
    'app.month.short.dec',
  ];
  return tr(keys[month - 1]);
}

String _formatLongDate(DateTime d) =>
    '${d.day} ${_monthShort(d.month)} ${d.year}';

/// Route monogram for the backdrop fallback, e.g. "S→M" from "Surat"/"Mumbai".
/// Empty when neither city is set, so the backdrop shows just the bus motif.
String _routeInitials(String from, String to) {
  String first(String s) {
    final t = s.trim();
    return t.isEmpty ? '' : t.characters.first.toUpperCase();
  }

  final f = first(from);
  final t = first(to);
  if (f.isEmpty && t.isEmpty) return '';
  return '$f→$t';
}

/// Whole CALENDAR DAYS until departure; negative once it is behind us.
///
/// Calendar days, not elapsed hours, on purpose: a bus leaving at 5 AM tomorrow
/// is "tomorrow" when read at 11 PM tonight, but that is only 6 hours away and
/// `Duration.inDays` would floor it to 0 and say "departs today". Normalising
/// both ends to midnight first is what makes the answer match the calendar the
/// customer is looking at.
///
/// [now] is injectable so this is testable without a clock.
@visibleForTesting
int daysUntilDeparture(DateTime departure, {DateTime? now}) {
  DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  return dateOnly(departure).difference(dateOnly(now ?? DateTime.now())).inDays;
}

/// "Departs today" / "Departs tomorrow" / "Departs in 10 days", or null once
/// the departure is behind us.
String? departureCountdownLabel(DateTime departure, {DateTime? now}) {
  final days = daysUntilDeparture(departure, now: now);
  if (days < 0) return null;
  if (days == 0) return tr('customer_tour_detail.departs_today');
  if (days == 1) return tr('customer_tour_detail.departs_tomorrow');
  return tr(
    'customer_tour_detail.departs_in_days',
    namedArgs: {'n': '$days'},
  );
}
