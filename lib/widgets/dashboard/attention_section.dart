import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/ugam.dart';
import 'dashboard_models.dart';

/// Section header used by the dashboard "Needs attention" and "Recent
/// requests" lists — a title, an optional count badge, and an optional
/// "see all" action with a 48dp hit area.
class DashboardSectionLabel extends StatelessWidget {
  final String label;
  final String? meta;
  final String? action;
  final VoidCallback? onAction;
  final UgamColorSet c;

  const DashboardSectionLabel({
    super.key,
    required this.label,
    required this.c,
    this.meta,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: UgamText.titleM.copyWith(color: c.ink)),
        if (meta != null) ...[
          const SizedBox(width: UgamSpacing.sm),
          UgamReqChip(label: meta!, variant: UgamChipVariant.neutral),
        ],
        const Spacer(),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            behavior: HitTestBehavior.opaque,
            // 48dp min hit area for the "See all" affordance.
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Text(action!,
                      style: UgamText.bodyStrong.copyWith(color: c.ink2)),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 16, color: c.ink2),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One actionable blocker row. Uses UgamCard's semantic tone (warm/good/accent)
/// for the tinted surface; the single top-priority row ([isPrimary]) carries
/// the lone accent chip so the dashboard spends its champagne exactly once.
class DashboardAttentionRow extends StatelessWidget {
  final AttentionItem item;
  final UgamColorSet c;
  final bool isPrimary;

  const DashboardAttentionRow({
    super.key,
    required this.item,
    required this.c,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    // Semantic tone drives the card tint + the leading icon colour. The neutral
    // tone stays an untinted surface so warm/good attention rows read louder.
    final cardTone = switch (item.tone) {
      UgamStatusTone.accent => UgamCardTone.accent,
      UgamStatusTone.good => UgamCardTone.good,
      UgamStatusTone.warm => UgamCardTone.warm,
      UgamStatusTone.neutral => UgamCardTone.none,
    };
    final iconColor = switch (item.tone) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };

    return UgamCard.plain(
      tone: cardTone,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.md),
      onTap: item.onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(item.ctaIcon, size: 18, color: iconColor),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.tour.title,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // 2 lines so the longer Gujarati/Hindi reason isn't clipped.
                Text(
                  item.reason,
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamReqChip(
            label: item.ctaLabel,
            variant:
                isPrimary ? UgamChipVariant.accent : UgamChipVariant.neutral,
          ),
        ],
      ),
    );
  }
}

/// Shown when there are active tours but nothing needs the agent right now — an
/// explicit "you're clear" affirmation instead of a silent empty gap.
class DashboardAllCaughtUp extends StatelessWidget {
  final int count;
  final UgamColorSet c;
  const DashboardAllCaughtUp({super.key, required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      tone: UgamCardTone.good,
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 22, color: c.good),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr('dashboard.all_caught_up'),
                    style: UgamText.titleS.copyWith(color: c.ink)),
                const SizedBox(height: 2),
                Text(
                  tr('dashboard.all_caught_up_subtitle',
                      namedArgs: {'n': '$count'}),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
