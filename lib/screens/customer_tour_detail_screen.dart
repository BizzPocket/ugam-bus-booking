import 'package:easy_localization/easy_localization.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
import 'customer_format.dart';

part 'customer_tour_detail/header.dart';
part 'customer_tour_detail/availability_journey.dart';
part 'customer_tour_detail/bus_contact_cta.dart';

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
                // It used to copy in silence, so a tap read as "nothing
                // happened". Say where the text went and what to do with it.
                AppSnackBar.success(tr('customer_tour_detail.share_copied'));
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
                    // By index: two equal bus summaries (== by value) made
                    // `bus != last` false for both, dropping a gap.
                    for (var i = 0; i < _summary.buses.length; i++) ...[
                      _BusCard(bus: _summary.buses[i], c: c),
                      if (i < _summary.buses.length - 1)
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

String _formatLongDate(DateTime d) =>
    '${d.day} ${customerMonthShort(d.month)} ${d.year}';

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
