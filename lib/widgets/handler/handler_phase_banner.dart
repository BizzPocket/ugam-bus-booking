import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/ugam.dart';
import '../../models/handler_phase.dart';
import '../../utils/formatters.dart';

/// The one thing on the handler surface that says what to do next.
///
/// It sits above the dock and is visible from all four tabs, because the
/// failure it fixes is structural: the old screen rendered the money hero, the
/// settlement card, the leg-completion card and the boarding tally at equal
/// weight from the moment it opened, so the app never distinguished a handler
/// standing at the depot from one counting cash at midnight. Everything was
/// available and nothing was suggested.
///
/// The banner shows three things and no more — where the trip is, the single
/// number that matters in that phase, and the one action that moves it on.
/// [onOpen] jumps to the tab that number belongs to, so the banner is also the
/// navigation for the phase.
class HandlerPhaseBanner extends StatelessWidget {
  final HandlerPhase phase;

  /// The phase's headline progress, already localised — "18 of 42 boarded",
  /// "₹8,600 still to collect".
  final String detail;

  /// Where the bus is right now, when the phase has such a thing (the current
  /// pickup stop while boarding). Null hides the line.
  final String? sublabel;

  /// The milestone offered, or null in [HandlerPhase.settling] /
  /// [HandlerPhase.closed] where the next step isn't a stamp.
  final HandlerMilestone? milestone;

  /// Fires the milestone. Null while a stamp is in flight, which also disables
  /// the CTA — these are hard to walk back, so a double tap must not double
  /// fire even though the RPC is idempotent.
  final VoidCallback? onMilestone;

  /// Tapping the body opens the tab this phase is about.
  final VoidCallback? onOpen;

  /// Cash still to hand over, shown as the CTA in [HandlerPhase.settling].
  final double outstanding;
  final VoidCallback? onSettle;

  const HandlerPhaseBanner({
    super.key,
    required this.phase,
    required this.detail,
    required this.milestone,
    this.sublabel,
    this.onMilestone,
    this.onOpen,
    this.outstanding = 0,
    this.onSettle,
  });

  /// Phase colour. Settling is the only one that shouts: it is the state where
  /// the handler is personally holding the agent's money.
  Color _tone(UgamColorSet c) {
    switch (phase) {
      case HandlerPhase.boardingGo:
      case HandlerPhase.boardingRet:
        return c.accent;
      case HandlerPhase.enRouteGo:
      case HandlerPhase.enRouteRet:
        return c.ink2;
      case HandlerPhase.settling:
        return c.warm;
      case HandlerPhase.closed:
        return c.good;
    }
  }

  IconData get _icon {
    switch (phase) {
      case HandlerPhase.boardingGo:
      case HandlerPhase.boardingRet:
        return Icons.how_to_reg_rounded;
      case HandlerPhase.enRouteGo:
      case HandlerPhase.enRouteRet:
        return Icons.directions_bus_filled_rounded;
      case HandlerPhase.settling:
        return Icons.account_balance_wallet_rounded;
      case HandlerPhase.closed:
        return Icons.check_circle_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tone = _tone(c);
    final showSettle = phase == HandlerPhase.settling && onSettle != null;

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(UgamRadius.row),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: tone,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Icon(_icon, size: 16, color: tone),
                const SizedBox(width: UgamSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        phase.label.toUpperCase(),
                        style: UgamText.micro.copyWith(color: tone),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        detail,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (sublabel != null && sublabel!.isNotEmpty)
                        Text(
                          sublabel!,
                          style: UgamText.caption.copyWith(color: c.ink2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (onOpen != null)
                  Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
              ],
            ),
          ),
          if (showSettle) ...[
            const SizedBox(height: UgamSpacing.md),
            UgamCTA(
              label: tr('handler_phase.action_settle'),
              leadingIcon: Icons.account_balance_wallet_rounded,
              trailingValue: Formatters.formatMoneyInr(outstanding),
              onPressed: onSettle,
            ),
          ] else if (milestone != null) ...[
            const SizedBox(height: UgamSpacing.md),
            UgamCTA(
              label: milestone!.label,
              leadingIcon: _milestoneIcon(milestone!),
              // Null while in flight — UgamCTA renders a disabled state, which
              // is the whole feedback a handler gets on a slow link.
              onPressed: onMilestone,
            ),
          ],
        ],
      ),
    );
  }

  IconData _milestoneIcon(HandlerMilestone m) {
    switch (m) {
      case HandlerMilestone.departGo:
      case HandlerMilestone.departRet:
        return Icons.play_arrow_rounded;
      case HandlerMilestone.arriveGo:
        return Icons.flag_rounded;
      case HandlerMilestone.endTrip:
        return Icons.done_all_rounded;
    }
  }
}
