part of '../collection_screen.dart';

String? _tripLabel(TripType t) => switch (t) {
  TripType.roundTrip => null,
  TripType.outboundOnly => tr('collection.trip_outbound_only'),
  TripType.returnOnly => tr('collection.trip_return_only'),
};

class _PassengerRow extends StatelessWidget {
  final _SeatCollectionLine line;
  final Bus bus;
  final VoidCallback onTap;
  final VoidCallback onMarkPaid;

  /// Reverse the money recorded on this seat. Null when nothing is recorded.
  final VoidCallback? onUndoPayment;

  const _PassengerRow({
    required this.line,
    required this.bus,
    required this.onTap,
    required this.onMarkPaid,
    this.onUndoPayment,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = line.passenger;
    // Global pickup-code lookup for the trailing name tag; null (degrade to
    // name-only) when the controller isn't registered.
    final pickup = Get.isRegistered<PickupController>()
        ? Get.find<PickupController>()
        : null;
    final due = line.due;
    final col = line.col;
    final received = col?.amountReceived ?? 0;
    final returned = col?.amountRefunded ?? 0;
    final trip = _tripLabel(passenger.tripType);
    // Everything below reads the LIVE balance (see _SeatCollectionLine), so a
    // rider carried in from another bus shows the DIFFERENCE at this bus's
    // band — not the full fare over again, and not a stale "settled".
    final isShortfall = line.isShortfall;
    final shortfall = line.stillToCollect;

    // Status chip resolution. UgamReqChip carries the tone via variant, and
    // every state here has a real semantic token: money handed back is warm,
    // money still owed is danger, settled is good, untouched is neutral. The
    // "due" state used to borrow the accent on the stated grounds that the
    // chip set had no danger tone — [UgamChipVariant.danger] exists, so that
    // note was stale and the amber was buying nothing.
    late final String chipLabel;
    late final UgamChipVariant chipVariant;
    if (line.isReturnDue) {
      chipLabel = tr(
        'collection.chip_return',
        namedArgs: {'amount': Formatters.formatMoneyInr(line.changeToReturn)},
      );
      chipVariant = UgamChipVariant.warm;
    } else if (isShortfall) {
      chipLabel = tr(
        'collection.chip_due',
        namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
      );
      chipVariant = UgamChipVariant.danger;
    } else if (received > 0) {
      chipLabel = tr('collection.chip_paid');
      chipVariant = UgamChipVariant.good;
    } else {
      chipLabel = tr('collection.chip_not_collected');
      chipVariant = UgamChipVariant.neutral;
    }

    final card = UgamCard.plain(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Name stays flexible so it can never overflow, but wraps to
                    // 2 lines before it ellipsises (app-wide rule — see
                    // UgamRequestRow); the pickup-CODE tag is a fixed trailing
                    // chip that baseline-aligns to the name's first line.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(
                            passenger.displayName,
                            style: UgamText.titleS.copyWith(color: c.ink),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Only with a live controller — an Obx whose closure
                        // reads no observable throws (see PickupController.
                        // codeFor).
                        if (pickup != null)
                          Obx(() {
                            final code = pickup.codeFor(
                              passenger.pickupLocationId,
                            );
                            if (code == null || code.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(
                                left: UgamSpacing.sm,
                              ),
                              child: UgamReqChip(
                                label: code,
                                variant: UgamChipVariant.neutral,
                              ),
                            );
                          }),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      passenger.phone.trim().isEmpty
                          ? tr(
                              'collection.seat_label',
                              namedArgs: {'seat': line.seatId},
                            )
                          : tr(
                              'collection.phone_seat_label',
                              namedArgs: {
                                'phone': passenger.phone,
                                'seat': line.seatId,
                              },
                            ),
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (trip != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          trip,
                          // A status word that must hold against the caption
                          // copy around it → [captionStrong]. `micro` is
                          // Latin-only and "ફક્ત પાછા આવવાનું" is not.
                          style: UgamText.captionStrong.copyWith(color: c.warm),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // The unverified-UPI hint moved DOWN here, onto the same
                    // line as the rest of the rider's detail — the pattern
                    // [UgamRequestRow] already uses for secondary chips.
                    //
                    // It used to be a second natural-width chip in the trailing
                    // cluster. Row lays non-flex children out with UNBOUNDED
                    // main-axis constraints, so a money chip + this chip + the
                    // 44pt settle button could together exceed the card at
                    // 320px with Gujarati labels at the 1.3x text scale
                    // app.dart permits: the Expanded name got 0 and the row
                    // overflowed. Only ONE natural-width chip rides the top
                    // line now, and it can no longer be starved.
                    if (line.pendingClaim != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: UgamReqChip(
                          label: tr(
                            'collection.upi_pending_chip',
                            namedArgs: {
                              'n': Formatters.formatMoneyInr(
                                line.pendingClaim!.amountRupees,
                              ),
                            },
                          ),
                          variant: UgamChipVariant.warm,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamReqChip(label: chipLabel, variant: chipVariant),
              // Settle-in-full, on the row. 44×44 (the touch floor) and 8dp
              // clear of the chip beside it, so it can be hit one-handed
              // without opening the sheet by mistake.
              if (isShortfall) ...[
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  key: ValueKey('mark-paid-${line.seatId}-${passenger.id}'),
                  icon: Icons.check_rounded,
                  // A BUTTON — never the brand hue. The danger chip beside it
                  // already says how much is owed; the control itself is plain
                  // chrome, exactly as `action` is a neutral in the palette.
                  tone: UgamIconButtonTone.neutral,
                  semanticLabel: tr(
                    'collection.mark_paid',
                    namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
                  ),
                  onTap: onMarkPaid,
                ),
              ],
              // Undo, in the SAME slot the ✓ occupies on an owing row — so a
              // Paid / To-return row gets its reverse control exactly where the
              // settle control was, and the two never share a row (no extra
              // width at 320px). Confirmed by a dialog before anything moves.
              //
              // GHOST, not a filled disc: a paid row is finished business, so
              // its reverse control must not shout as loud as the ✓ on an
              // owing row. Same 44pt hit box (the touch floor), but no fill and
              // a muted ink — it is there when wanted, invisible when scanning.
              if (!isShortfall && onUndoPayment != null) ...[
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  key: ValueKey('undo-paid-${line.seatId}-${passenger.id}'),
                  icon: Icons.undo_rounded,
                  tone: UgamIconButtonTone.neutral,
                  fillOverride: Colors.transparent,
                  inkOverride: c.ink3,
                  iconSize: 17,
                  semanticLabel: tr('collection.undo_payment_title'),
                  onTap: onUndoPayment!,
                ),
              ],
            ],
          ),
          // Fare · Received (· Returned) on ONE caption line. This used to be
          // a two-column label-over-value block that labelled the FARE "Due",
          // so a paid rider read "Due ₹3,400" and an unpaid one saw the same
          // figure twice (chip + metric). The chip owns "how much is owed";
          // this line is the record: what the seat costs and what came in.
          // Money handed back appears only when there is some.
          const SizedBox(height: 3),
          Text.rich(
            TextSpan(
              children: [
                _metricSpan(
                  tr('collection.metric_fare'),
                  Formatters.formatMoneyInr(due),
                  c,
                ),
                _metricSep(c),
                _metricSpan(
                  tr('collection.received'),
                  Formatters.formatMoneyInr(received),
                  c,
                ),
                if (returned > 0) ...[
                  _metricSep(c),
                  _metricSpan(
                    tr('collection.metric_returned'),
                    Formatters.formatMoneyInr(returned),
                    c,
                  ),
                ],
              ],
            ),
            style: UgamText.tabular(UgamText.caption.copyWith(color: c.ink2)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // Nothing owed → a plain row, no action affordance at all.
    if (!isShortfall) return card;

    // One-tap full settlement. It rides ON the row (44×44, next to the status
    // chip) instead of a full-width button stacked underneath: the row is a
    // list item in a long seat list, and a stacked CTA per seat turned the
    // list into a column of web cards. Swipe-right settles too.
    return UgamSwipeAction(
      key: ValueKey('collect-swipe-${line.seatId}-${passenger.id}'),
      rightIcon: Icons.check_rounded,
      rightLabel: tr(
        'collection.mark_paid',
        namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
      ),
      onRight: onMarkPaid,
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: card,
    );
  }
}

/// "Fare ₹3,400" — the label in the caption ink, the figure a step stronger so
/// the money still leads. Wraps (maxLines 2 on the host) rather than losing a
/// digit at the 1.3x text scale.
InlineSpan _metricSpan(String label, String value, UgamColorSet c) => TextSpan(
  children: [
    TextSpan(text: '$label '),
    TextSpan(
      text: value,
      style: UgamText.captionStrong.copyWith(color: c.ink),
    ),
  ],
);

InlineSpan _metricSep(UgamColorSet c) => TextSpan(
  text: '  ·  ',
  style: TextStyle(color: c.ink3),
);
