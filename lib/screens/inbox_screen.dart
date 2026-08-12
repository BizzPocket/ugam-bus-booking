import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/inbox_controller.dart';
import '../design/ugam.dart';
import '../models/wa_conversation.dart';
import '../routes/app_routes.dart';
import 'conversation_screen.dart';

/// WhatsApp inbox — the two-way conversation list.
///
/// One row per customer thread, ordered most-recent-first by the controller
/// (which mirrors `wa_conversations.last_message_at desc`). Each row shows the
/// customer name, the last message preview, a relative time and an unread
/// count pill. Tapping opens the [ConversationScreen], which owns marking the
/// thread read (see the note on that screen — doing it here missed every other
/// way into a thread and left the badge set for messages that arrived while the
/// thread was already open).
///
/// Chrome comes entirely from the Ugam system: [UgamScaffold] frame,
/// [UgamAppBar] header, [UgamPersonRow] rows, [UgamEmpty] empty state and
/// [UgamSkeleton] load placeholders — nothing hand-rolled.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<InboxController>();
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Shell tab in normal use (cannot pop); the back affordance only
            // shows when a future caller actually pushes the inbox.
            Obx(() {
              final unread = ctrl.totalUnread.value;
              return UgamAppBar(
                title: tr('inbox.title'),
                // The header carried a bare title over an empty band. The
                // across-all-threads unread count is the one number an agent
                // opens this screen to see, so it earns the subtitle slot.
                subtitle: unread > 0
                    ? tr('inbox.card_unread', namedArgs: {'count': '$unread'})
                    : null,
                showBack: Navigator.canPop(context),
              );
            }),
            Expanded(
              child: Obx(() {
                // First load, nothing cached yet → shimmer rows rather than a
                // spinner (the app reserves spinners for pull-refresh / submit).
                if (ctrl.loading.value && ctrl.conversations.isEmpty) {
                  return const _InboxSkeletonList();
                }

                final conversations = ctrl.conversations;
                if (conversations.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.forum_outlined,
                    title: tr('inbox.empty_title'),
                    body: tr('inbox.empty_subtitle'),
                    // An empty inbox has exactly one useful action: confirm the
                    // WhatsApp number is actually connected. Without it this
                    // state is a dead end that cannot tell "no one has written"
                    // from "the webhook was never wired up".
                    cta: UgamButton(
                      label: tr('inbox.empty_cta'),
                      icon: Icons.settings_outlined,
                      kind: UgamButtonKind.neutral,
                      onPressed: () => Get.toNamed(AppRoutes.whatsappSettings),
                    ),
                  );
                }

                return ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  // NOT `dockClearance`. The inbox is a root-level pushed route
                  // (`AppRoutes.inbox`), so it covers `MainShell` and its dock
                  // entirely — reserving 140px here was a screen-height of dead
                  // space under the last thread.
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xxl,
                  ),
                  itemCount: conversations.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: UgamSpacing.xs),
                  itemBuilder: (_, i) {
                    final convo = conversations[i];
                    return _ConversationTile(
                      conversation: convo,
                      c: c,
                      onTap: () =>
                          Get.to(() => ConversationScreen(conversation: convo)),
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// One inbox row: customer name + one-line preview + relative time + unread
/// pill. Built on the canonical [UgamPersonRow] so the density and tap target
/// match the rest of the app's list rows.
class _ConversationTile extends StatelessWidget {
  final WaConversation conversation;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    required this.c,
    required this.onTap,
  });

  /// Locale-aware relative marker: clock time for today, short date otherwise.
  /// Uses [MaterialLocalizations] so it needs no translation keys and follows
  /// the device locale.
  String _relativeTime(BuildContext context, DateTime dt) {
    final ml = MaterialLocalizations.of(context);
    final local = dt.toLocal();
    final now = DateTime.now();
    final sameDay =
        now.year == local.year &&
        now.month == local.month &&
        now.day == local.day;
    if (sameDay) {
      return ml.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    }
    return ml.formatShortDate(local);
  }

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName.trim().isEmpty
        ? tr('inbox.unknown')
        : conversation.displayName;
    final preview = conversation.lastMessagePreview?.trim();
    final hasUnread = conversation.hasUnread;

    return UgamPersonRow(
      name: name,
      subtitle: (preview == null || preview.isEmpty) ? null : preview,
      onTap: onTap,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _relativeTime(context, conversation.lastMessageAt),
            // Meta text, so NOT the accent: tokens.dart reserves amber for
            // "this is yours" and explicitly rules out subtitle text. Unread
            // is carried by weight + full-strength ink, and by the pill below.
            style: UgamText.tabular(
              UgamText.caption.copyWith(
                color: hasUnread ? c.ink : c.ink3,
                fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            maxLines: 1,
          ),
          if (hasUnread) ...[
            const SizedBox(height: UgamSpacing.xs + 2),
            _UnreadPill(count: conversation.unreadCount, c: c),
          ],
        ],
      ),
    );
  }
}

/// Tonal count pill for a thread's unread messages.
///
/// `accentFill` + `accent` ink, never a solid copper disc: the accent-rationing
/// law allows at most one solid accent fill in a screen's content area, and an
/// inbox can show a dozen of these at once. Matches the dashboard's messages
/// card, which already resolved this the same way.
class _UnreadPill extends StatelessWidget {
  final int count;
  final UgamColorSet c;

  const _UnreadPill({required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: tr('inbox.card_unread', namedArgs: {'count': '$count'}),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 22),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.sm,
          vertical: UgamSpacing.badgeV,
        ),
        decoration: BoxDecoration(
          color: c.accentFill,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: c.accent.withValues(alpha: 0.28)),
        ),
        alignment: Alignment.center,
        // `caption`, not `micro`: micro is the uppercase-eyebrow step and its
        // 1.4 tracking visibly spaces out a two-digit badge.
        child: Text(
          count > 99 ? '99+' : '$count',
          style: UgamText.tabular(
            UgamText.caption.copyWith(
              color: c.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shimmer placeholder list shown on first load.
///
/// Shaped like the row it stands in for — avatar disc, name line, preview line,
/// trailing time — rather than one flat 64px slab. A placeholder that does not
/// match the final layout still makes the content jump when it lands, which is
/// the exact tell a skeleton exists to remove.
class _InboxSkeletonList extends StatelessWidget {
  const _InboxSkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xxl,
      ),
      itemCount: 8,
      separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.xs),
      itemBuilder: (_, i) => _InboxSkeletonRow(seed: i),
    );
  }
}

class _InboxSkeletonRow extends StatelessWidget {
  final int seed;

  const _InboxSkeletonRow({required this.seed});

  @override
  Widget build(BuildContext context) {
    // Decorative geometry — [UgamScale.px], never [tap]: nothing here is a
    // target. Mirrors UgamPersonRow's 36pt avatar and 60pt min row height.
    final avatar = UgamScale.px(context, 36);
    // Varied name widths so eight identical bars don't read as a table.
    final nameWidth = UgamScale.px(context, seed.isEven ? 132 : 104);

    return Container(
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      child: Row(
        children: [
          UgamSkeleton(width: avatar, height: avatar, radius: avatar / 2),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                UgamSkeleton.text(width: nameWidth),
                const SizedBox(height: UgamSpacing.sm),
                const UgamSkeleton(height: 11, radius: 4),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamSkeleton(
            width: UgamScale.px(context, 38),
            height: 11,
            radius: 4,
          ),
        ],
      ),
    );
  }
}
