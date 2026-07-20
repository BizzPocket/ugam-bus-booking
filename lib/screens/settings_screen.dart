import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../config/app_info.dart';
import '../controllers/auth_controller.dart';
import '../controllers/finance_controller.dart';
import '../controllers/theme_controller.dart';
import '../design/ugam.dart';
import '../routes/app_routes.dart';
import '../widgets/language_picker_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authCtrl = Get.find<AuthController>();
    final themeCtrl = Get.find<ThemeController>();
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Settings is shell tab 4 and normally cannot pop, so the back
            // affordance is hidden in tab mode. It only appears (and acts)
            // when a future caller actually pushes this screen.
            UgamAppBar(
              title: tr('settings.profile_title'),
              showBack: Navigator.canPop(context),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.dockClearance,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ProfileHero(authCtrl: authCtrl, c: c),
                    const SizedBox(height: UgamSpacing.md),
                    _FinanceCard(c: c),
                    const SizedBox(height: UgamSpacing.xl),
                    Text(
                      tr('settings.account_section').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Obx(
                      () => _AccountCard(
                        phone: authCtrl.userPhone.value,
                        c: c,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    Text(
                      tr('settings.appearance').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Obx(
                      () => _ThemeTriPicker(
                        mode: themeCtrl.themeMode.value,
                        onPick: themeCtrl.setMode,
                        c: c,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    Text(
                      tr('settings.title').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Container(
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        borderRadius: BorderRadius.circular(UgamRadius.card),
                      ),
                      child: Column(
                        children: [
                          _SettingsRow(
                            c: c,
                            icon: Icons.person_outline_rounded,
                            iconTone: UgamStatVariant.neutral,
                            title: tr('settings.account_details_title'),
                            subtitle: tr('settings.account_details_subtitle'),
                            onTap: () =>
                                Get.toNamed(AppRoutes.accountDetails),
                          ),
                          _Divider(c: c),
                          _SettingsRow(
                            c: c,
                            icon: Icons.notifications_none_rounded,
                            iconTone: UgamStatVariant.neutral,
                            title: tr('settings.notifications_title'),
                            subtitle: tr('settings.notifications_subtitle'),
                            onTap: () =>
                                Get.toNamed(AppRoutes.notificationsSettings),
                          ),
                          _Divider(c: c),
                          _SettingsRow(
                            c: c,
                            icon: Icons.place_outlined,
                            iconTone: UgamStatVariant.neutral,
                            title: tr('pickup.settings_title'),
                            subtitle: tr('pickup.settings_subtitle'),
                            onTap: () =>
                                Get.toNamed(AppRoutes.pickupLocations),
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
                        final ok = await UgamDialog.confirm(
                          context,
                          title: tr('settings.logout'),
                          message: tr('settings.logout_confirm_message'),
                          confirmLabel: tr('settings.logout'),
                          destructive: true,
                        );
                        if (ok) authCtrl.logout();
                      },
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    Center(
                      child: Column(
                        children: [
                          Text(
                            tr(
                              'settings.footer_version',
                              namedArgs: {'version': AppInfo.version},
                            ),
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

String _fmtSignedInr(num v) {
  String grp(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${parts.join(',')},$last3';
  }

  final r = v.round();
  if (r == 0) return '₹0';
  return r > 0 ? '+₹${grp(r)}' : '−₹${grp(r.abs())}';
}

/// Prominent Profit & Loss entry inside Settings. Shows the lifetime realised
/// net across all completed tours and opens the full [FinanceScreen] report.
/// This is the one place the cross-tour P&L surfaces in the main flow, so it
/// leads the settings body rather than hiding in the list below.
class _FinanceCard extends StatefulWidget {
  final UgamColorSet c;
  const _FinanceCard({required this.c});

  @override
  State<_FinanceCard> createState() => _FinanceCardState();
}

class _FinanceCardState extends State<_FinanceCard> {
  FinanceController get _finance => Get.find<FinanceController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _finance.ensureLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Obx(() {
      final loaded = _finance.loadedOnce.value;
      final net = loaded ? _finance.lifetimeNet : 0.0;
      final profit = net >= 0;
      final netColor = !loaded
          ? c.ink3
          : (net.round() == 0 ? c.ink : (profit ? c.good : c.danger));

      return UgamCard.plain(
        elev: true,
        onTap: () => Get.toNamed(AppRoutes.finance),
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(13),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.insights_rounded, size: 21, color: c.accent),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('finance.card_eyebrow'),
                    style: UgamText.micro.copyWith(color: c.ink3),
                  ),
                  const SizedBox(height: 3),
                  if (!loaded)
                    Text(
                      tr('finance.card_loading'),
                      style: UgamText.titleS.copyWith(color: c.ink3),
                    )
                  else
                    Text(
                      _fmtSignedInr(net),
                      style: UgamText.tabular(
                        UgamText.numLg.copyWith(color: netColor, fontSize: 22),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    tr('finance.card_lifetime'),
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
      );
    });
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
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Obx(
              () => Text(
                authCtrl.initials.isNotEmpty ? authCtrl.initials : '👋',
                style: UgamText.titleM.copyWith(
                  color: c.onAccent,
                  fontSize: 22,
                ),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => Text(
                    authCtrl.userName.value.isNotEmpty
                        ? authCtrl.userName.value
                        : tr('settings.welcome'),
                    style: UgamText.titleM.copyWith(color: c.ink, fontSize: 17),
                  ),
                ),
                const SizedBox(height: 6),
                UgamReqChip(label: tr('settings.admin_badge')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final String phone;
  final UgamColorSet c;
  const _AccountCard({
    required this.phone,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: _AccountRow(
        c: c,
        icon: Icons.phone_rounded,
        iconTone: UgamStatVariant.neutral,
        label: tr('settings.phone_label'),
        value: phone,
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final UgamStatVariant iconTone;
  final String label;
  final String value;

  const _AccountRow({
    required this.c,
    required this.icon,
    required this.iconTone,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final (iconBg, iconFg) = switch (iconTone) {
      UgamStatVariant.accent => (c.accentFill, c.accent),
      UgamStatVariant.good => (c.goodFill, c.good),
      UgamStatVariant.warm => (c.warmFill, c.warm),
      UgamStatVariant.neutral => (c.card, c.ink2),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md + 4,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: iconFg),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: UgamText.caption.copyWith(
                    color: c.ink2,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Country-code badge. Uses the darker base `card` against
                    // the `cardElev` card so the pill actually reads — the old
                    // neutral chip was `cardElev` on `cardElev` (invisible).
                    // No border: the darker fill alone separates it (soft-card
                    // style — depth from fill, not strokes).
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '+91',
                        style: UgamText.micro.copyWith(
                          color: c.ink2,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        value.isNotEmpty ? value : '—',
                        style: UgamText.tabular(
                          UgamText.bodyStrong.copyWith(
                            color: c.ink,
                            fontSize: 15,
                          ),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
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

  // Each segment: (mode, icon, label key). Order matches the visible row.
  static const _options = <(ThemeMode, IconData, String)>[
    (ThemeMode.system, Icons.brightness_auto_rounded, 'settings.theme_system'),
    (ThemeMode.light, Icons.light_mode_rounded, 'settings.theme_light'),
    (ThemeMode.dark, Icons.dark_mode_rounded, 'settings.theme_dark'),
  ];

  @override
  Widget build(BuildContext context) {
    // Same segmented-pill idiom as UgamTabPills, but tailored for the theme
    // choice: a stacked icon-over-label cell with a clearer selected state
    // (filled card + soft shadow + accent icon). Kept local so the shared
    // pill component used across the app is untouched.
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          for (final (m, icon, key) in _options)
            Expanded(
              child: _ThemeSegment(
                c: c,
                icon: icon,
                label: tr(key),
                active: mode == m,
                onTap: () => onPick(m),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ThemeSegment({
    required this.c,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
        decoration: BoxDecoration(
          color: active ? c.card : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          boxShadow: active
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: active ? c.accent : c.ink3),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: UgamText.bodyStrong.copyWith(
                color: active ? c.ink : c.ink2,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
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
      borderRadius: BorderRadius.circular(UgamRadius.card),
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
                borderRadius: BorderRadius.circular(11),
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
                  Text(
                    title,
                    style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: UgamText.caption.copyWith(
                      color: c.ink3,
                      fontSize: 12,
                    ),
                  ),
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

  const _DangerRow({
    required this.c,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dangerTile(
          icon: Icons.logout_rounded,
          title: tr('settings.logout'),
          subtitle: tr('settings.logout_subtitle'),
          onTap: onLogout,
        ),
      ],
    );
  }

  Widget _dangerTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md + 2,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: c.danger),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: UgamText.titleS.copyWith(
                      color: c.danger,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: UgamText.caption.copyWith(
                      color: c.ink3,
                      fontSize: 12,
                    ),
                  ),
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
