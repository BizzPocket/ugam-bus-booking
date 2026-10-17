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

  /// One-line strip instead of the full card. The full banner (number, stop,
  /// CTA) belongs on the tab its number lives on; on every other tab it was
  /// ~200px of chrome repeating what that tab's own hero already says, so it
  /// shrinks to "where the trip is" plus a tap target back to its tab. An
  /// empty [detail] shows the phase name alone (the Money tab, whose hero
  /// already carries every figure the banner would repeat).
  final bool compact;

  /// Whether the milestone / hand-over action shows at all. Only on the tab the
  /// phase belongs to — elsewhere the strip's tap leads there instead.
  final bool showAction;

  /// False while the milestone is offered EARLY — "We've left" with riders
  /// still not aboard. The action stays available (somebody always no-shows)
  /// but drops from the solid accent slab to a neutral button, so the screen
  /// stops shouting "leave now" over half an empty bus.
  final bool milestoneReady;

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
    this.compact = false,
    this.showAction = true,
    this.milestoneReady = true,
  });

  /// Phase colour. Settling is the only one that shouts: it is the state where
  /// the handler is personally holding the agent's money.
  Color _tone(UgamColorSet c) => switch (phase) {
    HandlerPhase.boardingGo || HandlerPhase.boardingRet => c.accent,
    HandlerPhase.enRouteGo || HandlerPhase.enRouteRet => c.ink2,
    HandlerPhase.settling => c.warm,
    HandlerPhase.closed => c.good,
  };

  IconData get _icon => switch (phase) {
    HandlerPhase.boardingGo || HandlerPhase.boardingRet =>
      Icons.how_to_reg_rounded,
    HandlerPhase.enRouteGo || HandlerPhase.enRouteRet =>
      Icons.directions_bus_filled_rounded,
    HandlerPhase.settling => Icons.account_balance_wallet_rounded,
    HandlerPhase.closed => Icons.check_circle_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tone = _tone(c);
    final showSettle =
        showAction && phase == HandlerPhase.settling && onSettle != null;
    final showMilestone = showAction && !showSettle && milestone != null;

    return UgamCard.plain(
      padding: compact
          ? const EdgeInsets.symmetric(
              horizontal: UgamSpacing.md,
              vertical: UgamSpacing.sm,
            )
          : const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(UgamRadius.row),
            child: compact ? _stripRow(c, tone) : _fullRow(c, tone),
          ),
          if (showSettle) ...[
            SizedBox(height: compact ? UgamSpacing.sm : UgamSpacing.md),
            UgamCTA(
              label: tr('handler_phase.action_settle'),
              leadingIcon: Icons.account_balance_wallet_rounded,
              trailingValue: Formatters.formatMoneyInr(outstanding),
              onPressed: onSettle,
            ),
          ] else if (showMilestone) ...[
            SizedBox(height: compact ? UgamSpacing.sm : UgamSpacing.md),
            if (milestoneReady)
              UgamCTA(
                label: milestone!.label,
                leadingIcon: _milestoneIcon(milestone!),
                // Null while in flight — UgamCTA renders a disabled state,
                // which is the whole feedback a handler gets on a slow link.
                onPressed: onMilestone,
              )
            else
              UgamButton(
                label: milestone!.label,
                icon: _milestoneIcon(milestone!),
                kind: UgamButtonKind.neutral,
                expand: true,
                onPressed: onMilestone,
              ),
          ],
        ],
      ),
    );
  }

  Widget _fullRow(UgamColorSet c, Color tone) => Row(
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
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
            if (detail.isNotEmpty)
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
  );

  /// The compact form: phase + (optional) headline on ONE line.
  Widget _stripRow(UgamColorSet c, Color tone) => Row(
    children: [
      Icon(_icon, size: 16, color: tone),
      const SizedBox(width: UgamSpacing.sm),
      Text(
        phase.label.toUpperCase(),
        style: UgamText.micro.copyWith(color: tone),
        maxLines: 1,
      ),
      const SizedBox(width: UgamSpacing.sm),
      Expanded(
        child: Text(
          detail,
          style: UgamText.caption.copyWith(color: c.ink),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (onOpen != null)
        Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
    ],
  );

  IconData _milestoneIcon(HandlerMilestone m) => switch (m) {
    HandlerMilestone.departGo || HandlerMilestone.departRet =>
      Icons.play_arrow_rounded,
    HandlerMilestone.arriveGo => Icons.flag_rounded,
    HandlerMilestone.endTrip => Icons.done_all_rounded,
  };
}
