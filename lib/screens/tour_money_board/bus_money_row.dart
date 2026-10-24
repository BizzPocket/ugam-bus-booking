part of '../tour_money_board_screen.dart';

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
    // collected reads as a quiet "no activity". A status WORD is added only
    // where it says something the figure doesn't (settled / not-started).
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
        // Money still TO COLLECT is a normal operating state — every bus looks
        // like this the morning it departs — so the card stays neutral and the
        // figure carries the weight typographically (full `ink`, w700, see
        // below). It used to wear `UgamCardTone.danger`: a red hairline, a red
        // tint and red numerals. `danger` means "something needs you" (see the
        // token doc), and spending it on the everyday state is what teaches a
        // handler to scroll past red — which then costs us the one place red
        // has to work. A handover still DUE keeps the rose `warm` tint: that
        // is an open obligation on the operator, attention without alarm.
        hasHandoverDue ? UgamCardTone.warm : UgamCardTone.none,
        // "Still to hand over", not "Handover": the stat box below already
        // says "Handover" for what HAS been handed over, and the two numbers
        // under one label read as a contradiction.
        hasHandoverDue
            ? tr('tour_money_board.outstanding_handover')
            : tr('tour_money_board.to_collect'),
        hasHandoverDue ? summary.outstandingHandover : summary.toCollectTotal,
        hasHandoverDue ? c.warm : c.ink,
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
      // Neutral and settled never paint the figure (see `leadsWithFigure`) —
      // their label/amount/ink entries keep the record shape uniform.
      BusMoneyState.neutral => (
        UgamCardTone.none,
        tr('tour_money_board.to_collect'),
        summary.toCollectTotal,
        c.ink3,
        tr('tour_money_board.no_activity'),
        UgamStatusTone.neutral,
      ),
    };

    // With the red tint gone, the to-collect figure IS the signal, so it is the
    // only thing on the row set in full ink at w700 — heavier than the bus name
    // beside it. Everything else on a calm card sits at ink2/ink3.
    final leadsWithFigure = state == BusMoneyState.actionNeeded;
    final emphasiseFigure = leadsWithFigure && !hasHandoverDue;

    // Collected / handover only carry information once cash has changed hands —
    // until then they are ₹0 filler, so the strip is hidden and the card
    // collapses to identity + action figure + collect.
    final hasMoved =
        summary.collected > 0.005 ||
        summary.handedOver > 0.005 ||
        summary.income > 0.005;

    return UgamSwipeAction(
      key: ValueKey('bus-money-swipe-${bus.id}'),
      // Right-swipe only: collecting is the accelerator, and a bus row must
      // never be dismissible — there is no "delete a bus" here.
      rightIcon: Icons.groups_rounded,
      rightLabel: tr('tour_money_board.collect'),
      onRight: onCollect,
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: UgamCard.plain(
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
              // tabular — so the row answers "how much?" in one glance without
              // a second full-width headline block. Shown ONLY when there is
              // an action: a settled bus already says so with the mint dot +
              // the collected/handover pills, and a bus with no activity was
              // spending this whole column on a "TO COLLECT ₹0" that carried
              // nothing — and, at 375pt, squeezed the Gujarati "કોઈ પ્રવૃત્તિ
              // નથી" status dot hard enough to crush the bus type beside it
              // down to two characters. Dropping the ₹0 hands that width back.
              if (leadsWithFigure) ...[
                ConstrainedBox(
                  // This column is the only child of the row with a variable
                  // width and no flex factor, so it used to size itself first
                  // and let the identity absorb whatever was left: at a 1.3×
                  // accessibility scale a seven-figure amount plus a Gujarati
                  // label pushed the row 27pt past its own card and squeezed
                  // the bus name to zero width. Capped at a third of the row,
                  // the amount scales down INSIDE the cap instead of being
                  // clipped — money is never ellipsized, the same rule the
                  // totals capsule follows — and the identity keeps a
                  // readable share.
                  constraints: BoxConstraints(
                    maxWidth: UgamScale.px(context, 128),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        numLabel.toUpperCase(),
                        style: UgamText.micro.copyWith(
                          color: emphasiseFigure ? c.ink2 : c.ink3,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 1),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          Formatters.formatMoneyInr(numAmount),
                          style: UgamText.tabular(
                            UgamText.numLg.copyWith(
                              color: numColor,
                              // Weight, not colour, is what makes the neutral
                              // card still lead with its number.
                              fontWeight:
                                  emphasiseFigure ? FontWeight.w700 : null,
                            ),
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UgamSpacing.xs),
              ],
              // The collect shortcut rides ON the row as a 44×44 round action
              // instead of a full-width button stacked beneath it. That kept
              // the shortcut one tap away while halving the row's height and
              // leaving the row itself as the only large tap target (it opens
              // the bus detail). Swipe-right does the same thing.
              // Default 44×44 — the Apple HIG / Material touch floor. Do not
              // shrink it to buy width: a mis-tap here opens the wrong screen
              // mid-collection.
              UgamIconButton(
                key: ValueKey('bus-collect-${bus.id}'),
                icon: Icons.groups_rounded,
                tone: UgamIconButtonTone.accent,
                semanticLabel: tr('tour_money_board.collect'),
                onTap: onCollect,
              ),
              // 8dp minimum between adjacent touch targets (the button vs the
              // row's own tap).
              const SizedBox(width: UgamSpacing.sm),
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
          ],
        ),
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
          Text(
            label,
            style: UgamText.micro.copyWith(color: c.ink3),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UgamSpacing.xs),
          // A money figure scales down to fit; it is never ellipsized. "₹1,8…"
          // is not a smaller number, it is a wrong one.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              // `titleS` (15) off the ladder, not `numLg` shrunk with a raw
              // fontSize — same Sora face at the same size, one less hardcoded
              // number, and `tabular()` keeps the figures aligned.
              style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink2)),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
