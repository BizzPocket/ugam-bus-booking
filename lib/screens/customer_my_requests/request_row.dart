part of '../customer_my_requests_screen.dart';

// ─── REQUEST ROW (photo-anchored) ─────────────────────────────────────

class _RequestRow extends StatelessWidget {
  final CustomerRequestEntry entry;
  final bool isHandler;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onViewChart;
  final VoidCallback onCancel;
  final VoidCallback onRequestCancel;
  final VoidCallback onContact;

  /// Re-books THIS trip after its hold lapsed. Row-scoped by nature (the seats
  /// that were released were on this tour), which is why it survived the lift
  /// of the general "add another request" action up to the page.
  final VoidCallback onRebook;

  /// Re-opens the advance UPI sheet for a booking sitting on a live hold.
  final Future<void> Function(CustomerRequestEntry entry) onPayAdvance;

  /// Finish paying a banded request-mode charge left unpaid at submit.
  final Future<void> Function(CustomerRequestEntry entry) onPayCharge;

  const _RequestRow({
    required this.entry,
    required this.isHandler,
    required this.onTap,
    required this.onEdit,
    required this.onViewChart,
    required this.onRebook,
    required this.onCancel,
    required this.onRequestCancel,
    required this.onContact,
    required this.onPayAdvance,
    required this.onPayCharge,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (statusLabel, statusTone) = _statusFor(entry);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Was a 76×88 graphite gradient tile — a placeholder that read
                // as an image that had failed to load, and whose only real
                // payload was a 9.5px date pill in its corner. The date is the
                // one fact on this card that appears nowhere else, so the
                // space now renders it at a size a person can actually read.
                // The route it also carried as initials ("S→M") is stated in
                // full one line to the right.
                _DateBlock(date: entry.tourDepartureDate, c: c),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.tourTitle,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.south_east_rounded,
                            size: 12,
                            color: c.ink2,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${entry.tourFromCity} → ${entry.tourToCity}',
                              style: UgamText.caption.copyWith(color: c.ink2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (entry.pickupLocationName != null &&
                          entry.pickupLocationName!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              Icons.place_rounded,
                              size: 12,
                              color: c.ink2,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${tr('pickup.reflect_label')}: ${entry.pickupLocationName!}',
                                style: UgamText.caption.copyWith(color: c.ink2),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: UgamSpacing.tight),
                      Row(
                        children: [
                          UgamStatusDot(label: statusLabel, tone: statusTone),
                          const SizedBox(width: UgamSpacing.sm),
                          Flexible(
                            child: Text(
                              _seatsLabel(entry),
                              style: UgamText.caption.copyWith(color: c.ink),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Seat-hold recovery. Sits ABOVE the informational chips because a
            // ticking deadline with money attached outranks anything else on
            // the card. Renders nothing unless this booking is on a hold.
            if (entry.isHeld || entry.holdExpired) ...[
              const SizedBox(height: UgamSpacing.tight),
              HoldCountdownStrip(
                entry: entry,
                onPay: () => onPayAdvance(entry),
                onRebook: onRebook,
              ),
            ]
            // Banded request-mode charge. No hold and no clock, so this is a
            // plain outstanding-balance strip rather than a countdown — but it
            // is the same recovery: a request left unpaid must offer a way to
            // finish, and a paid one must stop asking.
            else if (entry.canPayCharge || entry.paymentRecorded) ...[
              const SizedBox(height: UgamSpacing.tight),
              _ChargeStrip(
                entry: entry,
                onPay: () => onPayCharge(entry),
                c: c,
              ),
            ],
            // Chip strip is informational only (departure countdown / edited /
            // one-way / seats / cancel-requested / note). Actions live in the
            // single action bar below, so we never stack more than two strips
            // under the header. Always present now that it carries the
            // countdown, which every live booking has.
            const SizedBox(height: UgamSpacing.tight),
            _RowFooter(entry: entry, c: c),
            // ONE action strip: the single most relevant CTA inline plus a ⋮
            // overflow holding the rest. It is TONAL, not solid accent — the
            // page's one solid control is the bottom CTA, and a solid button
            // repeated once per list row is what made a page-level action look
            // like it belonged to a single card.
            _ActionBar(
              entry: entry,
              c: c,
              isHandler: isHandler,
              // The row tap opens the seat-layout sheet once seats are
              // visible, so "View my seat" is that same action, named.
              onViewSeat: onTap,
              onEdit: onEdit,
              onViewChart: onViewChart,
              onCancel: onCancel,
              onRequestCancel: onRequestCancel,
              onContact: onContact,
            ),
          ],
        ),
      ),
    );
  }

  (String, UgamStatusTone) _statusFor(CustomerRequestEntry e) {
    // Reveal "Seats assigned" (with numbers) only once the tour is locked.
    if (e.seatsVisible) {
      return (
        tr('customer_my_requests.chip_seats_assigned'),
        UgamStatusTone.good,
      );
    }
    // A cancelled/rejected ticket reads as cancelled regardless of stale seats.
    if (e.isCancelled) {
      return (tr('customer_my_requests.chip_cancelled'), UgamStatusTone.warm);
    }
    // Seats are HELD pending an advance. This is a live booking — the berths
    // are blocked on the chart for everyone else — so it must never fall
    // through to "Pending", and certainly not to "Cancelled", which is what it
    // used to do (there is no booking_requests row until the advance clears).
    if (e.isHeld) {
      return (tr('customer_my_requests.chip_held'), UgamStatusTone.warm);
    }
    // The hold lapsed unpaid. The seats went back on sale, so this is
    // re-bookable — which is why it is not folded into "Cancelled".
    if (e.holdExpired) {
      return (
        tr('customer_my_requests.chip_hold_expired'),
        UgamStatusTone.warm,
      );
    }
    // A booking reads "Confirmed" the moment it is organiser-confirmed OR holds
    // a provisionally-assigned seat — even before the tour is locked. The seat
    // NUMBER still stays hidden until lock (via seatsVisible above and the footer
    // chip), but the headline must not read "still being booked" for a rider who
    // already has a seat. `hasSeatsAssigned` is included so this pill AGREES with
    // the Confirmed tab's `_isConfirmedish` bucket — a seated rider was otherwise
    // mis-labelled "being finalized" while sitting inside the Confirmed tab.
    if (e.status == 'accepted' || e.isConfirmed || e.hasSeatsAssigned) {
      return (tr('customer_my_requests.chip_confirmed'), UgamStatusTone.good);
    }
    return (tr('customer_my_requests.chip_pending'), UgamStatusTone.warm);
  }

  String _seatsLabel(CustomerRequestEntry e) {
    final parts = <String>[];
    if (e.doubleSofa > 0) {
      parts.add(
        tr(
          'customer_my_requests.seats_double',
          namedArgs: {'count': e.doubleSofa.toString()},
        ),
      );
    }
    if (e.singleSofa > 0) {
      parts.add(
        tr(
          'customer_my_requests.seats_single',
          namedArgs: {'count': e.singleSofa.toString()},
        ),
      );
    }
    if (parts.isEmpty) {
      return tr(
        'customer_my_requests.seats_fallback',
        namedArgs: {'count': e.partySize.toString()},
      );
    }
    return parts.join(' + ');
  }
}

/// Departure date block — the row's leading element, replacing the graphite
/// placeholder tile that used to sit there.
///
/// Month above, day below, in tabular figures so a column of these lines up.
/// Recessed (`card` inside a `cardElev` row) rather than tinted: it is data,
/// not the row's action, and the accent is rationed to meaning.
class _DateBlock extends StatelessWidget {
  final DateTime date;
  final UgamColorSet c;

  const _DateBlock({required this.date, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      // Decorative box, not a tap target — the whole card takes the tap.
      width: UgamScale.px(context, 54),
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            // Three-letter month in the reader's language (`app.month.short.*`).
            customerMonthShort(date.month),
            style: UgamText.micro.copyWith(color: c.ink3),
            maxLines: 1,
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            date.day.toString().padLeft(2, '0'),
            style: UgamText.numLg.copyWith(color: c.ink),
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

class _RowFooter extends StatelessWidget {
  final CustomerRequestEntry entry;
  final UgamColorSet c;

  const _RowFooter({
    required this.entry,
    required this.c,
  });

  /// Assigned seat numbers, truncated so a large group booking can't bloat the
  /// chip past one line. UgamReqChip has no maxLines of its own, so we cap the
  /// list at source and append "…" (with a leading count) once it overflows.
  static String _seatsChipLabel(CustomerRequestEntry e) {
    // Distinct, in order: a whole double sofa is stored as TWO assignments on
    // one seat id, which printed "DU1, DU1, SL1".
    final ids = e.assignedSeats.map((s) => s.seatId).toSet().toList();
    const maxShown = 4;
    if (ids.length <= maxShown) return ids.join(', ');
    return tr(
      'customer_my_requests.seats_more',
      namedArgs: {
        'shown': ids.take(maxShown).join(', '),
        'count': ids.length.toString(),
      },
    );
  }

  /// Whole days from today to departure, date-only so a 23:00 booking for
  /// tomorrow morning still reads "tomorrow".
  static int _daysToDeparture(DateTime departure) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(departure.year, departure.month, departure.day);
    return d.difference(today).inDays;
  }

  /// "Departs today / tomorrow / in N days". The single most useful thing a
  /// customer with a live booking wants off this card, and the card carried
  /// no sense of time at all before.
  static (String, UgamChipVariant)? _departureChip(DateTime departure) {
    final days = _daysToDeparture(departure);
    if (days < 0) return null; // past trips never reach this list
    if (days == 0) {
      return (tr('customer_my_requests.departs_today'), UgamChipVariant.warm);
    }
    if (days == 1) {
      return (
        tr('customer_my_requests.departs_tomorrow'),
        UgamChipVariant.warm,
      );
    }
    return (
      tr(
        'customer_my_requests.departs_in_days',
        namedArgs: {'count': days.toString()},
      ),
      UgamChipVariant.neutral,
    );
  }

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];

    final departure = _departureChip(entry.tourDepartureDate);
    if (departure != null) {
      widgets.add(
        UgamReqChip(
          label: departure.$1,
          variant: departure.$2,
          leading: Icons.schedule_rounded,
        ),
      );
    }
    if (entry.wasEdited) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_edited'),
          variant: UgamChipVariant.neutral,
        ),
      );
    }
    if (entry.cancellationRequested) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_cancel_requested'),
          variant: UgamChipVariant.warm,
        ),
      );
    }
    if (entry.tripType == TripType.outboundOnly) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_oneway_out'),
          variant: UgamChipVariant.warm,
        ),
      );
    } else if (entry.tripType == TripType.returnOnly) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_oneway_return'),
          variant: UgamChipVariant.warm,
        ),
      );
    }
    // Seat NUMBERS are revealed only after the tour locks. Before that, show a
    // neutral "number coming soon" chip so the customer knows their seat is
    // secured but never sees a provisional number that may still change.
    if (entry.seatsVisible) {
      widgets.add(
        UgamReqChip(
          label: tr(
            'customer_my_requests.chip_seats',
            namedArgs: {'seats': _seatsChipLabel(entry)},
          ),
          variant: UgamChipVariant.good,
        ),
      );
    } else if (entry.hasSeatsAssigned) {
      // Seated but the tour isn't locked yet, so the NUMBER stays hidden. The
      // seat is secured (headline reads "Confirmed") — tell the rider the number
      // is coming, never that it's "still being finalized".
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_seat_after_lock'),
          variant: UgamChipVariant.neutral,
        ),
      );
    }

    // Defensive: `_live` never yields a departed trip, so the countdown chip
    // is always present in practice — but an empty strip must collapse rather
    // than paint a bare recessed bar.
    if (widgets.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Expanded(child: Wrap(spacing: 5, runSpacing: 5, children: widgets)),
          // Edit moved into the action bar below; the footer now only flags a
          // note the customer attached to the request.
          if (entry.note != null && entry.note!.isNotEmpty) ...[
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.sticky_note_2_outlined, size: 14, color: c.ink3),
          ],
        ],
      ),
    );
  }
}

