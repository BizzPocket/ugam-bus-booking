part of '../tour_money_board_screen.dart';

// ─── Sticky tour-totals capsule ─────────────────────────────────────────────

class _TotalsCapsule extends StatelessWidget {
  final TourMoneySummary summary;
  final UgamColorSet c;

  const _TotalsCapsule({required this.summary, required this.c});

  @override
  Widget build(BuildContext context) {
    final outstanding = summary.totalOutstandingHandover;
    final settled = outstanding.abs() <= 0.005;

    // TWO ROWS, not a four-up strip.
    //
    // This was one Row: the hero column, then the two pills, each at flex 1.
    // At a 375pt width that leaves the hero 98pt — and the hero's own
    // label + status Row halved THAT again, so at 45pt a side the two labels
    // it carries rendered as "OUT…" and "Handov…" in English, and as "બા…"
    // and "સોંપ…" in Gujarati. Re-measured against the longest gu.json
    // strings instead of the English ones: the label line now owns the full
    // 315pt of card interior (longest label + status ≈ 235pt, so it never
    // ellipsizes and may wrap to a second line if a locale runs longer
    // still), and each pill below owns 153pt — 129pt of text for a
    // "એકઠી કરેલ" that needs ~55pt and a "₹1,81,000" that needs ~78pt.
    //
    // The extra ~55pt of height is deliberate: this capsule reports the
    // tour's three headline figures and it is now the thing the board's
    // short-board whitespace was wasted on (see the Flexible body slot).
    return UgamStickyCTA(
      child: UgamCard.plain(
        elev: true,
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Hero: outstanding handover ─────────────────────────
            Row(
              children: [
                Flexible(
                  child: Text(
                    tr('tour_money_board.outstanding_handover').toUpperCase(),
                    style: UgamText.micro.copyWith(color: c.ink3),
                    // Wraps rather than ellipsizes: a three-character stub of
                    // a label is worse than a second 12pt line.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                // Scoped to the HANDOVER, which is what this capsule
                // reports. A bare "all settled" sat directly above bus
                // rows still owing their full fares and read as "nothing
                // left to collect" — the handover can be square while the
                // trip has taken no money at all.
                // Flexible so the longer, scoped label ellipsizes inside
                // the capsule instead of overflowing the row —
                // UgamStatusDot only self-ellipsizes under bounded width.
                Flexible(
                  child: UgamStatusDot(
                    label: settled
                        ? tr('tour_money_board.handover_settled')
                        : tr('tour_money_board.open'),
                    tone: settled ? UgamStatusTone.good : UgamStatusTone.warm,
                  ),
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
                  UgamText.numXl.copyWith(color: settled ? c.good : c.warm),
                ),
                maxLines: 1,
              ),
            ),
            const SizedBox(height: UgamSpacing.md),
            // ── Two compact pills: collected + net ─────────────────
            // Equal halves, equal heights: if one locale wraps its label to two
            // lines the other pill grows with it instead of the pair sitting at
            // two different heights. `stretch` alone can't do that inside a
            // Column (the Row's height is unbounded there, and stretching
            // against infinity asserts), so the height is pinned to the taller
            // pill first — two children, so the intrinsic pass is cheap.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _CapsulePill(
                      label: tr('tour_money_board.collected'),
                      value: Formatters.formatMoneyInr(summary.totalCollected),
                      c: c,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Expanded(
                    child: _CapsulePill(
                      // "NET (CASH)", not "NET": the P&L card higher up this
                      // same screen headlines the BILLED net. The pill is too
                      // small for a caption, so the basis rides in the label.
                      label: tr('tour_money_board.net_cash'),
                      value: Formatters.formatMoneyInr(summary.totalNet),
                      c: c,
                    ),
                  ),
                ],
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
          Text(
            label,
            style: UgamText.micro.copyWith(color: c.ink3),
            // Two lines of a long Gujarati label beats an ellipsis; both pills
            // grow together (the Row above stretches).
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UgamSpacing.xs),
          // Scaled down to fit rather than ellipsized — see _MoneyPill.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              // `titleS` (15) off the ladder, not `numLg` shrunk with a raw
              // fontSize — see _MoneyPill.
              style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
