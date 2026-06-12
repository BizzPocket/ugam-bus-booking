import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';

import '../utils/app_snackbar.dart';
import '../widgets/settings_scaffold.dart';

/// Settings → Account Details. Edits the admin's name and business info;
/// the login phone is shown read-only (it's the account identity and can't
/// be changed from the app).
class AccountDetailsScreen extends StatefulWidget {
  const AccountDetailsScreen({super.key});

  @override
  State<AccountDetailsScreen> createState() => _AccountDetailsScreenState();
}

class _AccountDetailsScreenState extends State<AccountDetailsScreen> {
  final _authCtrl = Get.find<AuthController>();

  late final TextEditingController _name;
  late final TextEditingController _businessName;
  late final TextEditingController _businessEmail;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final admin = _authCtrl.currentAdmin.value;
    _name = TextEditingController(
      text: admin?.name ?? _authCtrl.userName.value,
    );
    _businessName = TextEditingController(text: admin?.businessName ?? '');
    _businessEmail = TextEditingController(text: admin?.businessEmail ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _businessName.dispose();
    _businessEmail.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final admin = _authCtrl.currentAdmin.value;
    if (admin == null) {
      AppSnackBar.error(tr('settings_pages.no_admin'));
      return;
    }
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppSnackBar.error(tr('settings_pages.account.name_required'));
      return;
    }

    setState(() => _saving = true);
    try {
      await _authCtrl.saveAdmin(
        admin.copyWith(
          name: name,
          businessName: _businessName.text.trim(),
          businessEmail: _businessEmail.text.trim(),
        ),
      );
      AppSnackBar.success(tr('settings_pages.saved'));
      Get.back();
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return SettingsScaffold(
      title: tr('settings.account_details_title'),
      saving: _saving,
      saveLabel: tr('settings_pages.save'),
      onSave: _save,
      children: [
        UgamInput(
          label: tr('settings_pages.account.name_label'),
          hint: tr('settings_pages.account.name_hint'),
          controller: _name,
          keyboardType: TextInputType.name,
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('settings_pages.account.business_name_label'),
          hint: tr('settings_pages.account.business_name_hint'),
          controller: _businessName,
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('settings_pages.account.business_email_label'),
          hint: tr('settings_pages.account.business_email_hint'),
          controller: _businessEmail,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: UgamSpacing.lg),
        Text(
          tr('settings_pages.account.phone_label').toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md + 4,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 18, color: c.ink3),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Text(
                  '+91 ${_authCtrl.userPhone.value}',
                  style: UgamText.tabular(
                    UgamText.bodyStrong.copyWith(color: c.ink2),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.sm),
        Text(
          tr('settings_pages.account.phone_hint'),
          style: UgamText.caption.copyWith(color: c.ink3),
        ),
      ],
    );
  }
}
