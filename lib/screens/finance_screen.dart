import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/finance_controller.dart';
import '../design/ugam.dart';
import '../models/tour_finance.dart';
import '../routes/app_routes.dart';

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
  FinancePeriod _period = FinancePeriod.allTime;

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
            _Header(c: c),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                0,
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
                  return _Loading(c: c);
                }
                if (_finance.loadFailed.value && !_finance.loadedOnce.value) {
                  return _ErrorState(c: c, onRetry: _finance.reload);
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
                      _StatTriple(totals: totals, c: c),
                      const SizedBox(height: UgamSpacing.xl),
                      if (tours.isEmpty)
                        _Empty(c: c)
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

// ── Money formatting (Indian grouping) ──────────────────────────────────────

String _grp(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final parts = <String>[];
  while (rest.length > 2) {
    parts.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return '${parts.join(',')},$last3';
}

/// Unsigned amount, e.g. `₹1,72,000`.
String _inr(num v) => '₹${_grp(v.abs().round())}';

/// Signed amount with explicit +/−, e.g. `+₹38,200` / `−₹4,100` / `₹0`.
String _signedInr(num v) {
  final r = v.round();
  if (r == 0) return '₹0';
  return r > 0 ? '+₹${_grp(r)}' : '−₹${_grp(r.abs())}';
}

/// Compact amount for tight stat columns, e.g. `₹1.7L`, `₹38K`, signed.
String _compactSigned(num v) {
  final neg = v < 0;
  final a = v.abs();
  String body;
  if (a >= 100000) {
    final l = a / 100000;
    body = '₹${l.toStringAsFixed(l >= 10 ? 0 : 1)}L';
  } else if (a >= 1000) {
    final k = a / 1000;
    body = '₹${k.toStringAsFixed(k >= 10 ? 0 : 1)}K';
  } else {
    body = '₹${a.round()}';
  }
  if (a.round() == 0) return '₹0';
  return neg ? '−$body' : '+$body';
}

String _dateLabel(DateTime d) => DateFormat('d MMM yyyy').format(d);

// ── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final UgamColorSet c;
  const _Header({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('finance.eyebrow'),
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('finance.title'),
                  style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                    const SizedBox(width: 4),
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
            style: UgamText.tabular(
              UgamText.numXl.copyWith(color: netColor, fontSize: 34),
            ),
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
            const SizedBox(width: 6),
            Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: UgamText.tabular(
            UgamText.numLg.copyWith(color: color, fontSize: 18),
          ),
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
  final UgamColorSet c;
  const _StatTriple({required this.totals, required this.c});

  @override
  Widget build(BuildContext context) {
    final items = <({String label, String value})>[
      (label: tr('finance.stat_tours'), value: '${totals.tourCount}'),
      (
        label: tr('finance.stat_avg'),
        value: totals.tourCount == 0 ? '—' : _compactSigned(totals.avgNet),
      ),
      (
        label: tr('finance.stat_best'),
        value: totals.best == null ? '—' : _compactSigned(totals.best!.net),
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.stat),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    items[i].value,
                    style: UgamText.tabular(
                      UgamText.titleM.copyWith(color: c.ink, fontSize: 16),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    items[i].label,
                    style: UgamText.caption.copyWith(color: c.ink2),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (i < items.length - 1)
              Container(width: 1, height: 28, color: c.border),
          ],
        ],
      ),
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
    final meta = '${_dateLabel(tf.date)} · $busLabel';

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
                  borderRadius: BorderRadius.circular(12),
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
                    style: UgamText.tabular(
                      UgamText.numLg.copyWith(color: netColor, fontSize: 17),
                    ),
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
  final UgamColorSet c;
  const _Empty({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.insights_rounded, size: 26, color: c.ink3),
            ),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('finance.empty_title'),
              style: UgamText.titleS.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
              child: Text(
                tr('finance.empty_body'),
                style: UgamText.caption.copyWith(color: c.ink3),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  final UgamColorSet c;
  const _Loading({required this.c});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: c.accent),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final UgamColorSet c;
  final Future<void> Function() onRetry;
  const _ErrorState({required this.c, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 34, color: c.ink3),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('finance.error_title'),
              style: UgamText.titleS.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: UgamSpacing.lg),
            UgamCTA(
              label: tr('finance.error_retry'),
              leadingIcon: Icons.refresh_rounded,
              onPressed: () => onRetry(),
            ),
          ],
        ),
      ),
    );
  }
}
