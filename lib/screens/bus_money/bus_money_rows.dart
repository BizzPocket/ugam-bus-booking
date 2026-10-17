part of '../bus_money_screen.dart';

class _ExpenseRow extends StatelessWidget {
  final Expense expense;
  final VoidCallback onTap;

  const _ExpenseRow({required this.expense, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Tapping the row opens the edit sheet; delete is a swipe-left gesture
    // owned by the enclosing UgamSwipeAction. `onTap` goes THROUGH the card
    // (an outer GestureDetector swallowed the card's own press animation).
    return UgamCard.plain(
      onTap: onTap,
      radius: UgamRadius.row,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: ConstrainedBox(
        // 44pt tap floor expressed as content height: the card already adds
        // `md` above and below, so 44 - 12 - 12 = 20. A no-op at the 390pt
        // baseline (the chip row is already ~21) — it only bites once the
        // text scales down and would otherwise drop the row under 44.
        constraints: const BoxConstraints(minHeight: 44 - UgamSpacing.md * 2),
        child: Row(
          children: [
            UgamReqChip(
              label: expense.category.displayName,
              variant: UgamChipVariant.neutral,
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                expense.label.isEmpty ? '—' : expense.label,
                style: UgamText.bodyStrong.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(expense.amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single handler-entered income entry, shown read-only on the admin's
/// money screen. Mirrors [_ExpenseRow] styling but has no edit/delete — the
/// handler logs this extra cash (Cabin/Gallery/Other) on the ground.
class _IncomeRow extends StatelessWidget {
  final IncomeEntry income;

  /// Opens the edit sheet. Null keeps the row read-only (the handler-facing
  /// surfaces still render it that way).
  final VoidCallback? onTap;

  const _IncomeRow({required this.income, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final receivedBy = income.receivedBy?.trim() ?? '';
    final label = income.label.isEmpty
        ? income.category.displayName
        : income.label;
    return UgamCard.plain(
      // Tap goes THROUGH the card (not a nested InkWell) so the press
      // animation fires — same rule as _ExpenseRow / _HandoverRow.
      onTap: onTap,
      radius: UgamRadius.row,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: Row(
        children: [
          UgamReqChip(
            label: income.category.displayName,
            variant: UgamChipVariant.neutral,
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (receivedBy.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    receivedBy,
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            Formatters.formatMoneyInr(income.amount),
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.good),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoverRow extends StatelessWidget {
  final BusHandover handover;
  final VoidCallback onTap;

  const _HandoverRow({required this.handover, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Locale-aware date (month name follows app locale) + a stable AM/PM time.
    final date =
        '${Formatters.formatDateShort(handover.settledAt, locale: context.locale.languageCode)}, '
        '${DateFormat('h:mm a', 'en_US').format(handover.settledAt)}';
    // WHO recorded this settlement. `source` was already selected and parsed
    // but only ever read for the handler's edit permission (BusHandover
    // .byHandler), so the admin reconciling cash could not tell a row the
    // handler filed on the bus from one they typed in the office themselves.
    // Read through `byHandler` so an unrecognised value falls back to 'admin'
    // exactly as the model and the handler UI already treat it.
    final source = handover.byHandler
        ? tr('bus_money.handover_by_handler')
        : tr('bus_money.handover_by_admin');
    // `onTap` goes THROUGH the card so the press animation fires (the outer
    // GestureDetector that used to wrap it swallowed the feedback).
    return UgamCard.plain(
      onTap: onTap,
      radius: UgamRadius.row,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: ConstrainedBox(
        // Same 44pt tap floor as _ExpenseRow: 44 minus the card's `md`
        // padding top and bottom. No-op at the 390pt baseline.
        constraints: const BoxConstraints(minHeight: 44 - UgamSpacing.md * 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(
                      'bus_money.handed_of',
                      namedArgs: {
                        'handed': Formatters.formatMoneyInr(
                          handover.handedOverAmount,
                        ),
                        'expected': Formatters.formatMoneyInr(
                          handover.expectedAmount,
                        ),
                      },
                    ),
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  // Metadata, not a headline: the provenance rides ALONGSIDE
                  // the date on the same caption line rather than taking a row
                  // of its own. A Wrap, not a Row — Gujarati runs ~30% longer
                  // than English and the app allows 1.3x text scale, so the
                  // pair must be free to fall onto a second line instead of
                  // ellipsizing. Separated by weight and ink alone (no glyph),
                  // which keeps a wrapped second line from opening on a
                  // stranded separator.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: UgamSpacing.sm,
                    runSpacing: 2,
                    children: [
                      Text(
                        date,
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                      Text(
                        source,
                        style: UgamText.captionStrong.copyWith(color: c.ink3),
                      ),
                    ],
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
