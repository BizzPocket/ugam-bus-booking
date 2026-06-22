import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../utils/app_snackbar.dart';
import '../widgets/settings_scaffold.dart';

/// Settings → WhatsApp. Edits the WhatsApp number customers are handed off
/// to (falls back to the login phone when blank) and a custom signature
/// appended to outgoing tour announcements.
class WhatsAppSettingsScreen extends StatefulWidget {
  const WhatsAppSettingsScreen({super.key});

  @override
  State<WhatsAppSettingsScreen> createState() => _WhatsAppSettingsScreenState();
}

class _WhatsAppSettingsScreenState extends State<WhatsAppSettingsScreen> {
  final _authCtrl = Get.find<AuthController>();

  late final TextEditingController _waNumber;
  late final TextEditingController _signature;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final admin = _authCtrl.currentAdmin.value;
    _waNumber = TextEditingController(text: admin?.whatsappNumber ?? '');
    _signature = TextEditingController(text: admin?.waHandoffTemplate ?? '');
  }

  @override
  void dispose() {
    _waNumber.dispose();
    _signature.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final admin = _authCtrl.currentAdmin.value;
    if (admin == null) {
      AppSnackBar.error(tr('settings_pages.no_admin'));
      return;
    }
    final wa = _waNumber.text.trim();
    if (wa.isNotEmpty && wa.length != 10) {
      AppSnackBar.error(tr('settings_pages.whatsapp.number_invalid'));
      return;
    }

    setState(() => _saving = true);
    try {
      await _authCtrl.saveAdmin(admin.copyWith(
        whatsappNumber: wa,
        waHandoffTemplate: _signature.text.trim(),
      ));
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
    final loginPhone = _authCtrl.userPhone.value;

    return SettingsScaffold(
      title: tr('settings.whatsapp_title'),
      saving: _saving,
      saveLabel: tr('settings_pages.save'),
      onSave: _save,
      children: [
        _SoftField(
          c: c,
          note: tr('settings_pages.whatsapp.number_hint',
              namedArgs: {'phone': loginPhone}),
          child: UgamPhoneInput(
            controller: _waNumber,
            label: tr('settings_pages.whatsapp.number_label'),
          ),
        ),
        const SizedBox(height: UgamSpacing.xl),
        _SoftField(
          c: c,
          note: tr('settings_pages.whatsapp.signature_note'),
          child: UgamInput(
            label: tr('settings_pages.whatsapp.signature_label'),
            hint: tr('settings_pages.whatsapp.signature_hint'),
            controller: _signature,
            maxLines: 4,
            minLines: 3,
            maxLength: 240,
            keyboardType: TextInputType.multiline,
          ),
        ),
      ],
    );
  }
}

/// A single settings field on its own soft surface — the labelled input on a
/// quiet [UgamColorSet.cardElev] card with the helper line tucked underneath,
/// matching the grouped-card look of the other settings sub-pages.
class _SoftField extends StatelessWidget {
  final UgamColorSet c;
  final String note;
  final Widget child;

  const _SoftField({
    required this.c,
    required this.note,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: UgamSpacing.md),
          Text(
            note,
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }
}
