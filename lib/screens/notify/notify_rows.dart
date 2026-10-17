part of '../notify_screen.dart';

// ─── Notify passenger row ─────────────────────────────────────────────

class _NotifyRow extends StatelessWidget {
  final Passenger passenger;
  final NotifyRowState state;
  final UgamColorSet c;
  final VoidCallback onSend;

  const _NotifyRow({
    required this.passenger,
    required this.state,
    required this.c,
    required this.onSend,
  });

  bool get _isSent => state == NotifyRowState.notified;
  bool get _removed => state == NotifyRowState.seatRemoved;

  String get _statusLabel => switch (state) {
        NotifyRowState.notified => tr('notify.row_sent'),
        NotifyRowState.pending => tr('notify.row_pending'),
        NotifyRowState.seatRemoved => tr('notify.row_seat_removed'),
      };

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first.characters.first}${parts.last.characters.first}'.toUpperCase();
    }
    return name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    // A whole double sofa is one SeatAssignment PER LEG, so the raw map
    // listed "DL1, DL1". De-dupe on (bus, seat), first-seen order kept.
    final seen = <String>{};
    final seats = [
      for (final a in passenger.assignedSeats)
        if (seen.add('${a.busId}|${a.seatId}')) a.seatId,
    ].join(', ');
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      radius: UgamRadius.row,
      child: Row(
        children: [
          // Decorative avatar — scales, so ~30 rows stop reading as a wall of
          // full-size circles while their names shrink on a small phone.
          Container(
            width: UgamScale.px(context, 40),
            height: UgamScale.px(context, 40),
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(passenger.name),
              style: UgamText.caption.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.tight),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The name owns the full first line. The status dot used to
                // share it and squeezed most Gujarati/English names onto two
                // lines; it now rides the seat line below.
                Text(
                  passenger.displayName,
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                  // 2 lines before ellipsis — app-wide name rule.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      _removed
                          ? Icons.event_seat_outlined
                          : Icons.event_seat_rounded,
                      size: 11,
                      color: c.ink3,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        // Say WHAT happened rather than printing a bare dash:
                        // this rider is on the list precisely because the seat
                        // they were told about is gone.
                        _removed
                            ? tr('notify.seat_removed_line')
                            : (seats.isEmpty
                                ? '—'
                                : tr('notify.seat_label',
                                    namedArgs: {'seats': seats})),
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink2),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    // Bounded (Flexible): the dot's label is itself Flexible
                    // and needs a finite width to ellipsize against.
                    Flexible(
                      child: UgamStatusDot(
                        label: _statusLabel,
                        // A withdrawn seat is outstanding work, exactly like a
                        // pending send — warm attention, not a "done" green.
                        tone:
                            _isSent ? UgamStatusTone.good : UgamStatusTone.warm,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // A BUTTON, so it never wears the brand hue — even tonally. Thirty
          // rows of amber-tinted discs was the single largest accent spill on
          // this screen and it meant nothing: every row has this button, sent
          // or not. `good` still marks the ones already delivered (a real
          // semantic); the rest are plain neutral chrome. The row's own status
          // dot carries "pending".
          //
          // The withdrawn-seat row wears a HANDSET, not the chat glyph: its
          // action opens a call-them follow-up, not a WhatsApp send, and the
          // two must not look like the same button.
          UgamIconButton(
            icon: _removed ? Icons.call_rounded : Icons.chat_rounded,
            onTap: onSend,
            // Neutral on every row: 47 green discs repeated what the status
            // dot already says ("sent"). The dot carries state; this is chrome.
            tone: UgamIconButtonTone.neutral,
            semanticLabel: _statusLabel,
          ),
        ],
      ),
    );
  }
}

// ─── Sticky CTAs ──────────────────────────────────────────────────────

class _LockStickyCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final Future<void> Function(Tour) onLock;
  const _LockStickyCTA({
    required this.tour,
    required this.c,
    required this.onLock,
  });

  @override
  Widget build(BuildContext context) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;
    final canLock = allAssigned && hasHandler && hasPassengers;

    String? reason;
    if (!hasPassengers) {
      reason = tr('notify.lock_reason_no_passengers');
    } else if (!allAssigned) {
      reason = tr('notify.lock_reason_unassigned');
    } else if (!hasHandler) {
      reason = tr('notify.lock_reason_no_handler');
    }

    return UgamStickyCTA(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!canLock && reason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: Text(
                reason,
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
          UgamCTA(
            label: canLock
                ? tr('notify.lock_btn')
                : tr('notify.lock_btn_disabled'),
            leadingIcon: Icons.lock_rounded,
            onPressed: canLock ? () => onLock(tour) : null,
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool done;
  final String label;
  final UgamColorSet c;

  const _Check({required this.done, required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: done ? c.goodFill : c.cardElev,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            done ? Icons.check_rounded : Icons.circle_outlined,
            size: 14,
            color: done ? c.good : c.ink3,
          ),
        ),
        const SizedBox(width: UgamSpacing.tight),
        Expanded(
          child: Text(
            label,
            style: UgamText.body.copyWith(color: done ? c.ink : c.ink2),
          ),
        ),
      ],
    );
  }
}

// ─── Message-this-bus card + composer (F4 admin path) ──────────────────

/// A tappable card in the post-lock tracker that opens the per-bus
/// announcement composer. The agent can fire a quick free-text WhatsApp to
/// everyone on one bus (e.g. "Boarding moved to Gate 3").
class _BusMessageCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _BusMessageCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // `onTap` goes THROUGH the card so it gives press feedback like the
    // equivalent card on Settings; the outer GestureDetector swallowed it.
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          // Decorative medallion on a navigation row — not a selection.
          Container(
            width: UgamScale.px(context, 40),
            height: UgamScale.px(context, 40),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.campaign_rounded,
              size: UgamScale.px(context, 19),
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
                  tr('bus_message.card_title'),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('bus_message.card_subtitle'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}
