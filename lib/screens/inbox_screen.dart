import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/inbox_controller.dart';
import '../design/ugam.dart';
import '../models/wa_conversation.dart';
import 'conversation_screen.dart';

/// WhatsApp inbox — the two-way conversation list.
///
/// One row per customer thread, ordered most-recent-first by the controller
/// (which mirrors `wa_conversations.last_message_at desc`). Each row shows the
/// customer name, the last message preview, a relative time and an unread
/// count pill. Tapping marks the thread read and opens the [ConversationScreen].
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
            UgamAppBar(
              title: tr('inbox.title'),
              showBack: Navigator.canPop(context),
            ),
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
                  );
                }

                return ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.dockClearance,
                  ),
                  itemCount: conversations.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: UgamSpacing.xs),
                  itemBuilder: (_, i) {
                    final convo = conversations[i];
                    return _ConversationTile(
                      conversation: convo,
                      c: c,
                      onTap: () {
                        // Mark read first so the badge clears immediately, then
                        // open the thread.
                        ctrl.markRead(convo.id);
                        Get.to(
                          () => ConversationScreen(conversation: convo),
                        );
                      },
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
            style: UgamText.micro.copyWith(
              color: hasUnread ? c.accent : c.ink3,
              fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          if (hasUnread) ...[
            const SizedBox(height: 6),
            _UnreadPill(count: conversation.unreadCount, c: c),
          ],
        ],
      ),
    );
  }
}

/// Small accent count pill for a thread's unread messages.
class _UnreadPill extends StatelessWidget {
  final int count;
  final UgamColorSet c;

  const _UnreadPill({required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: tr('inbox.new_label'),
      child: Container(
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        alignment: Alignment.center,
        child: Text(
          count > 99 ? '99+' : '$count',
          style: UgamText.tabular(
            UgamText.micro.copyWith(
              color: c.onAccent,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shimmer placeholder list shown on first load.
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
        UgamSpacing.dockClearance,
      ),
      itemCount: 8,
      separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.xs),
      itemBuilder: (_, _) => const Padding(
        padding: EdgeInsets.symmetric(vertical: UgamSpacing.sm),
        child: UgamSkeleton.row(),
      ),
    );
  }
}
