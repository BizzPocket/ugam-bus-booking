import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../controllers/theme_controller.dart';
import '../design/ugam.dart';
import '../utils/app_dialogs.dart';
import '../widgets/language_picker_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authCtrl = Get.find<AuthController>();
    final themeCtrl = Get.find<ThemeController>();
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.md,
                UgamSpacing.sm,
                UgamSpacing.md,
                UgamSpacing.md,
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Get.back(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.arrow_back_rounded,
                          size: 19, color: c.ink),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Text(
                      tr('settings.profile_title'),
                      style: UgamText.titleL.copyWith(color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ProfileHero(authCtrl: authCtrl, c: c),
                    const SizedBox(height: UgamSpacing.xl),
                    Text('APPEARANCE',
                        style: UgamText.micro.copyWith(color: c.ink3)),
                    const SizedBox(height: UgamSpacing.sm),
                    Obx(() => _ThemeTriPicker(
                          mode: themeCtrl.themeMode.value,
                          onPick: themeCtrl.setMode,
                          c: c,
                        )),
                    const SizedBox(height: UgamSpacing.xl),
                    Text(tr('settings.title').toUpperCase(),
                        style: UgamText.micro.copyWith(color: c.ink3)),
                    const SizedBox(height: UgamSpacing.sm),
                    Container(
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        children: [
                          _SettingsRow(
                            c: c,
                            icon: Icons.person_outline_rounded,
                            iconTone: UgamStatVariant.accent,
                            title: tr('settings.account_details_title'),
                            subtitle: tr('settings.account_details_subtitle'),
                            onTap: () {},
                          ),
                          _Divider(c: c),
                          _SettingsRow(
                            c: c,
                            icon: Icons.chat_bubble_outline_rounded,
                            iconTone: UgamStatVariant.good,
                            title: tr('settings.whatsapp_title'),
                            subtitle: tr('settings.whatsapp_subtitle'),
                            onTap: () {},
                          ),
                          _Divider(c: c),
                          _SettingsRow(
                            c: c,
                            icon: Icons.attach_money_rounded,
                            iconTone: UgamStatVariant.warm,
                            title: tr('settings.payment_title'),
                            subtitle: tr('settings.payment_subtitle'),
                            onTap: () {},
                          ),
                          _Divider(c: c),
                          _SettingsRow(
                            c: c,
                            icon: Icons.notifications_none_rounded,
                            iconTone: UgamStatVariant.accent,
                            title: tr('settings.notifications_title'),
                            subtitle: tr('settings.notifications_subtitle'),
                            onTap: () {},
                          ),
                          _Divider(c: c),
                          _SettingsRow(
                            c: c,
                            icon: Icons.language_rounded,
                            iconTone: UgamStatVariant.neutral,
                            title: tr('settings.language'),
                            subtitle: tr('settings.language_subtitle'),
                            onTap: () => LanguagePickerSheet.show(context),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    _DangerRow(
                      c: c,
                      onLogout: () async {
                        final ok = await AppDialogs.confirm(
                          title: tr('settings.logout'),
                          message: tr('settings.logout_confirm_message'),
                          confirmText: tr('settings.logout'),
                          isDestructive: true,
                        );
                        if (ok) authCtrl.logout();
                      },
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    Center(
                      child: Column(
                        children: [
                          Text(
                            'Ugam Booking v1.0.0',
                            style: UgamText.caption.copyWith(color: c.ink3),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            tr('settings.footer_made_in'),
                            style: UgamText.caption.copyWith(color: c.ink3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  final AuthController authCtrl;
  final UgamColorSet c;
  const _ProfileHero({required this.authCtrl, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: c.accent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Obx(() => Text(
                  authCtrl.initials.isNotEmpty ? authCtrl.initials : '👋',
                  style: UgamText.titleM
                      .copyWith(color: c.onAccent, fontSize: 22),
                )),
          ),
          const SizedBox(width: UgamSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() => Text(
                      authCtrl.userName.value.isNotEmpty
                          ? authCtrl.userName.value
                          : tr('settings.welcome'),
                      style: UgamText.titleM
                          .copyWith(color: c.ink, fontSize: 17),
                    )),
                const SizedBox(height: 2),
                Obx(() => Text(
                      authCtrl.userPhone.value,
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink2),
                      ),
                    )),
                const SizedBox(height: 6),
                const UgamReqChip(label: 'ADMIN'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeTriPicker extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onPick;
  final UgamColorSet c;
  const _ThemeTriPicker({
    required this.mode,
    required this.onPick,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return UgamTabPills(
      currentIndex: ThemeMode.values.indexOf(mode),
      onChanged: (i) => onPick(ThemeMode.values[i]),
      items: const [
        UgamTabItem(label: 'System', icon: Icons.brightness_auto_rounded),
        UgamTabItem(label: 'Light', icon: Icons.light_mode_rounded),
        UgamTabItem(label: 'Dark', icon: Icons.dark_mode_rounded),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final UgamStatVariant iconTone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.c,
    required this.icon,
    required this.iconTone,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (iconBg, iconFg) = switch (iconTone) {
      UgamStatVariant.accent => (c.accentFill, c.accent),
      UgamStatVariant.good => (c.goodFill, c.good),
      UgamStatVariant.warm => (c.warmFill, c.warm),
      UgamStatVariant.neutral => (c.card, c.ink2),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md + 2,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: iconFg),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: UgamText.titleS
                          .copyWith(color: c.ink, fontSize: 15)),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      style: UgamText.caption
                          .copyWith(color: c.ink3, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final UgamColorSet c;
  const _Divider({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
      child: Divider(height: 1, color: c.border),
    );
  }
}

class _DangerRow extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onLogout;
  const _DangerRow({required this.c, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onLogout,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md + 2,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.logout_rounded, size: 18, color: c.danger),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tr('settings.logout'),
                      style: UgamText.titleS
                          .copyWith(color: c.danger, fontSize: 15)),
                  const SizedBox(height: 1),
                  Text(tr('settings.logout_subtitle'),
                      style: UgamText.caption
                          .copyWith(color: c.ink3, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
