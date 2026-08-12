// Shared-seat rider chooser: a Double Sofa can carry up to four riders
// across GO+RET, so the handler picks whom to act on first.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../design/ugam.dart';
import '../../models/passenger.dart';
import '../../models/trip_type.dart';
import '../../utils/passenger_display.dart';
import '../../utils/seat_occupants.dart';
import 'handler_atoms.dart';

// ─── Leg-shared chooser sheet ───────────────────────────────────────────

/// A chooser for a shared seat. When the seat is leg-divided — different riders
/// per leg (an outbound-only + a return-only, or a round-trip sharing with a
/// one-way rider) — the handler collects from ONE leg at a time: the GO riders
/// while the bus is going out, the RETURN riders once GO is done. A GO/Return
/// toggle (mirroring the attendance view) switches between them, opening on the
/// active leg by default. A non-divided seat (same riders on both legs, or all
/// on one leg) lists everyone with no toggle. Each row carries phone + a Call
/// button + a Collect button, so Call never opens the collect sheet.
class HandlerOccupantChooserSheet extends StatefulWidget {
  final String seatId;

  /// The bus this berth belongs to. Seat ids are only unique WITHIN a bus, so
  /// the per-seat leg lookup needs it to resolve the right assignment.
  final String busId;
  final List<Passenger> occupants;

  /// Whether the agent has completed the outbound leg — seeds the default leg
  /// to RETURN so the handler collects from the riders still aboard.
  final bool outboundDone;
  final ValueChanged<Passenger> onPick;

  const HandlerOccupantChooserSheet({
    super.key,
    required this.seatId,
    required this.busId,
    required this.occupants,
    required this.outboundDone,
    required this.onPick,
  });

  @override
  State<HandlerOccupantChooserSheet> createState() =>
      _HandlerOccupantChooserSheetState();
}

class _HandlerOccupantChooserSheetState
    extends State<HandlerOccupantChooserSheet> {
  late CollectLeg _leg = defaultCollectLeg(
    widget.occupants,
    outboundDone: widget.outboundDone,
  );

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Seat-scoped: the leg comes from each rider's assignment for THIS berth,
    // not their overall trip, so the RETURN chooser can't offer a rider whose
    // return berth is a different seat.
    final hasSplit = seatHasLegSplit(
      widget.occupants,
      seatId: widget.seatId,
      busId: widget.busId,
    );
    final shown = hasSplit
        ? occupantsForCollectLeg(
            widget.occupants,
            _leg,
            seatId: widget.seatId,
            busId: widget.busId,
          )
        : widget.occupants;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('handler_chart.leg_shared_intro'),
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        if (hasSplit) ...[
          const SizedBox(height: UgamSpacing.md),
          // GO / Return leg toggle — same control the attendance view uses.
          UgamTabPills(
            items: [
              UgamTabItem(label: tr('handler_chart.att_leg_go')),
              UgamTabItem(label: tr('handler_chart.att_leg_ret')),
            ],
            currentIndex: _leg == CollectLeg.go ? 0 : 1,
            onChanged: (i) =>
                setState(() => _leg = i == 0 ? CollectLeg.go : CollectLeg.ret),
          ),
        ],
        const SizedBox(height: UgamSpacing.md),
        // Cross-fade the occupant list when the GO/RET leg toggle changes so the
        // tiles swap smoothly instead of popping. Contained region only — the
        // sheet's surrounding layout is untouched.
        AnimatedSwitcher(
          duration: UgamMotion.sheet,
          switchInCurve: UgamMotion.easeOut,
          switchOutCurve: UgamMotion.easeOut,
          child: Column(
            key: ValueKey<CollectLeg>(_leg),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(height: UgamSpacing.sm),
                _LegSharedTile(
                  passenger: shown[i],
                  // The badge reads each rider's own leg (GO / RET / round-trip).
                  leg: shown[i].tripType,
                  onPick: () => widget.onPick(shown[i]),
                  c: c,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _LegSharedTile extends StatelessWidget {
  final Passenger passenger;
  final TripType leg;
  final VoidCallback onPick;
  final UgamColorSet c;

  const _LegSharedTile({
    required this.passenger,
    required this.leg,
    required this.onPick,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    // Call and Collect are separate actions — tapping Call must not open the
    // collect sheet (the old full-card onTap combined them).
    return UgamCard.plain(
      elev: true,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          HandlerTripBadge(tripType: leg, c: c),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  p.displayName,
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  hasPhone ? p.phone : tr('handler_chart.no_mobile'),
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(color: hasPhone ? c.ink2 : c.ink3),
                  ),
                ),
              ],
            ),
          ),
          if (hasPhone) ...[
            const SizedBox(width: UgamSpacing.sm),
            HandlerCallButton(phone: p.phone),
          ],
          const SizedBox(width: UgamSpacing.sm),
          UgamButton(
            label: tr('handler_chart.collect_action'),
            icon: Icons.payments_rounded,
            kind: UgamButtonKind.tonal,
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}
