part of '../dashboard_screen.dart';

/// Explicit "no requests yet" state for the Recent requests section. Replaces
/// a silent `SizedBox.shrink()`: on a live tour with no bookings, a section
/// that simply is not there is indistinguishable from a section that failed to
/// load. The whole card is the primary action (→ the Requests tab), so it also
/// clears the 44 pt minimum by a wide margin.
class _RecentEmptyCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _RecentEmptyCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Decorative medallion inside an already-tappable card -> px, never tap.
    final tile = UgamScale.px(context, 40);
    return UgamCard.plain(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: tile,
            height: tile,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.inbox_rounded,
              size: UgamScale.px(context, 20),
              color: c.ink3,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('dashboard.recent_empty_title'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                // Two lines: the Gujarati copy runs past one line at 375.
                Text(
                  tr('dashboard.recent_empty_body'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}

/// Bottom-anchored closing block for the dashboard.
///
/// Everything live on this screen sits in the top half. When the agent has no
/// active tour left — a brand-new account, or a season that has finished — the
/// blocks above collapse and the rest of the page was blank. This takes that
/// space on purpose and puts the one door that is still useful (the archive of
/// finished tours) on the floor of the viewport, where the thumb already is.
/// It renders nothing while there IS active work: a quiet dashboard should not
/// grow footer furniture the moment it is busy.
class _DashboardTail extends StatelessWidget {
  final List<Tour> tours;
  final UgamColorSet c;

  const _DashboardTail({required this.tours, required this.c});

  @override
  Widget build(BuildContext context) {
    final hasActive = tours.any((t) => t.status != TourStatus.completed);
    final completed =
        tours.where((t) => t.status == TourStatus.completed).length;
    if (hasActive || completed == 0) return const SizedBox.shrink();

    return UgamButton(
      label: tr('dashboard.completed_tours', namedArgs: {'n': '$completed'}),
      icon: Icons.history_rounded,
      kind: UgamButtonKind.ghost,
      expand: true,
      onPressed: () => Get.find<ShellController>().onTabTapped(1), // Tours tab
    );
  }
}

/// Dashboard nudge card for unread WhatsApp customer messages. Neutral surface
/// (accent-rationing law — the accent CTA belongs to the top attention row);
/// the unread count rides a small TONAL accent pill — `accentFill` + `accent`
/// ink, never a solid copper blob. Opens the inbox by named route.
class _MessagesCard extends StatelessWidget {
  final int count;
  final UgamColorSet c;

  const _MessagesCard({required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    // Decorative chrome inside an already-tappable card (the whole card is the
    // target), so [UgamScale.px], never [tap] — nothing here is its own target.
    final tile = UgamScale.px(context, 40);
    final glyph = UgamScale.px(context, 20);
    return UgamCard.plain(
      // Named route, not an anonymous `Get.to(() => const InboxScreen())`:
      // push_service.dart:245 guards inbox re-entry with
      // `Get.currentRoute != AppRoutes.inbox`, and an anonymous route never
      // reports '/inbox', so a WhatsApp push arriving while the inbox was
      // open from here stacked a second identical inbox.
      onTap: () => Get.toNamed(AppRoutes.inbox),
      tone: UgamCardTone.warm,
      child: Row(
        children: [
          Container(
            width: tile,
            height: tile,
            decoration: BoxDecoration(
              color: c.warmFill,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(color: c.warm.withValues(alpha: 0.35)),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.forum_rounded, size: glyph, color: c.warm),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('inbox.title'),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                // `caption`, not `micro`: micro is the uppercase eyebrow step
                // (10 pt, 1.4 tracking) and this is a subtitle sentence. In
                // Gujarati ("3 વાંચ્યા વગર") the eyebrow tracking pulled the
                // conjuncts apart and the line read as spaced-out fragments.
                Text(
                  tr('inbox.card_unread', namedArgs: {'count': '$count'}),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          Container(
            constraints: BoxConstraints(minWidth: UgamScale.px(context, 26)),
            height: UgamScale.px(context, 26),
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Warm count matches the card tone — keeps champagne reserved for
              // the top attention CTA on this screen.
              color: c.warm,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            // `onAction` rather than a hardcoded `Colors.white`: the warm fill
            // is a DARK rose in Daylight (white ink, 5.4:1) but a LIGHT pink in
            // Midnight, where white-on-pink measured ~1.4:1 — the count was
            // effectively invisible in the app's primary theme. `onAction` is
            // the token that already resolves to "ink that survives a
            // maximum-contrast fill" and flips correctly in both themes.
            // Numerals also drop to `caption`: micro's eyebrow tracking was
            // spacing out a two-digit badge.
            child: Text(
              count > 99 ? '99+' : '$count',
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: c.onAction,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Icon(Icons.chevron_right_rounded, size: glyph, color: c.ink3),
        ],
      ),
    );
  }
}
