import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../design/ugam.dart';
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
                  Text(greeting,
                      style: UgamText.body
                          .copyWith(color: c.ink2, fontSize: 13)),
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
                style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 26),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
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
