import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../components/content_block_view.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/money_summary.dart';
import '../models/payment_claim.dart';
import '../models/pnl_confidence.dart';
import '../models/tour.dart';
import '../services/chart_hold_status.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/in_flight.dart';
import '../widgets/cash_so_far_line.dart';
import '../widgets/money_loading_skeleton.dart';
import 'bus_money_screen.dart';
import 'collection_screen.dart';
import 'trip_pnl_screen.dart';

part 'tour_money_board/money_cards.dart';
part 'tour_money_board/bus_money_row.dart';
part 'tour_money_board/totals_capsule.dart';

/// TOUR MONEY BOARD — a scannable, mostly read-only roll-up of every bus on
/// a tour. Each row shows that bus's money summary (collected / to-collect /
/// to-return / expenses / outstanding handover) and carries a warm attention
/// ring ONLY when it needs action (outstanding handover or a shortfall still
/// to collect), a `good` ring when fully settled, and a neutral edge
/// otherwise. A sticky tour-totals capsule pins the [TourMoneySummary] in the
/// thumb zone. Tapping a bus opens the existing per-bus [BusMoneyScreen].
///
/// All aggregation is delegated to [MoneyController] (read-only helpers); this
/// screen never mutates money state. Colour comes exclusively from
/// [UgamColors.of] and every figure uses tabular numerals, per the locked DNA.
class TourMoneyBoardScreen extends StatefulWidget {
  final String tourId;

  const TourMoneyBoardScreen({super.key, required this.tourId});

  @override
  State<TourMoneyBoardScreen> createState() => _TourMoneyBoardScreenState();
}

/// Pads a full-height state (empty / error / skeleton) back out to the whole
/// body slot.
///
/// The board's body sits in a LOOSE flex child so a short list can shrink-wrap
/// and let the totals capsule rise to meet it. A scrollable fills a loose slot
/// on its own, but [UgamEmpty] is a [Center] — under loose constraints it
/// shrink-wraps to its own content and its "centred" state would clamp itself
/// to the app bar instead of the screen.
Widget _fillSlot(Widget child) => SizedBox.expand(child: child);

class _TourMoneyBoardScreenState extends State<TourMoneyBoardScreen> {
  MoneyController get _money => Get.find<MoneyController>();
  TourController get _tours => Get.find<TourController>();

