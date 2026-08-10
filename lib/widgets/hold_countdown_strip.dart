import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../services/customer_requests_store.dart';
import '../utils/formatters.dart';

/// The seat-hold recovery strip on a My Requests card.
///
/// *** THE GAP THIS FILLS ***
/// On a tour that collects an advance, holding seats and then dismissing the
/// UPI sheet left the customer with nothing: no countdown, no way to pay, no
/// notice when the hold lapsed — and, because the booking has no
/// `booking_requests` row until the advance clears, a ticket that refresh()
/// mislabelled "Cancelled". The seats were genuinely held the whole time.
///
/// So this strip states the two things the customer actually needs: how long
/// they have, and how to pay. Once the deadline passes it stops offering
/// payment — the seats are back on sale, so paying would buy nothing — and
/// offers re-booking instead.
class HoldCountdownStrip extends StatefulWidget {
  final CustomerRequestEntry entry;

  /// Opens the advance payment sheet for this hold.
  final Future<void> Function() onPay;

  /// Sends the customer back to the chart to pick seats again.
  final VoidCallback onRebook;

  /// Source of "now". Injectable because this widget's entire job is to react
  /// to the passage of time: a widget test advances a FAKE clock via
  /// `pump(duration)`, while `DateTime.now()` keeps reporting real wall time —
  /// so a hard-coded clock makes the lapse-while-on-screen behaviour
  /// untestable, which is exactly the behaviour that protects a customer from
  /// paying for seats that have already been released.
  final DateTime Function() clock;

  const HoldCountdownStrip({
    super.key,
    required this.entry,
    required this.onPay,
    required this.onRebook,
    this.clock = DateTime.now,
  });

  static const countdownKey = Key('hold_countdown');
  static const payKey = Key('hold_pay');
  static const rebookKey = Key('hold_rebook');

  @override
  State<HoldCountdownStrip> createState() => _HoldCountdownStripState();
}

class _HoldCountdownStripState extends State<HoldCountdownStrip> {
  Timer? _tick;
  late DateTime _now;
  bool _paying = false;

  @override
  void initState() {
    super.initState();
    _now = widget.clock();
    // One second, because the whole point is visible urgency. The timer only
    // runs while a live hold is on screen.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = widget.clock());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// m:ss. Padded seconds so the width does not jitter as it counts down.
  String _format(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    // A booking with no hold at all renders nothing — request-mode bookings and
    // ordinary confirmed ones must be untouched by this.
    if (!entry.isHeld && !entry.holdExpired) return const SizedBox.shrink();

    final c = UgamColors.of(context);
    final left = entry.holdRemaining(_now);
    // Recomputed against the ticking clock, not just the stored status: a hold
    // that lapses while the customer is looking at it must stop offering
    // payment on THIS frame, not after the next server refresh.
    final live = entry.isHeld && left > Duration.zero;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: live ? c.accentFill : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(
          color: live ? c.accent.withValues(alpha: 0.32) : c.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            live ? Icons.timer_outlined : Icons.timer_off_outlined,
            size: 16,
            color: live ? c.accent : c.ink3,
          ),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: live
                ? Row(
                    children: [
                      // The remaining time is its OWN element, in tabular
                      // figures, so the digits do not shuffle as they count
                      // down and the value stays independently readable.
                      Text(
                        key: HoldCountdownStrip.countdownKey,
                        _format(left),
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(
                            color: c.accent,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          tr('customer_my_requests.hold_left_suffix'),
                          style: UgamText.caption.copyWith(
                            color: c.accent,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                : Text(
                    tr('customer_my_requests.hold_expired_note'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontSize: 12,
                    ),
                  ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          if (live && entry.canPayAdvance)
            UgamButton(
              key: HoldCountdownStrip.payKey,
              // The label is stable while paying — only the button disables.
              // Swapping the text mid-tap makes an already-anxious moment
              // (money leaving, seats on a clock) read as an error.
              label: tr(
                'customer_my_requests.hold_pay',
                namedArgs: {
                  'amount': Formatters.formatMoneyInr(
                    entry.advancePaise / 100,
                  ),
                },
              ),
              kind: UgamButtonKind.primary,
              onPressed: _paying
                  ? null
                  : () async {
                      setState(() => _paying = true);
                      try {
                        await widget.onPay();
                      } finally {
                        if (mounted) setState(() => _paying = false);
                      }
                    },
            )
          else if (!live)
            UgamButton(
              key: HoldCountdownStrip.rebookKey,
              label: tr('customer_my_requests.hold_rebook'),
              kind: UgamButtonKind.neutral,
              onPressed: widget.onRebook,
            ),
        ],
      ),
    );
  }
}
