import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/finance_controller.dart';
import '../design/ugam.dart';
import '../models/tour_finance.dart';
import '../utils/formatters.dart';
import '../widgets/money_loading_skeleton.dart';
import 'create_tour_screen.dart';
import 'tour_money_board_screen.dart';

/// FINANCE — the cross-tour Profit & Loss report.
///
/// Sums the realised revenue (net cash collected) and expenses of every
/// COMPLETED tour, scoped to a period (this month / this year / all time), and
/// shows the headline net profit, a few roll-up stats, and one tappable row per
/// past trip. Tapping a trip opens its existing per-tour money board, so the
/// completed tour's full money record stays reachable — nothing is deleted, it
/// just lives here now.
///
/// All aggregation is delegated to [FinanceController]; colour comes only from
/// [UgamColors.of] and every figure uses tabular numerals, per the locked DNA.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

/// What the period's numbers actually MEAN — the distinction the report used to
/// throw away by rendering every one of these as the same confident `₹0`.
///
/// The three "no data" shapes are genuinely different problems with genuinely
/// different fixes, and the screen now says which one you are looking at:
///
/// * [periodEmpty] — trips exist, none of them ENDED inside the chosen period.
///   Nothing is wrong; the filter is too narrow. Fix = widen the period.
/// * [noTrips]     — there is no trip anywhere, in any period. Fix = make one.
/// * [noMoney]     — trips exist in the period but not one rupee has been
///   collected or spent against them. Fix = record the first entry.
/// * [breakEven]   — money genuinely moved and cancelled out. This is the ONLY
///   one of the four where `₹0` is a real answer, and it is the reading the old
///   screen silently gave to all four.
enum _ReportState { periodEmpty, noTrips, noMoney, breakEven, profit, loss }

class _FinanceScreenState extends State<FinanceScreen> {
  FinanceController get _finance => Get.find<FinanceController>();

