part of '../tour_money_board_screen.dart';

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

  Future<void> _confirm(PaymentClaim claim) async {
    try {
      await money.confirmPaymentClaim(claim.id);
      AppSnackBar.success(tr('tour_money_board.upi_confirmed'));
    } catch (_) {
      AppSnackBar.error(tr('tour_money_board.upi_confirm_failed'));
    }
  }

  Future<void> _reject(PaymentClaim claim) async {
    try {
      await money.rejectPaymentClaim(claim.id);
      AppSnackBar.info(tr('tour_money_board.upi_rejected'));
    } catch (_) {
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
                  onPressed: () => _confirm(claim),
                ),
                const SizedBox(width: UgamSpacing.sm),
                UgamButton(
                  label: tr('tour_money_board.upi_reject'),
                  kind: UgamButtonKind.ghost,
                  onPressed: () => _reject(claim),
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
  final PnlConfidence confidence;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _PnlEntryCard({
    required this.summary,
    required this.confidence,
    required this.onTap,
    required this.c,
  });

  /// "Trip is in profit" is a claim about an outcome. Before the trip has
  /// earned anything it can only be a projection, so the card says which.
  String get _verdict {
    if (summary.totalNetBilled >= 0) {
      return confidence.isProjected
          ? tr('tour_money_board.trip_projected_profit')
          : tr('tour_money_board.trip_in_profit');
    }
    return confidence.isProjected
        ? tr('tour_money_board.trip_projected_loss')
        : tr('tour_money_board.trip_at_loss');
  }

  @override
  Widget build(BuildContext context) {
    final billed = summary.totalNetBilled;
    final inProfit = billed >= 0;
    // Neutral ink for a figure that is a forecast or is missing a cost —
    // green is reserved for a settled result (mirrors _TripTotalCard).
    final tone = !inProfit
        ? c.danger
        : (confidence.isProvisional ? c.ink : c.good);
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
            // Top-anchored: the text column now grows by a whole caveat strip,
            // and a centred icon drifted away from the title it belongs to.
            crossAxisAlignment: CrossAxisAlignment.start,
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
                      _verdict,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 2,
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
                    // The trip's second figure — the same "cash so far" the
                    // Trip P&L behind this tap and the trip's Finance row show.
                    const SizedBox(height: 2),
                    CashSoFarLine(value: summary.totalNet),
                    // "Per bus & per handler" describes what a tap reveals —
                    // useful when the figure is calm, but it is the first thing
                    // to go once something is wrong with the number itself. The
                    // chevron already promises detail; three stacked meta lines
                    // buried the one line that actually matters.
                    if (!confidence.costsIncomplete) ...[
                      const SizedBox(height: 2),
                      Text(
                        tr('trip_pnl.entry_sub'),
                        style: UgamText.caption.copyWith(color: c.ink3),
                      ),
                    ],
                    // This card headlines BILLED net while the sticky capsule at
                    // the foot of the same screen headlines CASH net. Two right
                    // answers to two different questions — but unlabelled, one
                    // screen appeared to disagree with itself.
                    const SizedBox(height: 2),
                    Text(
                      tr('money.basis_billed'),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    // An unentered rent inflates the very figure this card
                    // headlines, so the caveat travels with the number rather
                    // than waiting to be discovered one screen deeper.
                    if (confidence.costsIncomplete) ...[
                      const SizedBox(height: UgamSpacing.sm),
                      UgamCaveat(
                        message: summary.busesMissingRent == 1
                            ? tr('trip_pnl.rent_missing_one')
                            : tr(
                                'trip_pnl.rent_missing_many',
                                namedArgs: {
                                  'n': '${summary.busesMissingRent}',
                                },
                              ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Pinned to the top rather than floating at the vertical centre
              // of a column whose height swings with the caveat strip.
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: c.ink3,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
