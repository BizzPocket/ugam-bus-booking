part of 'handler_money_tab.dart';

/// A rider's outstanding line on this bus.
class _CollectLine {
  final Passenger passenger;
  final String seatId;
  final double due;
  final Collection? collection;
  final SeatMoneyState state;

  /// What the rider says they paid by UPI that the agent has not verified
  /// yet — ₹0 when nothing is claimed. Shown on the row so the handler does
  /// not walk up and ask for money that may already be in the agent's bank.
  final double claimedOnline;

  const _CollectLine({
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.collection,
    required this.state,
    this.claimedOnline = 0,
  });

  /// What is still owed (positive) or owed back (negative).
  double get balance => liveBalanceOf(due, collection);
}

enum _MoneyFilter {
  due,
  toReturn,
  all;

  String get label => switch (this) {
    _MoneyFilter.due => tr('collection.filter_to_collect'),
    _MoneyFilter.toReturn => tr('collection.filter_to_return'),
    _MoneyFilter.all => tr('collection.filter_all'),
  };

  bool matches(_CollectLine l) => switch (this) {
    _MoneyFilter.due =>
      l.state == SeatMoneyState.uncollected || l.state == SeatMoneyState.owing,
    _MoneyFilter.toReturn => l.state == SeatMoneyState.returnDue,
    _MoneyFilter.all => true,
  };
}

/// One rider line: who, which seat, what they owe, and a call button — the
/// call-first roster the redesign put back.
class _CollectRow extends StatelessWidget {
  final _CollectLine line;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool inDueFilter;

  const _CollectRow({
    required this.line,
    required this.c,
    required this.onTap,
    this.inDueFilter = false,
  });

  /// Status dot tone. Owed money is the NORMAL state of this list, so it is
  /// neutral — the accent is not spent on twenty identical rows.
  Color get _tone => switch (line.state) {
    SeatMoneyState.paid => c.good,
    SeatMoneyState.returnDue => c.warm,
    SeatMoneyState.owing || SeatMoneyState.uncollected => c.ink3,
  };

  /// Amount ink: plain ink for what is owed; only paid (good) and change to
  /// hand back (warm) keep a hue, because those are the exceptions.
  Color get _amountTone => switch (line.state) {
    SeatMoneyState.paid => c.good,
    SeatMoneyState.returnDue => c.warm,
    SeatMoneyState.owing || SeatMoneyState.uncollected => c.ink,
  };

  /// The status line, or null when it would only repeat the filter.
  String? get _statusLabel {
    switch (line.state) {
      case SeatMoneyState.paid:
        return tr('handler_chart.money_paid');
      case SeatMoneyState.returnDue:
        return tr('handler_chart.money_return_due');
      case SeatMoneyState.owing:
        // Nothing in yet ("owing" is also the state of a never-touched rider):
        // same as uncollected, never "₹0 received".
        if (netCollectedOf(line.collection) <= Collection.kMoneyEpsilon) {
          return inDueFilter ? null : tr('handler_chart.money_not_collected');
        }
        // A part-payment says how much came in — "Owing" next to an amount
        // that is already the remainder told the handler nothing new.
        return tr(
          'handler_chart.money_received_part',
          namedArgs: {
            'amount': Formatters.formatMoneyInr(
              netCollectedOf(line.collection),
            ),
          },
        );
      case SeatMoneyState.uncollected:
        return inDueFilter ? null : tr('handler_chart.money_not_collected');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = line.passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    final amount = line.state == SeatMoneyState.paid
        ? line.due
        : line.balance.abs();
    final status = _statusLabel;

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamCard.plain(
        padding: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          child: Padding(
            padding: const EdgeInsets.all(UgamSpacing.md),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    line.seatId,
                    style: UgamText.micro.copyWith(color: c.accent),
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.displayName,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (status != null)
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _tone,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: UgamSpacing.xs),
                            Flexible(
                              child: Text(
                                status,
                                style: UgamText.caption.copyWith(
                                  color: c.ink2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      // The rider's own word that money already went by UPI.
                      // Warm, not green: it is unverified until the agent
                      // matches it against the bank.
                      if (line.claimedOnline > Collection.kMoneyEpsilon)
                        Text(
                          tr(
                            'handler_chart.upi_claim_row',
                            namedArgs: {
                              'amount': Formatters.formatMoneyInr(
                                line.claimedOnline,
                              ),
                            },
                          ),
                          style: UgamText.micro.copyWith(color: c.warm),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                Text(
                  Formatters.formatMoneyInr(amount),
                  style: UgamText.bodyStrong.copyWith(color: _amountTone),
                ),
                if (hasPhone) ...[
                  const SizedBox(width: UgamSpacing.sm),
                  UgamIconButton(
                    icon: Icons.call_rounded,
                    onTap: () => PhoneDialer.call(p.phone),
                    semanticLabel: tr('handler_chart.call_semantic'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
