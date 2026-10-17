part of '../finance_screen.dart';

// ── Per-tour row ─────────────────────────────────────────────────────────────

class _TourFinanceRow extends StatelessWidget {
  final TourFinance tf;
  final VoidCallback onTap;

  /// Long-press → delete this trip (confirmed by a dialog first).
  final VoidCallback? onLongPress;
  final UgamColorSet c;
  const _TourFinanceRow({
    required this.tf,
    required this.onTap,
    this.onLongPress,
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

    final (
      IconData rowIcon,
      Color iconBg,
      Color iconFg,
      Color netColor,
    ) = untouched
        ? (Icons.hourglass_empty_rounded, c.cardElev, c.ink3, c.ink3)
        : zero
        ? (Icons.trending_flat_rounded, c.cardElev, c.ink2, c.ink2)
        : profit
        ? (Icons.trending_up_rounded, c.goodFill, c.good, c.good)
        : (Icons.trending_down_rounded, c.dangerFill, c.danger, c.danger);

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
        ? tr(
            'finance.margin_pct',
            namedArgs: {'n': '${(tf.net / grossIn * 100).round()}'},
          )
        : null;

    final card = UgamCard.plain(
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
                    : tr(
                        'finance.row_revenue_value',
                        namedArgs: {'n': _inr(tf.revenue)},
                      ),
                style: UgamText.tabular(UgamText.micro.copyWith(color: c.ink3)),
              ),
            ],
          ),
        ],
      ),
    );
    if (onLongPress == null) return card;
    // Long-press only — the card's own tap recogniser keeps quick taps, and a
    // destructive action never sits one mis-tap away on a list row.
    return GestureDetector(
      key: ValueKey('finance-row-${tf.tourId}'),
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: card,
    );
  }
}
