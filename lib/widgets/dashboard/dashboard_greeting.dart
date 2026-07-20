import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/inbox_controller.dart';
import '../../design/ugam.dart';
import '../../screens/inbox_screen.dart';
import '../../screens/main_shell.dart';
import '../../utils/formatters.dart';

/// Time-of-day greeting + localized date pill, with the avatar that switches
/// to the Settings tab.
class DashboardGreeting extends StatelessWidget {
  final String name;
  final String initials;
  final UgamColorSet c;

  const DashboardGreeting({
    super.key,
    required this.name,
    required this.initials,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? tr('dashboard.greeting_morning')
        : hour < 17
            ? tr('dashboard.greeting_afternoon')
            : tr('dashboard.greeting_evening');
    final displayName = name.isNotEmpty ? name : tr('dashboard.welcome_fallback');
    final displayInitials = initials.isNotEmpty ? initials : '👋';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      greeting,
                      style: UgamText.body
                          .copyWith(color: c.ink2, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  UgamReqChip(
                    label: Formatters.formatDateShort(
                      DateTime.now(),
                      locale: context.locale.languageCode,
                    ),
                    variant: UgamChipVariant.neutral,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                displayName,
                style: UgamText.titleL.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        _MessagesButton(c: c),
        const SizedBox(width: UgamSpacing.sm),
        Semantics(
          label: tr('main_shell.tab_settings'),
          button: true,
          child: GestureDetector(
            // Settings is shell tab 4 — switch to it rather than pushing a
            // second, dock-nav-less copy of the same screen (which also left
            // its hand-rolled back button popping the whole shell).
            onTap: () => Get.find<ShellController>().switchTab(4),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                displayInitials,
                style: UgamText.bodyStrong
                    .copyWith(color: c.ink, fontSize: 15),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Home-header entry point to the WhatsApp inbox: a chat icon that carries an
/// unread badge. Reading [InboxController] here is what first instantiates it
/// (lazy + fenix), so its realtime subscription starts on the admin home.
class _MessagesButton extends StatelessWidget {
  final UgamColorSet c;

  const _MessagesButton({required this.c});

  @override
  Widget build(BuildContext context) {
    final inbox = Get.find<InboxController>();

    return Semantics(
      label: tr('inbox.title'),
      button: true,
      child: GestureDetector(
        onTap: () => Get.to(() => const InboxScreen()),
        behavior: HitTestBehavior.opaque,
        child: Obx(() {
          final unread = inbox.totalUnread.value;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.forum_rounded,
                  size: 20,
                  color: unread > 0 ? c.accent : c.ink2,
                ),
              ),
              if (unread > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                      border: Border.all(color: c.bg, width: 1.5),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: UgamText.tabular(
                        UgamText.micro.copyWith(
                          color: c.onAccent,
                          fontWeight: FontWeight.w800,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}