  // Default to this month — running trips are included in financesFor, so the
  // report is no longer empty mid-season the way it was under completed-only.
  // All-time / this-year remain one tap away.
  FinancePeriod _period = FinancePeriod.thisMonth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Refetch when a money write happened since the last load, so the report
      // can't disagree with the per-tour money board.
      _finance.refreshIfStale();
    });
  }

  void _openTour(TourFinance tf) {
    // Cupertino, matching every other push into or between the money screens
    // (tour_money_board_screen.dart:62,:69,:79 and bus_money_screen.dart:366)
    // so the same destination animates identically wherever it is opened from.
    Get.to(
      () => TourMoneyBoardScreen(tourId: tf.tourId),
      transition: Transition.cupertino,
    );
  }

  /// The real create-trip destination, pushed exactly the way the charts screen
  /// empty state pushes it (charts_screen.dart:205) — an invented route or a
  /// second animation for the same screen is how an app starts feeling stitched
  /// together.
  void _createTour() {
    Get.to(
      () => const CreateTourScreen(),
      transition: Transition.cupertino,
    );
  }

  /// Classify the period. See [_ReportState] for why this exists.
  _ReportState _stateFor(FinanceTotals t) {
    if (t.tourCount == 0) {
      // Only worth asking on a narrowed period — "all time" is already the
      // widest answer there is, so an empty all-time really means no trips.
      final anyEver = _period != FinancePeriod.allTime &&
          _finance.financesFor(FinancePeriod.allTime).isNotEmpty;
      return anyEver ? _ReportState.periodEmpty : _ReportState.noTrips;
    }
    if (t.revenue == 0 && t.income == 0 && t.expenses == 0) {
      return _ReportState.noMoney;
    }
    if (t.net.round() == 0) return _ReportState.breakEven;
    return t.net > 0 ? _ReportState.profit : _ReportState.loss;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              eyebrow: tr('finance.eyebrow'),
              title: tr('finance.title'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.sm,
                UgamSpacing.gutter,
                UgamSpacing.md,
              ),
              child: UgamTabPills(
                currentIndex: FinancePeriod.values.indexOf(_period),
                onChanged: (i) =>
                    setState(() => _period = FinancePeriod.values[i]),
                items: [
                  UgamTabItem(label: tr('finance.period_month')),
                  UgamTabItem(label: tr('finance.period_year')),
                  UgamTabItem(label: tr('finance.period_all')),
                ],
              ),
            ),
            Expanded(
              child: Obx(() {
                final firstLoading =
                    _finance.isLoading.value && !_finance.loadedOnce.value;
                if (firstLoading) {
                  // The SHARED money skeleton — the four sibling money screens
                  // already shimmer this exact shape, so the first load no
                  // longer reflows differently on Finance alone.
                  return const MoneyLoadingSkeleton();
                }
                if (_finance.loadFailed.value && !_finance.loadedOnce.value) {
                  return UgamEmpty.error(onRetry: _finance.reload);
                }

                final tours = _finance.financesFor(_period);
                final totals = FinanceTotals.from(tours);
                final state = _stateFor(totals);
                final hasFigures = state == _ReportState.profit ||
                    state == _ReportState.loss ||
                    state == _ReportState.breakEven;

                final ledgerEmpty = _finance.ledgerEmpty;
                // The coaching card and the broken-ledger notice answer the
                // same ₹0 with opposite explanations ("record your first
                // entry" vs "the records exist, the ledger lost them"), so
                // only one of them is ever allowed on screen. The notice wins:
                // it is the more specific diagnosis.
                final showZeroCard = !hasFigures &&
                    !(ledgerEmpty && state == _ReportState.noMoney);

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  //
                  // This used to pass nothing and call itself "theme-driven",
                  // but RefreshIndicator falls back to
                  // `Theme.colorScheme.primary`, which this app seeds with the
                  // accent — so the money screens were painting the same amber
                  // as the screens that named it, just implicitly. Explicit
                  // now: there is no theme hook for a refresh spinner.
                  color: c.ink2,
                  onRefresh: _finance.reload,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.xs,
                      UgamSpacing.gutter,
                      UgamSpacing.xxl,
                    ),
                    children: [
                      // A silent ₹0 is the one thing this report must never
                      // show: it reads as "you made nothing", not "I could not
                      // find out". See FinanceController.ledgerEmpty.
                      if (ledgerEmpty) ...[
                        const _LedgerEmptyNotice(),
                        const SizedBox(height: UgamSpacing.md),
                      ],
                      _HeroCard(totals: totals, state: state, c: c),
                      // Three tiles reading `0 / — / —` under a headline that
                      // already says "no figures yet" is the same nothing said
                      // twice. They come back the moment a trip exists.
                      if (totals.tourCount > 0) ...[
                        const SizedBox(height: UgamSpacing.md),
                        _StatTriple(totals: totals),
                      ],
                      const SizedBox(height: UgamSpacing.lg),
                      if (showZeroCard) ...[
                        _ZeroStateCard(
                          state: state,
                          onShowAllTime: () => setState(
                            () => _period = FinancePeriod.allTime,
                          ),
                          onCreateTour: _createTour,
                          onOpenMoney: tours.isEmpty
                              ? null
                              : () => _openTour(tours.first),
                        ),
                        if (tours.isNotEmpty)
                          const SizedBox(height: UgamSpacing.lg),
                      ],
                      if (tours.isNotEmpty) ...[
                        Text(
                          tr('finance.per_tour'),
                          style: UgamText.micro.copyWith(color: c.ink3),
                        ),
                        const SizedBox(height: UgamSpacing.sm),
                        for (final tf in tours)
                          Padding(
                            padding:
                                const EdgeInsets.only(bottom: UgamSpacing.md),
                            child: _TourFinanceRow(
                              tf: tf,
                              onTap: () => _openTour(tf),
                              c: c,
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Money formatting ─────────────────────────────────────────────────────────
// All rupee grouping is delegated to the shared [Formatters]; these thin
// wrappers only add the explicit +/− sign presentation the report needs.

/// The "there is no figure here" glyph. A dash is NOT ₹0 — it is the report
/// saying it has nothing to report, which is the whole distinction this screen
/// used to lose.
const String _noFigure = '—';

/// Unsigned amount, e.g. `₹1,72,000`.
String _inr(num v) => Formatters.formatMoneyInr(v.abs());

/// Signed amount with explicit +/-, e.g. `+₹38,200` / `-₹4,100` / `₹0`.
///
/// The sign uses the ASCII hyphen [Formatters.formatMoneyInr] emits, not a
/// typographic U+2212 — a negative figure has to be glyph-identical to the same
/// figure on the money board / P&L, which the agent compares side by side.
String _signedInr(num v) {
  final r = v.round();
  if (r == 0) return Formatters.formatMoneyInr(0);
  final body = Formatters.formatMoneyInr(r.abs());
  return r > 0 ? '+$body' : '-$body';
}

/// Compact amount for tight stat columns, e.g. `₹1.7L`, `₹38K`, signed.
String _compactSigned(num v) {
  if (v.round() == 0) return Formatters.formatMoneyInrCompact(0);
  final body = Formatters.formatMoneyInrCompact(v.abs());
  return v < 0 ? '-$body' : '+$body';
}

String _dateLabel(BuildContext context, DateTime d) =>
    Formatters.formatDateMedium(d, locale: context.locale.languageCode);

// ── Incomplete-ledger notice ─────────────────────────────────────────────────

/// Shown when the finance ledger answered with nothing while the agent
/// demonstrably has buses (see [FinanceController.ledgerEmpty]).
///
/// Deliberately a warm NOTICE and not [UgamEmpty.error]: this is not a failed
/// fetch, so there is nothing to retry — the report really did load, and what
/// it loaded is empty. Saying so is the whole point; a bare ₹0 reads as "you
/// earned nothing" rather than "I could not find out", and that is the reading
/// this closes.
class _LedgerEmptyNotice extends StatelessWidget {
  const _LedgerEmptyNotice();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Was a hand-rolled Container: warm fill, no border, and — because it
    // predates the elevation scale — no shadow, so the one thing on the screen
    // that most needed to be noticed sat FLATTER than the cards under it.
    // `UgamCardTone.warm` is the same fill plus the system's hairline and
    // `UgamElevation.rest`.
    return UgamCard.plain(
      tone: UgamCardTone.warm,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('finance.ledger_empty_title'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
                const SizedBox(height: UgamSpacing.xs),
                Text(
                  tr('finance.ledger_empty_body'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Hero net card ────────────────────────────────────────────────────────────

class _HeroCard extends StatelessWidget {
  final FinanceTotals totals;
  final _ReportState state;
  final UgamColorSet c;
  const _HeroCard({
    required this.totals,
    required this.state,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // "Has a real answer" — the only three states where a rupee figure is an
    // honest thing to print. Everything below branches on this.
    final hasFigures = state == _ReportState.profit ||
        state == _ReportState.loss ||
        state == _ReportState.breakEven;

    final label = switch (state) {
      _ReportState.profit => tr('finance.net_profit'),
      _ReportState.loss => tr('finance.net_loss'),
      _ReportState.breakEven => tr('finance.flat'),
      _ => tr('finance.net_pending'),
    };

    // A dash, not ₹0. Break-even keeps ink (a real zero); profit/loss keep
    // their semantic colour.
    final value = hasFigures ? _signedInr(totals.net) : _noFigure;
    final netColor = switch (state) {
      _ReportState.profit => c.good,
      _ReportState.loss => c.danger,
      _ReportState.breakEven => c.ink,
      _ => c.ink3,
    };

    // The badge used to paint a green "from 0 tours" over ₹0 — a confident
    // success signal attached to nothing. Neutral for every non-answer.
    final (Color chipBg, Color chipFg, IconData chipIcon) = switch (state) {
      _ReportState.profit => (c.goodFill, c.good, Icons.trending_up_rounded),
      _ReportState.loss => (c.dangerFill, c.danger, Icons.trending_down_rounded),
      _ReportState.breakEven => (c.cardElev, c.ink2, Icons.trending_flat_rounded),
      _ReportState.noMoney => (c.cardElev, c.ink2, Icons.hourglass_empty_rounded),
      _ => (c.cardElev, c.ink3, Icons.event_busy_rounded),
    };
    final chipText = totals.tourCount == 0
        ? tr('finance.chip_no_trips')
        : (totals.tourCount == 1
            ? tr('finance.from_tours_one',
                namedArgs: {'n': '${totals.tourCount}'})
            : tr('finance.from_tours_other',
                namedArgs: {'n': '${totals.tourCount}'}));

    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 3:2 split rather than `spaceBetween`: in Gujarati the label
          // ("હજી કોઈ આંકડો નથી") and the badge ("કોઈ પ્રવાસ નથી") are BOTH
          // long, and two intrinsically-sized children on one line is exactly
          // how that row used to overflow.
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  label,
                  style: UgamText.micro.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Flexible(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.sm,
                      vertical: UgamSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: chipBg,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(chipIcon, size: 13, color: chipFg),
                        const SizedBox(width: UgamSpacing.xs),
                        Flexible(
                          child: Text(
                            chipText,
                            style: UgamText.micro.copyWith(color: chipFg),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            value,
            style: UgamText.tabular(UgamText.numXl.copyWith(color: netColor)),
          ),
          // Everything below the headline is an ANSWER about money that moved.
          // With no figures there is no proportion to draw, no legend to read
          // and no accounting basis to disclaim — an empty grey bar over three
          // ₹0 columns is four separate pieces of furniture communicating
          // nothing. The zero-state card below carries the meaning instead.
          if (hasFigures) ...[
            const SizedBox(height: UgamSpacing.md),
            _MarginBar(
              revenue: totals.revenue + totals.income,
              expenses: totals.expenses,
              c: c,
            ),
            const SizedBox(height: UgamSpacing.md),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _HeroMetric(
                    label: tr('finance.revenue'),
                    value: _inr(totals.revenue),
                    color: c.ink,
                    dot: c.good,
                    c: c,
                  ),
                ),
                if (totals.income != 0)
                  Expanded(
                    child: _HeroMetric(
                      label: tr('bus_money.stat_income'),
                      value: _inr(totals.income),
                      color: c.ink,
                      dot: c.accent,
                      c: c,
                    ),
                  ),
                Expanded(
                  child: _HeroMetric(
                    label: tr('finance.expenses'),
                    value: _inr(totals.expenses),
                    color: c.ink2,
                    dot: c.warm,
                    c: c,
                  ),
                ),
              ],
            ),
            // This report is CASH basis (FinanceController sums `collected`),
            // while a trip's own P&L headlines the BILLED net. Both are right;
            // comparing them without knowing which is which is what makes the
            // app look like it cannot add up. Naming the basis costs one line.
            const SizedBox(height: UgamSpacing.sm),
            Text(
              tr('money.basis_cash'),
              style: UgamText.micro.copyWith(color: c.ink3),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color dot;
  final UgamColorSet c;
  const _HeroMetric({
    required this.label,
    required this.value,
    required this.color,
    required this.dot,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // 6pt dot + `sm` gap — the same geometry [UgamStatusDot] ships, so
            // the hero legend matches every other dot+label pair in the app.
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: UgamText.micro.copyWith(color: c.ink3),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          value,
          style: UgamText.tabular(UgamText.numLg.copyWith(color: color)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Slim proportion bar: warm = the slice of revenue eaten by expenses, good =
/// the profit slice. A loss paints the whole bar danger.
///
/// It draws a PROPORTION, so with nothing to divide it has nothing to say — the
/// old empty grey capsule under a ₹0 was pure furniture, and worse, it looked
/// like a progress bar stuck at 0%, implying the report was still loading. It
/// now renders nothing at all; the caller only mounts it when money moved.
class _MarginBar extends StatelessWidget {
  final double revenue;
  final double expenses;
  final UgamColorSet c;
  const _MarginBar({
    required this.revenue,
    required this.expenses,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    if (revenue <= 0 && expenses <= 0) return const SizedBox.shrink();

    final net = revenue - expenses;
    Widget bar;
    if (net < 0) {
      bar = Container(color: c.danger);
    } else {
      final expFrac = revenue <= 0 ? 1.0 : (expenses / revenue).clamp(0.0, 1.0);
      final expFlex = (expFrac * 1000).round();
      final profFlex = ((1 - expFrac) * 1000).round();
      bar = Row(
        children: [
          if (expFlex > 0)
            Expanded(flex: expFlex, child: Container(color: c.warm)),
          if (profFlex > 0)
            Expanded(flex: profFlex, child: Container(color: c.good)),
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: SizedBox(height: 10, child: bar),
    );
  }
}

// ── Stat triple ──────────────────────────────────────────────────────────────

/// Trips / average / best. Each tile is a [UgamStatTile], which is a
/// [UgamCard] — so all three sit at `UgamElevation.rest` while the hero above
/// them sits on the `cardElev` fill, and the two rows read as two surfaces
/// rather than one flat block. Values come from [UgamText.numLg], which carries
/// `FontFeature.tabularFigures` already.
class _StatTriple extends StatelessWidget {
  final FinanceTotals totals;
  const _StatTriple({required this.totals});

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label, String value})>[
      (
        icon: Icons.event_rounded,
        label: tr('finance.stat_tours'),
        value: '${totals.tourCount}',
      ),
      (
        icon: Icons.bar_chart_rounded,
        label: tr('finance.stat_avg'),
        value: totals.tourCount == 0
            ? _noFigure
            : _compactSigned(totals.avgNet),
      ),
      (
        icon: Icons.workspace_premium_rounded,
        label: tr('finance.stat_best'),
        value: totals.best == null
            ? _noFigure
            : _compactSigned(totals.best!.net),
      ),
    ];

    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          Expanded(
            child: UgamStatTile(
              icon: items[i].icon,
              value: items[i].value,
              label: items[i].label,
              variant: UgamStatVariant.neutral,
            ),
          ),
          if (i < items.length - 1) const SizedBox(width: UgamSpacing.sm),
        ],
      ],
    );
  }
}

// ── Zero state ───────────────────────────────────────────────────────────────

/// The screen's answer to "so what would put a number here?".
///
/// This replaces (a) the centred [UgamEmpty] that said "no trips with money
/// yet" and offered no way to change that, and (b) the half-viewport of void
/// underneath it. It is a card, so it takes `UgamElevation.rest` from
/// [UgamCard] like everything else on the page, and it always ends in ONE
/// button that goes to a destination that really exists:
///
/// * [_ReportState.periodEmpty] → widen the period, in place. No navigation:
///   the trips are already loaded, the filter was just narrower than the data.
/// * [_ReportState.noTrips]     → `CreateTourScreen`.
/// * [_ReportState.noMoney]     → the newest trip's `TourMoneyBoardScreen`,
///   the same destination a trip row opens.
class _ZeroStateCard extends StatelessWidget {
  final _ReportState state;
  final VoidCallback onShowAllTime;
  final VoidCallback onCreateTour;

  /// Null when the period holds no trip to open — the button is disabled
  /// rather than hidden, so the card never changes shape mid-refresh.
  final VoidCallback? onOpenMoney;

  const _ZeroStateCard({
    required this.state,
    required this.onShowAllTime,
    required this.onCreateTour,
    required this.onOpenMoney,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final noMoney = state == _ReportState.noMoney;
    final periodEmpty = state == _ReportState.periodEmpty;

    final (IconData icon, String title, String body) = switch (state) {
      _ReportState.periodEmpty => (
        Icons.event_busy_rounded,
        tr('finance.zero_period_title'),
        tr('finance.zero_period_body'),
      ),
      _ReportState.noMoney => (
        Icons.savings_rounded,
        tr('finance.zero_money_title'),
        tr('finance.zero_money_body'),
      ),
      _ => (
        Icons.route_rounded,
        tr('finance.zero_start_title'),
        tr('finance.zero_start_body'),
      ),
    };

    final (String ctaLabel, IconData ctaIcon, VoidCallback? onCta) =
        switch (state) {
      _ReportState.periodEmpty => (
        tr('finance.zero_period_cta'),
        Icons.all_inclusive_rounded,
        onShowAllTime,
      ),
      _ReportState.noMoney => (
        tr('finance.zero_money_cta'),
        Icons.account_balance_wallet_rounded,
        onOpenMoney,
      ),
      _ => (
        tr('finance.zero_start_cta'),
        Icons.add_rounded,
        onCreateTour,
      ),
    };

    // The three things that actually create a rupee in this report, in the
    // order they happen. Skipped when the only problem is the period filter,
    // and the "create a trip" step is dropped once trips exist.
    final steps = <Widget>[
      if (!periodEmpty && !noMoney)
        _ZeroStep(
          icon: Icons.add_road_rounded,
          title: tr('finance.zero_step_trip_title'),
          body: tr('finance.zero_step_trip_body'),
        ),
      if (!periodEmpty) ...[
        _ZeroStep(
          icon: Icons.payments_rounded,
          title: tr('finance.zero_step_cash_title'),
          body: tr('finance.zero_step_cash_body'),
        ),
        _ZeroStep(
          icon: Icons.receipt_long_rounded,
          title: tr('finance.zero_step_expense_title'),
          body: tr('finance.zero_step_expense_body'),
        ),
      ],
    ];

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Decorative medallion — [UgamScale.px], never `tap`: nothing
              // here takes a finger, the button at the bottom does.
              Container(
                width: UgamScale.px(context, 40),
                height: UgamScale.px(context, 40),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: UgamScale.px(context, 20),
                  color: c.ink2,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // No maxLines anywhere in this card: Gujarati runs ~30%
                    // longer and these sentences carry the whole explanation,
                    // so they wrap rather than ellipsise.
                    Text(
                      title,
                      style: UgamText.titleM.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: UgamSpacing.xs),
                    Text(
                      body,
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.lg),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.md),
            for (var i = 0; i < steps.length; i++) ...[
              steps[i],
              if (i < steps.length - 1) const SizedBox(height: UgamSpacing.md),
            ],
          ],
          const SizedBox(height: UgamSpacing.lg),
          // The screen's single primary control. `UgamButton` floors itself at
          // the 44pt tap target via UgamScale.tap, and `primary` is the neutral
          // max-contrast fill — it spends no accent, so the rationing law is
          // untouched.
          UgamButton(
            label: ctaLabel,
            icon: ctaIcon,
            kind: UgamButtonKind.primary,
            expand: true,
            onPressed: onCta,
          ),
        ],
      ),
    );
  }
}

/// One "this is what creates a number" line inside [_ZeroStateCard].
class _ZeroStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _ZeroStep({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: UgamScale.px(context, 30),
          height: UgamScale.px(context, 30),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: UgamScale.px(context, 15), color: c.ink2),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: UgamText.titleS.copyWith(color: c.ink)),
              const SizedBox(height: 2),
              Text(body, style: UgamText.caption.copyWith(color: c.ink3)),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Per-tour row ─────────────────────────────────────────────────────────────

class _TourFinanceRow extends StatelessWidget {
  final TourFinance tf;
  final VoidCallback onTap;
  final UgamColorSet c;
  const _TourFinanceRow({
    required this.tf,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final profit = tf.isProfit;
    // Same distinction as the headline, one row down: a trip with no entries at
    // all is not a break-even trip. They used to share one dash-in-a-grey-box
    // thumbnail, which is exactly what read as an unloaded placeholder.
    final untouched = tf.revenue == 0 && tf.income == 0 && tf.expenses == 0;
    final zero = !untouched && tf.net.round() == 0;

    final (IconData rowIcon, Color iconBg, Color iconFg) = untouched
        ? (Icons.hourglass_empty_rounded, c.cardElev, c.ink3)
        : zero
            ? (Icons.trending_flat_rounded, c.cardElev, c.ink2)
            : profit
                ? (Icons.trending_up_rounded, c.goodFill, c.good)
                : (Icons.trending_down_rounded, c.dangerFill, c.danger);
    final netColor = untouched
        ? c.ink3
        : zero
            ? c.ink2
            : (profit ? c.good : c.danger);

    final busLabel = tf.buses == 1
        ? tr('finance.bus_one', namedArgs: {'n': '${tf.buses}'})
        : tr('finance.bus_other', namedArgs: {'n': '${tf.buses}'});
    // A running trip's net is provisional (more cash still to come in, more
    // costs still to be logged), so the row says so rather than letting it read
    // as a settled result sitting next to genuinely finished trips.
    final stateLabel = tf.isCompleted
        ? tr('finance.row_state_completed')
        : tr('finance.row_state_running');
    final meta = '${_dateLabel(context, tf.date)} · $busLabel · $stateLabel';

    // Margin is net over GROSS income (passenger fares + extra income), so
    // cabin/gallery cash isn't ignored in the percentage.
    final grossIn = tf.revenue + tf.income;
    final marginPct = grossIn > 0
        ? tr('finance.margin_pct',
            namedArgs: {'n': '${(tf.net / grossIn * 100).round()}'})
        : null;

    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        children: [
          // Decorative leading tile — [UgamScale.px], so the glyph box
          // tracks the label text instead of staying full-size while the
          // row's type shrinks on a narrow phone.
          Container(
            width: UgamScale.px(context, 38),
            height: UgamScale.px(context, 38),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              rowIcon,
              size: UgamScale.px(context, 18),
              color: iconFg,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title line carries the margin% as a small badge chip so
                // the headline answer (how good was this trip) rides
                // alongside the name — no separate metric strip needed.
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        tf.title.isEmpty ? tf.route : tf.title,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (marginPct != null) ...[
                      const SizedBox(width: UgamSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.sm,
                          vertical: UgamSpacing.badgeV,
                        ),
                        decoration: BoxDecoration(
                          color: c.cardElev,
                          borderRadius: BorderRadius.circular(UgamRadius.chip),
                        ),
                        child: Text(
                          marginPct,
                          style: UgamText.tabular(
                            UgamText.micro.copyWith(color: c.ink2),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  style: UgamText.caption.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // Net big, revenue small beneath — the trip's bottom line and the
          // gross it came from, stacked on the right. Both are tabular, so the
          // rupee digits line up down the column of rows.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                untouched ? _noFigure : _signedInr(tf.net),
                style: UgamText.tabular(
                  UgamText.numLg.copyWith(color: netColor),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                untouched
                    ? tr('finance.row_no_money')
                    : tr('finance.row_revenue_value',
                        namedArgs: {'n': _inr(tf.revenue)}),
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// The first-load skeleton and the load-failure state are the SHARED
// `MoneyLoadingSkeleton` / `UgamEmpty.error` used by the four sibling money
// screens. The private `_Loading` / `_ErrorState` copies that used to live here
// had already drifted from them (three stat boxes vs two, a tonal retry vs the
// shared solid one) and were deleted.
//
// The private `_Empty` that used to sit here is gone too: a centred icon over
// "No trips with money yet" is a statement, and what this screen owed the agent
// was an explanation plus a way out. That is `_ZeroStateCard`. The
// `finance.empty_title` / `finance.empty_body` strings are left in the
// translation files rather than deleted.
