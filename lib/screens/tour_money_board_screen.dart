import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/money_summary.dart';
import '../models/payment_claim.dart';
import '../models/tour.dart';
import '../services/chart_hold_status.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../widgets/money_loading_skeleton.dart';
import 'bus_money_screen.dart';
import 'collection_screen.dart';
import 'trip_pnl_screen.dart';

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

  void _openBus(Tour tour, Bus bus) {
    Get.to(
      () => BusMoneyScreen(tour: tour, bus: bus),
      transition: Transition.cupertino,
    );
  }

  void _openPnl() {
    Get.to(
      () => TripPnlScreen(tourId: widget.tourId),
      transition: Transition.cupertino,
    );
  }

  /// Shortcut into the existing per-bus [CollectionScreen] — the same
  /// destination [BusMoneyScreen]'s "Collect from passengers" CTA reaches,
  /// but jumped to in one tap from the board (no detour through BusMoney).
  void _collectForBus(Tour tour, Bus bus) {
    Get.to(
      () => CollectionScreen(tour: tour, bus: bus),
      transition: Transition.cupertino,
    );
  }

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
              return UgamAppBar(
                eyebrow: tr('tour_money_board.eyebrow'),
                title: title.isEmpty
                    ? tr('tour_money_board.tour_money')
                    : title,
              );
            }),
            Expanded(
              child: Obx(() {
                final tour = _tours.getTour(widget.tourId);
                if (tour == null) {
                  // Same key, same shape as trip_pnl_screen's not-found state —
                  // a bare centred sentence read as a half-built screen.
                  return UgamEmpty(
                    icon: Icons.search_off_rounded,
                    title: tr('tour_money_board.tour_not_found'),
                  );
                }

                if (_money.isLoading.value && !_money.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }

                // A failed money load leaves the obs lists empty; without this
                // the board would render every bus at ₹0 as if the trip had no
                // money. Swap in the shared retry only when nothing is held.
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => _money.loadForTour(widget.tourId),
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
                  return UgamEmpty(
                    icon: Icons.account_balance_wallet_outlined,
                    title: tr('tour_money_board.no_buses'),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => _money.refreshForTour(widget.tourId),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.sm,
                      UgamSpacing.gutter,
                      UgamSpacing.xl,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    children: [
                      _PnlEntryCard(
                        summary: tourSummary,
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
                          letterSpacing: 1.4,
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
                      if (tourSummary.hasOrphanMoney) ...[
                        _OrphanMoneyCard(summary: tourSummary, c: c),
                      ],
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

/// Pending chart soft-holds — Pay later locks seats without UPI confirm.
class _SeatHoldsCard extends StatelessWidget {
  final List<Map<String, dynamic>> holds;
  final MoneyController money;
  final UgamColorSet c;

  const _SeatHoldsCard({
    required this.holds,
    required this.money,
    required this.c,
  });

  Future<void> _payLater(Map<String, dynamic> hold) async {
    final id = hold['id']?.toString();
    if (id == null || id.isEmpty) return;
    try {
      await money.payLaterFinalizeHold(id);
      AppSnackBar.success(tr('tour_money_board.holds_finalized'));
    } catch (_) {
      AppSnackBar.error(tr('tour_money_board.holds_finalize_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      tone: UgamCardTone.warm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('tour_money_board.holds_pending_title'),
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: 4),
          Text(
            tr('tour_money_board.holds_pending_body'),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (final hold in holds) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (hold['name']?.toString().trim().isNotEmpty ?? false)
                            ? hold['name'].toString()
                            : (hold['phone']?.toString() ?? '—'),
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                      ),
                      Text(
                        hold['phone']?.toString() ?? '',
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                      // WHICH berths this hold is blocking, and for how much
                      // longer. Without it "Pay later" was a decision made
                      // blind — the card showed only a name and a number.
                      Builder(
                        builder: (_) {
                          final seats = summariseHoldSeats(hold['seats']);
                          final until = DateTime.tryParse(
                            hold['expires_at']?.toString() ?? '',
                          );
                          final left = until?.difference(DateTime.now());
                          final parts = <String>[
                            if (seats.seatIds.isNotEmpty)
                              seats.seatIds.join(', '),
                            if (seats.berths > 0)
                              tr(
                                'tour_money_board.holds_berths',
                                namedArgs: {'n': '${seats.berths}'},
                              ),
                            if (left != null && !left.isNegative)
                              tr(
                                'tour_money_board.holds_time_left',
                                namedArgs: {
                                  'time': '${left.inMinutes}:'
                                      '${left.inSeconds.remainder(60).toString().padLeft(2, '0')}',
                                },
                              ),
                          ];
                          if (parts.isEmpty) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              parts.join(' · '),
                              style: UgamText.micro.copyWith(color: c.ink3),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                UgamButton(
                  label: tr('tour_money_board.holds_pay_later'),
                  kind: UgamButtonKind.tonal,
                  onPressed: () => _payLater(hold),
                ),
              ],
            ),
            if (hold != holds.last) const SizedBox(height: UgamSpacing.md),
          ],
        ],
      ),
    );
  }
}

/// Pending UPI advance claims — confirm posts ledger money; reject leaves fare due.
class _UpiClaimsCard extends StatelessWidget {
  final List<PaymentClaim> claims;
  final Tour tour;
  final MoneyController money;
  final UgamColorSet c;

  const _UpiClaimsCard({
    required this.claims,
    required this.tour,
    required this.money,
    required this.c,
  });

  String _labelFor(PaymentClaim claim) {
    if (claim.passengerId != null) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == claim.passengerId);
      if (p != null) return p.name;
    }
    final name = claim.payerName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final phone = claim.payerPhone?.trim();
    if (phone != null && phone.isNotEmpty) return phone;
    return tr('tour_money_board.upi_unknown_payer');
  }

  Future<void> _confirm(BuildContext context, PaymentClaim claim) async {
    try {
      await money.confirmPaymentClaim(claim.id);
      AppSnackBar.success(tr('tour_money_board.upi_confirmed'));
    } catch (e) {
      AppSnackBar.error(tr('tour_money_board.upi_confirm_failed'));
    }
  }

  Future<void> _reject(BuildContext context, PaymentClaim claim) async {
    try {
      await money.rejectPaymentClaim(claim.id);
      AppSnackBar.info(tr('tour_money_board.upi_rejected'));
    } catch (e) {
      AppSnackBar.error(tr('tour_money_board.upi_reject_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      tone: UgamCardTone.warm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('tour_money_board.upi_pending_title'),
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: 4),
          Text(
            tr('tour_money_board.upi_pending_body'),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (final claim in claims) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _labelFor(claim),
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                      ),
                      Text(
                        [
                          Formatters.formatMoneyInr(claim.amountRupees),
                          if (claim.upiRef != null && claim.upiRef!.isNotEmpty)
                            tr('tour_money_board.upi_ref',
                                namedArgs: {'ref': claim.upiRef!}),
                        ].join(' · '),
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ),
                UgamButton(
                  label: tr('tour_money_board.upi_confirm'),
                  kind: UgamButtonKind.goodTonal,
                  onPressed: () => _confirm(context, claim),
                ),
                const SizedBox(width: UgamSpacing.sm),
                UgamButton(
                  label: tr('tour_money_board.upi_reject'),
                  kind: UgamButtonKind.ghost,
                  onPressed: () => _reject(context, claim),
                ),
              ],
            ),
            if (claim != claims.last) const SizedBox(height: UgamSpacing.md),
          ],
        ],
      ),
    );
  }
}