/// One selectable action for the row's action bar / overflow menu.
class _RowAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Destructive (self-cancel) — tinted danger in the menu, and never promoted
  /// to the inline primary while any non-destructive action exists. When it is
  /// the only action left it renders inline as danger-tonal, never affirmative.
  final bool destructive;

  /// An exit, not a next step ("I want to cancel my seat", "Call to cancel").
  /// Never promoted over a real action, and when it is all there is it renders
  /// as a quiet ghost link — on a confirmed ticket the biggest button on the
  /// card used to be the one that gives the seat away.
  final bool quiet;

  const _RowAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.quiet = false,
  });
}

/// Outstanding-balance strip for a banded request-mode booking.
///
/// The hold path has [HoldCountdownStrip], which is built around a deadline. A
/// request has no hold and no clock, so this states the plainer fact: what is
/// still owed, or that a payment has been recorded and is awaiting the
/// organiser's confirmation. Once paid it stops offering to take money again —
/// which is the whole point of tracking `claimedPaise`.
class _ChargeStrip extends StatelessWidget {
  final CustomerRequestEntry entry;
  final VoidCallback onPay;
  final UgamColorSet c;

  const _ChargeStrip({
    required this.entry,
    required this.onPay,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final paid = entry.paymentRecorded;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: paid ? c.cardElev : c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: paid ? c.border : c.accent),
      ),
      child: Row(
        children: [
          Icon(
            paid ? Icons.hourglass_bottom_rounded : Icons.payments_outlined,
            size: 16,
            color: paid ? c.ink3 : c.accent,
          ),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              paid
                  ? tr('customer_my_requests.payment_recorded')
                  : tr('customer_my_requests.payment_due', namedArgs: {
                      'amount': Formatters.formatMoneyInr(
                        entry.outstandingPaise / 100,
                      ),
                    }),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: UgamText.caption.copyWith(color: paid ? c.ink2 : c.ink),
            ),
          ),
          if (!paid) ...[
            const SizedBox(width: UgamSpacing.sm),
            UgamButton(
              label: tr('customer_my_requests.payment_pay_now'),
              kind: UgamButtonKind.primary,
              onPressed: onPay,
            ),
          ],
        ],
      ),
    );
  }
}
