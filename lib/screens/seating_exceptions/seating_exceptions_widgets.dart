part of '../seating_exceptions_screen.dart';

// ─── Loading ─────────────────────────────────────────────────────────────

/// The list's own shape while the roster loads — a section eyebrow followed by
/// three exception-card blocks, on the same gutters and rhythm as the real
/// [ListView] above. A centred spinner would have told the agent nothing about
/// what is arriving; this holds the layout still so the real cards drop into
/// place instead of shoving the page around.
class _ExceptionsSkeleton extends StatelessWidget {
  const _ExceptionsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const UgamSkeleton.text(width: 96),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < 3; i++) ...[
          const UgamSkeleton(height: 92, radius: UgamRadius.row),
          const SizedBox(height: UgamSpacing.md),
        ],
      ],
    );
  }
}

// ─── Section header ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  /// When true the header is tinted danger and gains a leading alert glyph —
  /// used for the pinned Priority section so it reads as urgent.
  final bool alert;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.c,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    // ink2, not ink3 — with caps and tracking gone from the eyebrow, colour is
    // the emphasis that actually lands (ink3 is 3.69:1 on the dark ground and
    // reads as disabled next to a count badge).
    final labelColor = alert ? c.danger : c.ink2;
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          if (alert) ...[
            Icon(
              Icons.priority_high_rounded,
              size: UgamScale.px(context, 13),
              color: c.danger,
            ),
            const SizedBox(width: UgamSpacing.xs),
          ],
          // [UgamText.label], not [UgamSectionLabel]. The shared eyebrow still
          // uppercases onto `micro`, and every one of these categories is a
          // translated string: in Gujarati the caps do nothing, micro's 1.4
          // tracking splits conjuncts, and its 10px lands at 8.5 on a small
          // phone. Flagged for the owner of lib/design; switched here because
          // this screen is in the wave.
          //
          // Flexible: the label was an unbounded Row child sitting in front of
          // a count badge, so a long Gujarati category had nowhere to give.
          Flexible(
            child: Text(
              label,
              style: UgamText.label.copyWith(color: labelColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // THE app badge — the count no longer renders as a private
          // 999-radius lozenge while the identical count on Requests uses a
          // 6-radius chip.
          UgamReqChip(
            label: '$count',
            variant: alert ? UgamChipVariant.danger : UgamChipVariant.neutral,
          ),
        ],
      ),
    );
  }
}

// ─── Exception card ──────────────────────────────────────────────────────

class _ExceptionCard extends StatelessWidget {
  final String message;
  final String? passengerName;
  final String? groupLabel;
  final VoidCallback onTap;

  /// Whether [onTap] actually leads somewhere. False for a bus-level
  /// exception, which resolves to no passenger — the card then drops BOTH the
  /// tap and the chevron rather than advertising a destination and answering
  /// with a toast.
  final bool tappable;

  /// Explicit alert headline shown ABOVE the passenger name (e.g. the priority
  /// "could not get a lower berth" title). Null on ordinary exceptions, which
  /// lean on the passenger name + engine message instead.
  final String? title;

  /// When true the card is rendered in danger tones (a prominent ALERT) rather
  /// than the default warm attention card. Used for priority-no-lower-berth
  /// misses.
  final bool alert;

  /// Inline remedies for a waitlist/overflow item. Null on every other
  /// exception category (those are resolved elsewhere).
  final VoidCallback? onEdit;
  final VoidCallback? onHold;

  /// Approve stranger share on a half-double (sharedDoubleNeedsReview only).
  final VoidCallback? onApproveShare;
  final UgamColorSet c;

  const _ExceptionCard({
    required this.message,
    required this.passengerName,
    required this.groupLabel,
    required this.onTap,
    required this.tappable,
    required this.c,
    this.title,
    this.alert = false,
    this.onEdit,
    this.onHold,
    this.onApproveShare,
  });

  @override
  Widget build(BuildContext context) {
    // The attention colour drives the icon badge; the card surface itself is
    // toned by [UgamCard] (warm vs danger).
    //
    // `dangerFill` instead of a hand-mixed `danger.withValues(alpha: 0.14)` —
    // the token exists precisely so this alpha stops drifting per call site
    // (see [UgamColorSet.dangerFill]), and the hand-mixed one sat lighter than
    // the real token in Daylight, where dangerFill is an opaque tint rather
    // than 14% of the ink.
    final Color toneInk = alert ? c.danger : c.warm;
    final Color toneFill = alert ? c.dangerFill : c.warmFill;

    return UgamCard.plain(
      // UgamCard.plain accepts a null onTap and then skips the press
      // animation, so an unresolvable card reads as a flat note.
      onTap: tappable ? onTap : null,
      tone: alert ? UgamCardTone.danger : UgamCardTone.warm,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: UgamScale.px(context, 38),
            height: UgamScale.px(context, 38),
            decoration: BoxDecoration(
              color: toneFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              alert
                  ? Icons.report_problem_rounded
                  : Icons.error_outline_rounded,
              size: UgamScale.px(context, 18),
              color: toneInk,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: UgamText.titleS.copyWith(
                      color: alert ? c.danger : c.ink,
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                ],
                if (passengerName != null) ...[
                  Text(
                    passengerName!,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                ],
                Text(
                  message,
                  style: UgamText.body.copyWith(
                    color: (passengerName != null || title != null)
                        ? c.ink2
                        : c.ink,
                  ),
                ),
                if (groupLabel != null && groupLabel!.isNotEmpty) ...[
                  const SizedBox(height: UgamSpacing.sm),
                  // Same chip the Requests card uses for the same concept, so
                  // the group tag stops changing size between the two screens.
                  UgamReqChip(
                    label: tr(
                      'seating_exceptions.group_label',
                      namedArgs: {'label': groupLabel!},
                    ),
                    variant: UgamChipVariant.neutral,
                    leading: Icons.group_rounded,
                  ),
                ],
                // Card actions sit as compact buttons aligned to the trailing
                // edge, never full-bleed: a stack of edge-to-edge buttons under
                // every card is a web card-footer, and it made each exception
                // read as its own page rather than an item in a list. Labels
                // stay — "Approve share" and "Hold" are not actions an icon
                // alone can carry. Wrap so a third action or a long
                // translation folds to the next line instead of overflowing.
                if (onEdit != null ||
                    onHold != null ||
                    onApproveShare != null) ...[
                  const SizedBox(height: UgamSpacing.md),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: UgamSpacing.sm,
                      runSpacing: UgamSpacing.sm,
                      children: [
                        if (onHold != null)
                          UgamButton(
                            label: tr('seating_exceptions.action_hold'),
                            icon: Icons.pause_circle_outline_rounded,
                            kind: UgamButtonKind.neutral,
                            onPressed: onHold,
                          ),
                        if (onEdit != null)
                          UgamButton(
                            label: tr('seating_exceptions.action_edit'),
                            icon: Icons.edit_note_rounded,
                            kind: UgamButtonKind.tonal,
                            onPressed: onEdit,
                          ),
                        // Primary last: on a trailing-aligned action row the
                        // rightmost button is the one the thumb reaches first.
                        if (onApproveShare != null)
                          UgamButton(
                            label: tr(
                              'seating_exceptions.action_approve_share',
                            ),
                            icon: Icons.people_alt_rounded,
                            kind: UgamButtonKind.tonal,
                            onPressed: onApproveShare,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: UgamSpacing.sm),
            Icon(
              Icons.chevron_right_rounded,
              size: UgamScale.px(context, 20),
              color: c.ink3,
            ),
          ],
        ],
      ),
    );
  }
}