// ─── Orphan (unassigned-bus) money ──────────────────────────────────────────

/// Money recorded against a bus that is no longer on this tour.
///
/// The rows above are drawn one-per-bus from `tour.buses`, while the totals
/// capsule folds EVERY row carrying the tour id — so without this card the
/// per-bus figures silently stop adding up to the total and nothing on screen
/// says why. The money is deliberately still counted in the totals (it is real
/// cash and real cost); this card only names the remainder, in the same
/// surface-don't-hide spirit as the per-bus detached-cash card.
class _OrphanMoneyCard extends StatelessWidget {
  final TourMoneySummary summary;
  final UgamColorSet c;

  const _OrphanMoneyCard({required this.summary, required this.c});

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (summary.orphanExpenses.abs() > 0.005)
        tr(
          'tour_money_board.orphan_expenses',
          namedArgs: {'n': Formatters.formatMoneyInr(summary.orphanExpenses)},
        ),
      if (summary.orphanCollected.abs() > 0.005)
        tr(
          'tour_money_board.orphan_collected',
          namedArgs: {'n': Formatters.formatMoneyInr(summary.orphanCollected)},
        ),
      if (summary.orphanIncome.abs() > 0.005)
        tr(
          'tour_money_board.orphan_income',
          namedArgs: {'n': Formatters.formatMoneyInr(summary.orphanIncome)},
        ),
    ];

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      tone: UgamCardTone.warm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 16, color: c.warm),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  tr('tour_money_board.orphan_title'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: UgamText.tabular(
                  UgamText.caption.copyWith(color: c.ink2),
                ),
              ),
            ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('tour_money_board.orphan_body'),
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }
}