  /// True only when the money load failed AND there is nothing already held to
  /// keep on screen — so a transient read failure shows a retry instead of an
  /// all-zero board. Reads the money obs inside the calling [Obx], so it stays
  /// reactive: a successful retry flips [MoneyController.loadFailed] and refills
  /// the lists, re-running the builder.
  bool get _showLoadError =>
      _money.loadFailed.value &&
      _money.collections.isEmpty &&
      _money.expenses.isEmpty &&
      _money.handovers.isEmpty &&
      _money.incomes.isEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _money.loadForTour(widget.tourId);
    });
  }

  void _go(Widget Function() page) =>
      Get.to(page, transition: Transition.cupertino);

  void _openBus(Tour tour, Bus bus) =>
      _go(() => BusMoneyScreen(tour: tour, bus: bus));

  void _openPnl() => _go(() => TripPnlScreen(tourId: widget.tourId));

  /// Shortcut into the existing per-bus [CollectionScreen] — the same
  /// destination [BusMoneyScreen]'s "Collect from passengers" CTA reaches,
  /// but jumped to in one tap from the board (no detour through BusMoney).
  void _collectForBus(Tour tour, Bus bus) =>
      _go(() => CollectionScreen(tour: tour, bus: bus));

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Obx(() {
              final title = _tours.getTour(widget.tourId)?.title ?? '';
              // The tour title is USER data and the longest string on this
              // screen. In the title slot (titleL, ~291pt beside the back
              // button) a Gujarati tour name clips after ~14 glyphs — it read
              // as "શ્રી દ્વારકા-સોમ…". So the FIXED screen name takes the
              // title slot, where the length is known in all three locales,
              // and the tour name drops to the subtitle: caption metrics fit
              // roughly 2.5× the glyphs, so the name survives whole. The
              // eyebrow goes with it — "TOUR MONEY" stacked over "Tour money"
              // was the same words twice.
              return UgamAppBar(
                title: tr('tour_money_board.tour_money'),
                subtitle: title.isEmpty ? null : title,
              );
            }),
            // LOOSE flex child, not Expanded: a short board (one or two buses)
            // used to strand ~250pt of undesigned void between the last bus
            // card and the bottom-anchored totals capsule. Shrink-wrapped, the
            // list takes only the height it needs and the capsule rises to
            // meet it; once the board outgrows the viewport the list is capped
            // at the remaining space and the capsule pins to the bottom again.
            Flexible(
              child: Obx(() {
                final tour = _tours.getTour(widget.tourId);
                if (tour == null) {
                  // Same key, same shape as trip_pnl_screen's not-found state —
                  // a bare centred sentence read as a half-built screen.
                  return _fillSlot(
                    UgamEmpty(
                      icon: Icons.search_off_rounded,
                      title: tr('tour_money_board.tour_not_found'),
                    ),
                  );
                }

                if (_money.isLoading.value && !_money.loadedOnce.value) {
                  return _fillSlot(const MoneyLoadingSkeleton());
                }

                // A failed money load leaves the obs lists empty; without this
                // the board would render every bus at ₹0 as if the trip had no
                // money. Swap in the shared retry only when nothing is held.
                if (_showLoadError) {
                  return _fillSlot(
                    UgamEmpty.error(
                      onRetry: () => _money.loadForTour(widget.tourId),
                    ),
                  );
                }

                final buses = tour.buses;
                // Touch the money obs lists so Obx re-renders on any change.
                final summaries = _money.summariesForBuses(
                  buses.map((b) => b.id),
                );
                // One computation shared by the P&L card and the orphan row —
                // they must describe the same numbers.
                final tourSummary = _money.tourSummary();

                if (buses.isEmpty) {
                  return _fillSlot(
                    UgamEmpty(
                      icon: Icons.account_balance_wallet_outlined,
                      title: tr('tour_money_board.no_buses'),
                    ),
                  );
                }

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  // (Unset used to mean `colorScheme.primary`, i.e. the accent;
                  // there is no theme hook for a refresh spinner.)
                  color: c.ink2,
                  onRefresh: () => _money.refreshForTour(widget.tourId),
                  child: ListView(
                    // Sizes to its content inside the loose slot above, so the
                    // totals capsule follows the last bus card up the screen.
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.sm,
                      UgamSpacing.gutter,
                      // The capsule's own UgamStickyCTA adds `lg` above itself;
                      // `xl` here on top of that opened a 32pt seam that read
                      // as another gap once the two met.
                      UgamSpacing.sm,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    children: [
                      // Operator-facing slot: settlement reminders, a note
                      // about a rate change, guidance during an incident.
                      // Content only — every figure below is computed from the
                      // ledger and must never come from a document.
                      const ContentSlot(
                        ContentSlots.adminMoneyTop,
                        role: 'admin',
                      ),
                      _PnlEntryCard(
                        summary: tourSummary,
                        confidence: PnlConfidence.of(
                          tourSummary,
                          tour.status,
                        ),
                        onTap: _openPnl,
                        c: c,
                      ),
                      if (_money.pendingClaims.isNotEmpty) ...[
                        const SizedBox(height: UgamSpacing.md),
                        _UpiClaimsCard(
                          claims: _money.pendingClaims,
                          tour: tour,
                          money: _money,
                          c: c,
                        ),
                      ],
                      if (_money.pendingSeatHolds.isNotEmpty) ...[
                        const SizedBox(height: UgamSpacing.md),
                        _SeatHoldsCard(
                          holds: _money.pendingSeatHolds.toList(),
                          money: _money,
                          c: c,
                        ),
                      ],
                      const SizedBox(height: UgamSpacing.md),
                      Text(
                        tr('tour_money_board.per_bus'),
                        style: UgamText.micro.copyWith(
                          color: c.ink3,
                          letterSpacing: UgamText.tracking(1.4),
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.md),
                      for (var i = 0; i < buses.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.md,
                          ),
                          child: _BusMoneyRow(
                            bus: buses[i],
                            summary: summaries[i],
                            state: _money.stateForBusSummary(summaries[i]),
                            onTap: () => _openBus(tour, buses[i]),
                            onCollect: () => _collectForBus(tour, buses[i]),
                            c: c,
                          ),
                        ),
                      // Money sitting on a bus this tour no longer lists. It IS
                      // inside the totals capsule below, so without this row the
                      // per-bus figures visibly fail to add up to the total with
                      // nothing on screen explaining the difference.
                      if (tourSummary.hasOrphanMoney)
                        _OrphanMoneyCard(summary: tourSummary, c: c),
                    ],
                  ),
                );
              }),
            ),
            // Sticky tour-totals capsule in the thumb zone.
            Obx(() {
              final tour = _tours.getTour(widget.tourId);
              // Hide the totals strip while the retry state is showing — an
              // all-zero capsule under a load-error message would contradict it.
              if (tour == null || tour.buses.isEmpty || _showLoadError) {
                return const SizedBox.shrink();
              }
              return _TotalsCapsule(summary: _money.tourSummary(), c: c);
            }),
          ],
        ),
      ),
    );
  }
}
