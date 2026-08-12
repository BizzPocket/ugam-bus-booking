import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_info.dart';
import '../controllers/auth_controller.dart';
import '../controllers/finance_controller.dart';
import '../controllers/theme_controller.dart';
import '../design/ugam.dart';
import '../utils/app_snackbar.dart';
import '../widgets/language_picker_sheet.dart';
import 'account_details_screen.dart';
import 'finance_screen.dart';
import 'notifications_settings_screen.dart';
import 'pickup_locations_screen.dart';
import 'whatsapp_settings_screen.dart';

/// ── Canonical settings-row geometry ────────────────────────────────────────
/// The settings cluster (this screen + Account Details, Notifications,
/// WhatsApp) was built across several passes and drifted: 38 vs 40 px icon
/// tiles, 18 vs 20 px glyphs, corner radius 11 vs 12 vs 14, and two different
/// row paddings. These four numbers are the agreed spec, and the same block is
/// copied at the top of `notifications_settings_screen.dart`. Change both
/// together, or promote them to a shared widget.
const double _rowIconBox = 40;
const double _rowIconGlyph = 20;
const double _rowIconRadius = 12;
const double _rowMinHeight = 64;

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
                    // Section eyebrows carry emphasis with WEIGHT + COLOUR, not
                    // with capitals: `.toUpperCase()` is a no-op in Gujarati
                    // and Hindi, so for most of this app's users the caps did
                    // nothing and a 3.5:1 `ink3` line was all that marked a
                    // section. `ink2` measures 7.2:1 and is the same ink
                    // UgamInput gives a field label, so eyebrows and form
                    // labels across the cluster now read as one system.
                    UgamSectionLabel(
                      tr('settings.account_section'),
                      color: c.ink2,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Obx(
                      () => _AccountCard(
                        phone: authCtrl.userPhone.value,
                        c: c,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamSectionLabel(tr('settings.appearance'), color: c.ink2),
                    const SizedBox(height: UgamSpacing.sm),
                    Obx(
                      () => _ThemeTriPicker(
                        mode: themeCtrl.themeMode.value,
                        onPick: themeCtrl.setMode,
                        c: c,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamSectionLabel(
                      tr('settings.security_section'),
                      color: c.ink2,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    _GroupCard(
                      children: [BiometricToggle(authCtrl: authCtrl)],
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamSectionLabel(tr('settings.title'), color: c.ink2),
                    const SizedBox(height: UgamSpacing.sm),
                    _GroupCard(
                      children: [
                        _SettingsRow(
                          c: c,
                          icon: Icons.person_outline_rounded,
                          iconTone: UgamStatVariant.neutral,
                          title: tr('settings.account_details_title'),
                          subtitle: tr('settings.account_details_subtitle'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AccountDetailsScreen(),
                            ),
                          ),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.notifications_none_rounded,
                          iconTone: UgamStatVariant.neutral,
                          title: tr('settings.notifications_title'),
                          subtitle: tr('settings.notifications_subtitle'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  const NotificationsSettingsScreen(),
                            ),
                          ),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.place_outlined,
                          iconTone: UgamStatVariant.neutral,
                          title: tr('pickup.settings_title'),
                          subtitle: tr('pickup.settings_subtitle'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PickupLocationsScreen(),
                            ),
                          ),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.chat_outlined,
                          iconTone: UgamStatVariant.neutral,
                          title: tr('settings.whatsapp_title'),
                          subtitle: tr('settings.whatsapp_subtitle'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WhatsAppSettingsScreen(),
                            ),
                          ),
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
                    // The destructive action is pushed away from the ordinary
                    // rows by a seam visibly wider than any section gap above
                    // it (26 vs 16), so log-out can't be caught by a thumb
                    // aiming at the last row of the list.
                    const SizedBox(height: UgamSpacing.huge),
                    _DangerRow(
                      c: c,
                      onLogout: () async {
                        final ok = await UgamDialog.confirm(
                          context,
                          title: tr('settings.logout'),
                          message: tr('settings.logout_confirm_message'),
                          confirmLabel: tr('settings.logout'),
                          // UgamDialog defaults this to the literal English
                          // 'Cancel', so every call site has to localise it.
                          cancelLabel: tr('app.action.cancel'),
                          destructive: true,
                        );
                        if (ok) authCtrl.logout();
                      },
                    ),
                    const SizedBox(height: UgamSpacing.huge),
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

/// A grouped list of settings rows sharing one card surface.
///
/// Was a bare `Container(decoration: BoxDecoration(color: cardElev, …))`, so
/// these groups sat flush with the page while the [UgamCard]s directly above
/// them floated. Composing with [UgamCard] means a group picks up the app's
/// elevation scale for free instead of opting out of it.
///
/// The [Material] is load-bearing: an [InkWell] paints its splash into the
/// nearest ancestor [Material], which without this is the Scaffold's — i.e.
/// *underneath* the card fill, so tapping a row produced no visible feedback
/// at all.
class _GroupCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    // The page Column lays out with CrossAxisAlignment.start, so claim width.
    return SizedBox(
      width: double.infinity,
      child: UgamCard.plain(
        elev: true,
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(UgamRadius.card),
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: children),
          ),
        ),
      ),
    );
  }
}

/// The one icon medallion every row in the settings cluster uses.
///
/// [UgamScale.px], not [UgamScale.tap]: the tile is decorative: the 44pt floor
/// belongs to the row wrapped around it, not to the glyph box.
class _RowIcon extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color foreground;

  const _RowIcon({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final box = UgamScale.px(context, _rowIconBox);
    return Container(
      width: box,
      height: box,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(_rowIconRadius),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: UgamScale.px(context, _rowIconGlyph),
        color: foreground,
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
      // Refetch when money moved since the last load. Settings is a tab, so its
      // State survives every visit — with a plain ensureLoaded() the headline
      // figure froze at whatever it was on first open and never tracked the
      // expenses/collections logged afterwards.
      _finance.refreshIfStale();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Obx(() {
      final loaded = _finance.loadedOnce.value;
      // A failed first load must NOT keep pretending to load: without this the
      // card sat on "Loading…" forever with no way to retry, which is what the
      // whole finance entry point looked like when the read failed.
      final failed = _finance.loadFailed.value && !loaded;
      final net = loaded ? _finance.lifetimeNet : 0.0;
      final profit = net >= 0;
      final netColor = failed
          ? c.danger
          : !loaded
              ? c.ink3
              : (net.round() == 0 ? c.ink : (profit ? c.good : c.danger));

      return UgamCard.plain(
        elev: true,
        // Retry in place when the load failed — tapping through to a report
        // that would only show its own error state helps nobody.
        onTap: failed
            ? _finance.reload
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FinanceScreen()),
                ),
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Row(
          children: [
            // Was a one-off 44/21/r13 medallion — the only one in the whole
            // cluster that missed the canonical 40/20/r12 spec.
            _RowIcon(
              icon: failed ? Icons.cloud_off_rounded : Icons.insights_rounded,
              background: failed ? c.dangerFill : c.accentFill,
              foreground: failed ? c.danger : c.accent,
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
                  if (failed)
                    Text(
                      tr('finance.card_failed'),
                      style: UgamText.titleS.copyWith(color: c.danger),
                    )
                  else if (!loaded)
                    Text(
                      tr('finance.card_loading'),
                      style: UgamText.titleS.copyWith(color: c.ink3),
                    )
                  else
                    Text(
                      // Was a hand-set 22. `numLg` (20) is the ladder step for
                      // an in-card figure; `numXl` (26) is the hero size and
                      // would out-shout the page title. numLg is already
                      // tabular, so the tabular() wrapper was a no-op too.
                      _fmtSignedInr(net),
                      style: UgamText.numLg.copyWith(color: netColor),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    failed
                        ? tr('finance.card_failed_hint')
                        : tr('finance.card_lifetime'),
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ],
              ),
            ),
            Icon(
              failed ? Icons.refresh_rounded : Icons.chevron_right_rounded,
              size: 20,
              color: c.ink3,
            ),
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
    final avatar = UgamScale.px(context, 48);
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        children: [
          Container(
            width: avatar,
            height: avatar,
            decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Obx(
              () => Text(
                authCtrl.initials.isNotEmpty ? authCtrl.initials : '👋',
                // `titleL` IS 22 — the hand-set size was already on the ladder,
                // just spelled as an override of the wrong step.
                style: UgamText.titleL.copyWith(color: c.onAccent),
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
                    // Was 17 — no such step. `titleM` (18) is the nearest and
                    // is what every other in-card heading already uses.
                    style: UgamText.titleM.copyWith(color: c.ink),
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
    return _GroupCard(
      children: [
        _AccountRow(
          c: c,
          icon: Icons.phone_rounded,
          iconTone: UgamStatVariant.neutral,
          label: tr('settings.phone_label'),
          value: phone,
        ),
      ],
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

    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: UgamScale.tap(context, _rowMinHeight),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        child: Row(
          children: [
            _RowIcon(icon: icon, background: iconBg, foreground: iconFg),
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
                          // `micro` IS 10 — the fontSize just restated the step.
                          // Weight/tracking stay as deliberate badge overrides.
                          style: UgamText.micro.copyWith(
                            color: c.ink2,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          value.isNotEmpty ? value : '—',
                          // `titleS` is the real 15px step (Sora, the numeral
                          // face). The old `bodyStrong` + fontSize:15 invented a
                          // step that does not exist on the ladder. Matches the
                          // locked phone field on the Account Details page.
                          style: UgamText.tabular(
                            UgamText.titleS.copyWith(color: c.ink),
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
    return UgamCard.plain(
      elev: true,
      radius: UgamRadius.input,
      padding: const EdgeInsets.all(4),
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
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.xs,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: active ? c.card : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          // Was a hand-rolled BoxShadow. The selected segment lifts off the
          // track using the app's own scale, so it tracks the theme.
          boxShadow: active ? UgamElevation.of(context).rest : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: UgamScale.px(context, 20),
              color: active ? c.accent : c.ink3,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              // Was `maxLines: 1, softWrap: false` + ellipsis. The three
              // Gujarati labels fit today, but the app allows a 1.3x
              // accessibility text scale, at which point they would clip —
              // wrapping grows the picker instead of hiding the word.
              maxLines: 2,
              textAlign: TextAlign.center,
              // `caption` is the 12px step; only the weight is an override.
              style: UgamText.caption.copyWith(
                color: active ? c.ink : c.ink2,
                fontWeight: FontWeight.w600,
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
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              _RowIcon(icon: icon, background: iconBg, foreground: iconFg),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Nothing in this row is clamped to one line, on purpose:
                    // the Gujarati and Hindi strings run ~30% past the English
                    // source and a settings row is label + value + chevron on
                    // one line, so the copy has to be free to wrap. The row
                    // grows; nothing hides behind an ellipsis.
                    Text(
                      title,
                      // `titleS` IS 15 — the override restated the step.
                      style: UgamText.titleS.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      // `caption` IS 12 — likewise redundant.
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hairline between two rows inside a [_GroupCard]. Inset so it starts where
/// the TEXT starts rather than under the icon medallion — that inset is what
/// makes a stack of rows read as one list instead of a sliced box. Mirrored in
/// `notifications_settings_screen.dart`.
class _Divider extends StatelessWidget {
  final UgamColorSet c;
  const _Divider({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: UgamSpacing.lg +
            UgamScale.px(context, _rowIconBox) +
            UgamSpacing.md,
        right: UgamSpacing.lg,
      ),
      child: Divider(height: 1, color: c.border),
    );
  }
}

/// Log out — the one destructive action on this screen.
///
/// It used to be a `cardElev` tile geometrically IDENTICAL to the five
/// navigation rows above it, separated by the same 16px seam, and it even
/// carried a chevron; the only thing marking it destructive was a red glyph.
/// It is now a danger-toned [UgamCard] (tinted fill + danger hairline) behind
/// a wider seam, with the chevron dropped — a chevron promises "this opens a
/// page", and this ends your session. The confirmation step was already in
/// place ([UgamDialog.confirm] with `destructive: true`) and is unchanged.
class _DangerRow extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onLogout;

  const _DangerRow({
    required this.c,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      tone: UgamCardTone.danger,
      padding: EdgeInsets.zero,
      onTap: onLogout,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              _RowIcon(
                icon: Icons.logout_rounded,
                // The `dangerFill` token, not a per-call-site alpha.
                background: c.dangerFill,
                foreground: c.danger,
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('settings.logout'),
                      style: UgamText.titleS.copyWith(color: c.danger),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('settings.logout_subtitle'),
                      // `ink2`, not `ink3`: on the tinted danger fill the
                      // tertiary ink drops under 3:1.
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Security-section toggle for biometric (fingerprint/face) login. Seeds its
/// switch from [AuthController.biometric] on init, clears the stored
/// credential when switched off, and re-authenticates with the account
/// password (via [AuthController.adminAuth]) before enrolling when switched
/// on. Exposed publicly so it is directly pumpable in widget tests.
class BiometricToggle extends StatefulWidget {
  const BiometricToggle({super.key, required this.authCtrl});
  final AuthController authCtrl;

  @override
  State<BiometricToggle> createState() => _BiometricToggleState();
}

class _BiometricToggleState extends State<BiometricToggle> {
  bool _available = false;
  bool _on = false;
  final _pw = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = widget.authCtrl.biometric;
    final avail = await b.isAvailable();
    final on = avail && await b.hasCredential(widget.authCtrl.userPhone.value);
    if (mounted) {
      setState(() {
        _available = avail;
        _on = on;
      });
    }
  }

  Future<void> _toggle(bool want) async {
    final b = widget.authCtrl.biometric;
    if (!want) {
      await b.clear();
      if (mounted) setState(() => _on = false);
      return;
    }
    final ok = await _promptPasswordAndEnroll();
    if (mounted && ok) setState(() => _on = true);
  }

  Future<bool> _promptPasswordAndEnroll() async {
    _pw.clear();
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: UgamInput(
          label: tr('login.password_label'),
          hint: tr('settings.biometric_enable_password_prompt'),
          controller: _pw,
          obscure: true,
          obscureToggle: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_pw.text),
            child: Text(tr('login.biometric_enroll_confirm')),
          ),
        ],
      ),
    );
    if (entered == null || entered.isEmpty) return false;
    try {
      final phone = widget.authCtrl.userPhone.value;
      await widget.authCtrl.adminAuth.signIn(phone: phone, password: entered);
      await widget.authCtrl.biometric.enroll(phone: phone, password: entered);
      return true;
    } on AuthException catch (_) {
      AppSnackBar.error(tr('login.password_incorrect'));
      return false;
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return _SecurityToggleRow(
      c: c,
      icon: Icons.fingerprint_rounded,
      title: tr('settings.biometric_title'),
      subtitle: _available
          ? tr('settings.biometric_subtitle')
          : tr('settings.biometric_unavailable'),
      value: _on,
      enabled: _available,
      onChanged: _toggle,
    );
  }
}

/// Toggle row for the Security section.
///
/// Deliberately IDENTICAL in geometry and behaviour to `_ToggleRow` in
/// `notifications_settings_screen.dart` — same 40/20/r12 medallion, same
/// padding, same [UgamSwitch], same whole-row tap target. The two remain
/// separate classes only because neither file may introduce a shared widget;
/// keep them in lockstep.
class _SecurityToggleRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _SecurityToggleRow({
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final on = value && enabled;

    return InkWell(
      // The whole row toggles, not just the ~50px switch — the nav rows on this
      // same screen have always been fully tappable.
      onTap: enabled ? () => onChanged(!value) : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              _RowIcon(
                icon: icon,
                background: c.card,
                foreground: enabled ? c.ink2 : c.ink3,
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
                        color: enabled ? c.ink : c.ink3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Was a raw Material Switch that set only the two ACTIVE colours,
              // so the off state fell back to Material's grey. UgamSwitch tints
              // all four, adds the haptic, guarantees the 44pt box and
              // announces the toggled state to a screen reader.
              UgamSwitch(
                value: on,
                onChanged: enabled ? onChanged : null,
                semanticLabel: title,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
