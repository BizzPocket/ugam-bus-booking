import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/finance_controller.dart';
import '../design/ugam.dart';
import '../models/tour_finance.dart';
import '../utils/formatters.dart';
import '../widgets/money_loading_skeleton.dart';
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

                return RefreshIndicator(
                  // Theme-driven, exactly like the four sibling money screens —
                  // a per-screen copper spinner made one pull-to-refresh look
                  // different from every other.
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
                      _HeroCard(totals: totals, c: c),
                      const SizedBox(height: UgamSpacing.md),
                      _StatTriple(totals: totals),
                      const SizedBox(height: UgamSpacing.xl),
                      if (tours.isEmpty)
                        const _Empty()
                      else ...[
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

// ── Hero net card ────────────────────────────────────────────────────────────

class _HeroCard extends StatelessWidget {
  final FinanceTotals totals;
  final UgamColorSet c;
  const _HeroCard({required this.totals, required this.c});

  @override
  Widget build(BuildContext context) {
    final profit = totals.isProfit;
    final netColor = totals.net.round() == 0
        ? c.ink
        : (profit ? c.good : c.danger);

    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                profit ? tr('finance.net_profit') : tr('finance.net_loss'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm,
                  vertical: UgamSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: profit ? c.goodFill : c.dangerFill,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      profit
                          ? Icons.trending_up_rounded
                          : Icons.trending_down_rounded,
                      size: 13,
                      color: profit ? c.good : c.danger,
                    ),
                    const SizedBox(width: UgamSpacing.xs),
                    Text(
                      totals.tourCount == 1
                          ? tr('finance.from_tours_one',
                              namedArgs: {'n': '${totals.tourCount}'})
                          : tr('finance.from_tours_other',
                              namedArgs: {'n': '${totals.tourCount}'}),
                      style: UgamText.micro.copyWith(
                        color: profit ? c.good : c.danger,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            _signedInr(totals.net),
            style: UgamText.tabular(UgamText.numXl.copyWith(color: netColor)),
          ),
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
            Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
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
/// the profit slice. A loss paints the whole bar danger. Hidden when there is
/// no money at all.
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
    if (revenue <= 0 && expenses <= 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        child: Container(height: 10, color: c.border),
      );
    }

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
        value: totals.tourCount == 0 ? '—' : _compactSigned(totals.avgNet),
      ),
      (
        icon: Icons.workspace_premium_rounded,
        label: tr('finance.stat_best'),
        value: totals.best == null ? '—' : _compactSigned(totals.best!.net),
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
    final zero = tf.net.round() == 0;
    final netColor = zero ? c.ink2 : (profit ? c.good : c.danger);
    final (iconBg, iconFg) = zero
        ? (c.cardElev, c.ink2)
        : (profit ? c.goodFill : c.dangerFill,
            profit ? c.good : c.danger);

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
        : '—';

    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
                  zero
                      ? Icons.remove_rounded
                      : (profit
                          ? Icons.trending_up_rounded
                          : Icons.trending_down_rounded),
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
                        if (marginPct != '—') ...[
                          const SizedBox(width: UgamSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: UgamSpacing.sm,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.cardElev,
                              borderRadius:
                                  BorderRadius.circular(UgamRadius.chip),
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
              // gross it came from, stacked on the right. The old divider + 3-col
              // revenue/expenses/margin strip is gone.
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _signedInr(tf.net),
                    style:
                        UgamText.tabular(UgamText.numLg.copyWith(color: netColor)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('finance.row_revenue_value',
                        namedArgs: {'n': _inr(tf.revenue)}),
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(color: c.ink3),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Empty / loading / error states ───────────────────────────────────────────

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      child: UgamEmpty(
        icon: Icons.insights_rounded,
        title: tr('finance.empty_title'),
        body: tr('finance.empty_body'),
      ),
    );
  }
}

// The first-load skeleton and the load-failure state are the SHARED
// `MoneyLoadingSkeleton` / `UgamEmpty.error` used by the four sibling money
// screens. The private `_Loading` / `_ErrorState` copies that used to live here
// had already drifted from them (three stat boxes vs two, a tonal retry vs the
// shared solid one) and were deleted.
