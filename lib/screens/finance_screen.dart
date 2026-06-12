import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/finance_controller.dart';
import '../design/ugam.dart';
import '../models/tour_finance.dart';
import '../routes/app_routes.dart';
import '../utils/formatters.dart';

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

  // Default the report to "this month" — the agent's most common question is
  // "how am I doing right now", not the lifetime total. Pure initial-state
  // change (no new persistence); the user can still switch to year / all time.
  FinancePeriod _period = FinancePeriod.thisMonth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _finance.ensureLoaded();
    });
  }

  void _openTour(TourFinance tf) {
    Get.toNamed(AppRoutes.tourMoney, arguments: {'tourId': tf.tourId});
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
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
                  return const _Loading();
                }
                if (_finance.loadFailed.value && !_finance.loadedOnce.value) {
                  return _ErrorState(onRetry: _finance.reload);
                }

                final tours = _finance.financesFor(_period);
                final totals = FinanceTotals.from(tours);

                return RefreshIndicator(
                  color: c.accent,
                  backgroundColor: c.cardElev,
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

/// Signed amount with explicit +/−, e.g. `+₹38,200` / `−₹4,100` / `₹0`.
String _signedInr(num v) {
  final r = v.round();
  if (r == 0) return '₹0';
  final body = Formatters.formatMoneyInr(r.abs());
  return r > 0 ? '+$body' : '−$body';
}

/// Compact amount for tight stat columns, e.g. `₹1.7L`, `₹38K`, signed.
String _compactSigned(num v) {
  if (v.round() == 0) return '₹0';
  final body = Formatters.formatMoneyInrCompact(v.abs());
  return v < 0 ? '−$body' : '+$body';
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
                  color: profit ? c.goodFill : c.danger.withValues(alpha: 0.16),
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
          _MarginBar(revenue: totals.revenue, expenses: totals.expenses, c: c),
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
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: UgamSpacing.xs + 2),
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
        : (profit ? c.goodFill : c.danger.withValues(alpha: 0.16),
            profit ? c.good : c.danger);

    final busLabel = tf.buses == 1
        ? tr('finance.bus_one', namedArgs: {'n': '${tf.buses}'})
        : tr('finance.bus_other', namedArgs: {'n': '${tf.buses}'});
    final meta = '${_dateLabel(context, tf.date)} · $busLabel';

    final marginPct = tf.revenue > 0
        ? tr('finance.margin_pct',
            namedArgs: {'n': '${(tf.net / tf.revenue * 100).round()}'})
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
              Container(
                width: 38,
                height: 38,
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
                  size: 18,
                  color: iconFg,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tf.title.isEmpty ? tf.route : tf.title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _signedInr(tf.net),
                    style:
                        UgamText.tabular(UgamText.numLg.copyWith(color: netColor)),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    zero
                        ? tr('finance.flat')
                        : (profit ? tr('finance.profit') : tr('finance.loss')),
                    style: UgamText.micro.copyWith(color: netColor),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Divider(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.sm + 2),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: tr('finance.row_revenue'),
                  value: _inr(tf.revenue),
                  color: c.ink,
                  c: c,
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: tr('finance.row_expenses'),
                  value: _inr(tf.expenses),
                  color: c.ink2,
                  c: c,
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: tr('finance.row_margin'),
                  value: marginPct,
                  color: c.ink2,
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

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final UgamColorSet c;
  const _MiniMetric({
    required this.label,
    required this.value,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
        const SizedBox(height: 2),
        Text(
          value,
          style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: color)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ── Empty / loading / error states ───────────────────────────────────────────

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
      child: UgamEmpty(
        icon: Icons.insights_rounded,
        title: tr('finance.empty_title'),
        body: tr('finance.empty_body'),
      ),
    );
  }
}

/// Initial-load skeleton: a hero placeholder, a stat strip, and a couple of
/// per-tour row placeholders — mirrors the real layout instead of a spinner.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.xs,
        UgamSpacing.gutter,
        UgamSpacing.xxl,
      ),
      children: [
        const UgamSkeleton(height: 184, radius: UgamRadius.card),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: const [
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
            SizedBox(width: UgamSpacing.sm),
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
            SizedBox(width: UgamSpacing.sm),
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
          ],
        ),
        const SizedBox(height: UgamSpacing.xl),
        const UgamSkeleton(height: 120, radius: UgamRadius.card),
        const SizedBox(height: UgamSpacing.md),
        const UgamSkeleton(height: 120, radius: UgamRadius.card),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Error/empty states must NOT use solid champagne — the retry is TONAL.
    return UgamEmpty(
      icon: Icons.cloud_off_rounded,
      title: tr('finance.error_title'),
      cta: UgamButton(
        label: tr('finance.error_retry'),
        icon: Icons.refresh_rounded,
        kind: UgamButtonKind.tonal,
        onPressed: () => onRetry(),
      ),
    );
  }
}
