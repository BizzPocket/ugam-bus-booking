import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../utils/app_snackbar.dart';
import '../widgets/settings_scaffold.dart';

/// Settings → Payment. Stores the UPI / payee details and defaults used when
/// collecting money and stamping receipts (see money collection flow).
class PaymentSettingsScreen extends StatefulWidget {
  const PaymentSettingsScreen({super.key});

  @override
  State<PaymentSettingsScreen> createState() => _PaymentSettingsScreenState();
}

class _PaymentSettingsScreenState extends State<PaymentSettingsScreen> {
  final _authCtrl = Get.find<AuthController>();

  late final TextEditingController _upiId;
  late final TextEditingController _payeeName;
  late final TextEditingController _defaultAdvance;
  late final TextEditingController _receiptNote;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final admin = _authCtrl.currentAdmin.value;
    _upiId = TextEditingController(text: admin?.upiId ?? '');
    _payeeName = TextEditingController(text: admin?.payeeName ?? '');
    final adv = admin?.defaultAdvance ?? 0;
    _defaultAdvance =
        TextEditingController(text: adv > 0 ? _trimAmount(adv) : '');
    _receiptNote = TextEditingController(text: admin?.receiptNote ?? '');
  }

  static String _trimAmount(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _upiId.dispose();
    _payeeName.dispose();
    _defaultAdvance.dispose();
    _receiptNote.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final admin = _authCtrl.currentAdmin.value;
    if (admin == null) {
      AppSnackBar.error(tr('settings_pages.no_admin'));
      return;
    }
    final advText = _defaultAdvance.text.trim();
    final advance = advText.isEmpty ? 0.0 : (double.tryParse(advText) ?? -1);
    if (advance < 0) {
      AppSnackBar.error(tr('settings_pages.payment.advance_invalid'));
      return;
    }

    setState(() => _saving = true);
    try {
      await _authCtrl.saveAdmin(admin.copyWith(
        upiId: _upiId.text.trim(),
        payeeName: _payeeName.text.trim(),
        defaultAdvance: advance,
        receiptNote: _receiptNote.text.trim(),
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

    return SettingsScaffold(
      title: tr('settings.payment_title'),
      saving: _saving,
      saveLabel: tr('settings_pages.save'),
      onSave: _save,
      children: [
        UgamInput(
          label: tr('settings_pages.payment.upi_label'),
          hint: 'name@upi',
          controller: _upiId,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('settings_pages.payment.payee_label'),
          hint: tr('settings_pages.payment.payee_hint'),
          controller: _payeeName,
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('settings_pages.payment.advance_label'),
          hint: '0',
          controller: _defaultAdvance,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: Padding(
            padding: const EdgeInsets.only(left: 14, right: 6),
            child: Text(
              '₹',
              style: UgamText.bodyStrong.copyWith(color: c.ink2),
            ),
          ),
        ),
        const SizedBox(height: UgamSpacing.sm),
        Text(
          tr('settings_pages.payment.advance_hint'),
          style: UgamText.caption.copyWith(color: c.ink3),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('settings_pages.payment.receipt_note_label'),
          hint: tr('settings_pages.payment.receipt_note_hint'),
          controller: _receiptNote,
          maxLines: 3,
          minLines: 2,
          maxLength: 160,
          keyboardType: TextInputType.multiline,
        ),
      ],
    );
  }
}