// ─── Profit & Loss entry card ───────────────────────────────────────────────

/// Tappable banner at the top of the board → opens the per-trip [TripPnlScreen]
/// (per-bus + per-handler P&L). Previews the trip's TRUE net (billed − costs)
/// so the headline answer is visible before tapping in.
class _PnlEntryCard extends StatelessWidget {
  final TourMoneySummary summary;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _PnlEntryCard({
    required this.summary,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final billed = summary.totalNetBilled;
    final inProfit = billed >= 0;
    final tone = inProfit ? c.good : c.danger;
    return UgamCard.plain(
      key: const ValueKey('pnl-hero'),
      onTap: onTap,
      elev: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Soft copper halo — the screen's one signature glow (§A4). Depth
          // from light, not borders: this hero sits above the flatter rows.
          // Purely decorative, so the whole halo (size AND offset) rides
          // [UgamScale.px]: unscaled it kept a full 200pt radius while the card
          // shrank around it, bleeding further across the card on small phones.
          Positioned(
            left: -UgamScale.px(context, 30),
            top: -UgamScale.px(context, 60),
            child: IgnorePointer(
              child: Container(
                width: UgamScale.px(context, 200),
                height: UgamScale.px(context, 200),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [c.glow, c.glow.withValues(alpha: 0)],
                    stops: const [0.0, 0.7],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Container(
                width: UgamScale.px(context, 40),
                height: UgamScale.px(context, 40),
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: BorderRadius.circular(UgamRadius.stat),
                ),
                child: Icon(
                  Icons.insights_rounded,
                  size: UgamScale.px(context, 20),
                  color: c.accent,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('trip_pnl.title').toUpperCase(),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      inProfit
                          ? tr('tour_money_board.trip_in_profit')
                          : tr('tour_money_board.trip_at_loss'),
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      Formatters.formatMoneyInr(billed.abs()),
                      style: UgamText.tabular(
                        UgamText.numXl.copyWith(color: tone),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('trip_pnl.entry_sub'),
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                    // This card headlines BILLED net while the sticky capsule at
                    // the foot of the same screen headlines CASH net. Two right
                    // answers to two different questions — but unlabelled, one
                    // screen appeared to disagree with itself.
                    const SizedBox(height: 2),
                    Text(
                      tr('money.basis_billed'),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Per-bus money row ──────────────────────────────────────────────────────

class _BusMoneyRow extends StatelessWidget {
  final Bus bus;
  final BusMoneySummary summary;
  final BusMoneyState state;
  final VoidCallback onTap;
  final VoidCallback onCollect;
  final UgamColorSet c;

  const _BusMoneyRow({
    required this.bus,
    required this.summary,
    required this.state,
    required this.onTap,
    required this.onCollect,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // A bus that still owes money leads with its ONE action figure — the
    // handover still due, else the passenger shortfall to collect. A settled
    // bus shows what it collected in mint; a bus with nothing owed and nothing
    // collected reads as a quiet "no activity". The card tone carries the same
    // attention signal the old ring did; a status WORD is added only where it
    // says something the tinted figure doesn't (settled / not-started).
    final hasHandoverDue = summary.outstandingHandover > 0.005;
    final (
      UgamCardTone cardTone,
      String numLabel,
      double numAmount,
      Color numColor,
      String? statusWord,
      UgamStatusTone statusTone,
    ) = switch (state) {
      BusMoneyState.actionNeeded => (
        // Tone tracks the figure: a collect shortfall is red, a handover due
        // is rose — so the card's tint says WHICH action at a glance (§A2/§A4).
        hasHandoverDue ? UgamCardTone.warm : UgamCardTone.danger,
        hasHandoverDue
            ? tr('tour_money_board.handover')
            : tr('tour_money_board.to_collect'),
        hasHandoverDue ? summary.outstandingHandover : summary.toCollectTotal,
        hasHandoverDue ? c.warm : c.danger,
        null,
        UgamStatusTone.warm,
      ),
      BusMoneyState.settled => (
        UgamCardTone.good,
        tr('tour_money_board.collected'),
        summary.collected,
        c.good,
        tr('tour_money_board.settled'),
        UgamStatusTone.good,
      ),
      BusMoneyState.neutral => (
        UgamCardTone.none,
        tr('tour_money_board.to_collect'),
        summary.toCollectTotal,
        c.ink2,
        tr('tour_money_board.no_activity'),
        UgamStatusTone.neutral,
      ),
    };

    // Collected / handover only carry information once cash has changed hands —
    // until then they are ₹0 filler, so the strip is hidden and the card
    // collapses to identity + action figure + collect.
    final hasMoved =
        summary.collected > 0.005 ||
        summary.handedOver > 0.005 ||
        summary.income > 0.005;

    return UgamCard.plain(
      key: ValueKey('bus-money-row-${bus.id}'),
      tone: cardTone,
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Identity + the ONE action figure, on a single line ─────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: UgamScale.px(context, 34),
                height: UgamScale.px(context, 34),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.seat),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.directions_bus_filled_rounded,
                  size: UgamScale.px(context, 17),
                  color: c.ink2,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bus.name,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    // Type + a compact status word (settled / not-started);
                    // action-needed shows none — its tinted figure says it.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            bus.busType,
                            style: UgamText.caption.copyWith(color: c.ink3),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (statusWord != null) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          UgamStatusDot(label: statusWord, tone: statusTone),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // The action figure rides on the identity line — right-aligned,
              // tabular, tinted by state — so the row answers "how much?" in
              // one glance without a second full-width headline block. Skipped
              // when settled: the mint "Settled" dot + the collected/handover
              // pills below already tell that story, so a figure here would
              // just duplicate a pill.
              if (state != BusMoneyState.settled) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      numLabel.toUpperCase(),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      Formatters.formatMoneyInr(numAmount),
                      style: UgamText.tabular(
                        UgamText.numLg.copyWith(color: numColor),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                const SizedBox(width: UgamSpacing.xs),
              ],
              Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
            ],
          ),
          // Extra income the handler holds (cabin/gallery/other) — surfaced
          // compactly, and only when there is any.
          if (summary.income > 0.005) ...[
            const SizedBox(height: UgamSpacing.sm),
            Text(
              '+${Formatters.formatMoneyInr(summary.income)} '
              '${tr('bus_money.stat_income')}',
              style: UgamText.tabular(
                UgamText.micro.copyWith(
                  color: c.good,
                  fontWeight: FontWeight.w700,
                ),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // ── Collected + handover — only once money has moved ───────
          if (hasMoved) ...[
            const SizedBox(height: UgamSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _MoneyPill(
                    label: tr('tour_money_board.collected'),
                    value: Formatters.formatMoneyInr(summary.collected),
                    c: c,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: _MoneyPill(
                    label: tr('tour_money_board.handover'),
                    value: Formatters.formatMoneyInr(summary.handedOver),
                    c: c,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: UgamSpacing.md),
          // One-tap shortcut straight into this bus's CollectionScreen. The row
          // itself still opens the full per-bus detail view (to-collect,
          // to-return, expenses live there). Tonal so it never competes with the
          // single solid-champagne totals capsule below.
          UgamButton(
            label: tr('tour_money_board.collect'),
            icon: Icons.groups_rounded,
            kind: UgamButtonKind.tonal,
            expand: true,
            onPressed: onCollect,
          ),
        ],
      ),
    );
  }
}

/// Compact tonal money chip — a quiet `accentFill` pill carrying a micro label
/// over a tabular value. Used in pairs on a bus row so the two everyday figures
/// (collected / handover) read as one calm strip instead of a metric grid.
class _MoneyPill extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _MoneyPill({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        // `sm`, matching _CapsulePill below — the two visually identical chips
        // sat 4pt apart in height on the same screen.
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.numLg.copyWith(color: c.ink2, fontSize: 15),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Sticky tour-totals capsule ─────────────────────────────────────────────

class _TotalsCapsule extends StatelessWidget {
  final TourMoneySummary summary;
  final UgamColorSet c;

  const _TotalsCapsule({required this.summary, required this.c});

  @override
  Widget build(BuildContext context) {
    final outstanding = summary.totalOutstandingHandover;
    final settled = outstanding.abs() <= 0.005;

    // One hero number (outstanding) on the left, two compact pills (collected,
    // net) on the right — a single tight strip in the thumb zone instead of the
    // old 5-number grid. Kept short (~88dp content) so the chart still breathes.
    return UgamStickyCTA(
      child: UgamCard.plain(
        elev: true,
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── Hero: outstanding handover ─────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          tr(
                            'tour_money_board.outstanding_handover',
                          ).toUpperCase(),
                          style: UgamText.micro.copyWith(color: c.ink3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      UgamStatusDot(
                        label: settled
                            ? tr('tour_money_board.all_settled')
                            : tr('tour_money_board.open'),
                        tone: settled
                            ? UgamStatusTone.good
                            : UgamStatusTone.warm,
                      ),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                  // Scale a long outstanding figure down to fit rather than
                  // ellipsize it — the thumb-zone capsule must never clip the
                  // very number it exists to show (e.g. "-₹1,81,000").
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      Formatters.formatMoneyInr(outstanding),
                      style: UgamText.tabular(
                        UgamText.numXl.copyWith(
                          color: settled ? c.good : c.warm,
                        ),
                      ),
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            // ── Two compact pills: collected + net ─────────────────
            Flexible(
              child: _CapsulePill(
                label: tr('tour_money_board.collected'),
                value: Formatters.formatMoneyInr(summary.totalCollected),
                c: c,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: _CapsulePill(
                // "NET (CASH)", not "NET": the P&L card higher up this same
                // screen headlines the BILLED net. The pill is too small for a
                // caption, so the basis rides in the label itself.
                label: tr('tour_money_board.net_cash'),
                value: Formatters.formatMoneyInr(summary.totalNet),
                c: c,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tight tonal chip used inside the sticky totals capsule: a micro cap over a
/// tabular value, sized for a thumb-zone strip rather than a full metric tile.
class _CapsulePill extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _CapsulePill({
    required this.label,
    required this.value,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.numLg.copyWith(color: c.ink, fontSize: 15),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
