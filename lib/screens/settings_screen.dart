import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_info.dart';
import '../config/whatsapp_cloud_config.dart';
import '../content/legal_content.dart';
import '../controllers/auth_controller.dart';
import '../controllers/finance_controller.dart';
import '../controllers/theme_controller.dart';
import '../design/ugam.dart';
import '../utils/app_snackbar.dart';
import '../widgets/language_picker_sheet.dart';
import 'account_details_screen.dart';
import 'finance_screen.dart';
import 'legal_document_screen.dart';
import 'notifications_settings_screen.dart';
import 'pickup_locations_screen.dart';
import 'whatsapp_settings_screen.dart';

part 'settings/settings_cards.dart';
part 'settings/settings_rows.dart';

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
                          title: tr('settings.account_details_title'),
                          subtitle: tr('settings.account_details_subtitle'),
                          onTap: () => _push(context, const AccountDetailsScreen()),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.notifications_none_rounded,
                          title: tr('settings.notifications_title'),
                          subtitle: tr('settings.notifications_subtitle'),
                          onTap: () =>
                              _push(context, const NotificationsSettingsScreen()),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.place_outlined,
                          title: tr('pickup.settings_title'),
                          subtitle: tr('pickup.settings_subtitle'),
                          onTap: () => _push(context, const PickupLocationsScreen()),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.chat_outlined,
                          title: tr('settings.whatsapp_title'),
                          subtitle: tr('settings.whatsapp_subtitle'),
                          onTap: () => _push(context, const WhatsAppSettingsScreen()),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.language_rounded,
                          title: tr('settings.language'),
                          subtitle: tr('settings.language_subtitle'),
                          onTap: () => LanguagePickerSheet.show(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    // ── About & legal ── Same three documents (and the same
                    // strings) the customer "More" menu links to: the store
                    // listing's privacy/terms surface must be reachable from
                    // the signed-in admin app too, not only the rider side.
                    UgamSectionLabel(
                      tr('customer_more.section_about_legal'),
                      color: c.ink2,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    _GroupCard(
                      children: [
                        _SettingsRow(
                          c: c,
                          icon: Icons.info_outline_rounded,
                          title: tr('customer_more.about'),
                          subtitle: tr('customer_more.about_subtitle'),
                          onTap: () => _openDoc(context, LegalContent.about),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.shield_outlined,
                          title: tr('customer_more.privacy'),
                          subtitle: tr('customer_more.privacy_subtitle'),
                          onTap: () => _openDoc(context, LegalContent.privacy),
                        ),
                        _Divider(c: c),
                        _SettingsRow(
                          c: c,
                          icon: Icons.description_outlined,
                          title: tr('customer_more.terms'),
                          subtitle: tr('customer_more.terms_subtitle'),
                          onTap: () => _openDoc(context, LegalContent.terms),
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

  void _openDoc(BuildContext context, LegalDoc doc) =>
      _push(context, LegalDocumentScreen(doc: doc));

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
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
