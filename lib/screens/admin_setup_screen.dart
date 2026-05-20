import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../utils/app_snackbar.dart';

/// Post-Supabase: admin accounts are provisioned via the Supabase
/// dashboard, not from the app. This screen exists for legacy routes;
/// submit shows an "unavailable" toast and the form acts as a friendly
/// explainer.
class AdminSetupScreen extends StatefulWidget {
  const AdminSetupScreen({super.key});

  @override
  State<AdminSetupScreen> createState() => _AdminSetupScreenState();
}

class _AdminSetupScreenState extends State<AdminSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _whatsapp = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final bool _busy = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _whatsapp.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    AppSnackBar.error(
      tr('admin_setup.snackbar_unavailable_body'),
      title: tr('admin_setup.snackbar_unavailable_title'),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                UgamSpacing.sm,
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
                      tr('admin_setup.title'),
                      style: UgamText.titleM.copyWith(color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.xxl,
                    UgamSpacing.md,
                    UgamSpacing.xxl,
                    UgamSpacing.xxl,
                  ),
                  children: [
                    Text(
                      tr('admin_setup.heading'),
                      style: UgamText.titleL.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      tr('admin_setup.subtitle'),
                      style: UgamText.body
                          .copyWith(color: c.ink2, fontSize: 14, height: 1.5),
                    ),
                    const SizedBox(height: UgamSpacing.huge),
                    UgamInput(
                      label: tr('admin_setup.label_name'),
                      hint: tr('admin_setup.hint_name'),
                      controller: _name,
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamPhoneInput(
                      controller: _phone,
                      label: tr('admin_setup.label_phone'),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamPhoneInput(
                      controller: _whatsapp,
                      label: tr('admin_setup.label_whatsapp'),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamInput(
                      label: tr('admin_setup.label_password'),
                      hint: tr('admin_setup.hint_password'),
                      controller: _password,
                      obscure: _obscurePassword,
                      inputFormatters: const [],
                      suffix: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () =>
                            setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamInput(
                      label: tr('admin_setup.label_confirm_password'),
                      hint: tr('admin_setup.hint_confirm_password'),
                      controller: _confirm,
                      obscure: _obscurePassword,
                    ),
                  ],
                ),
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: tr('admin_setup.btn_create'),
                leadingIcon: Icons.check_rounded,
                loading: _busy,
                onPressed: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Suppress unused import lint; FilteringTextInputFormatter is part of
// the standard form toolkit even if not directly referenced here.
// ignore: unused_element
void _kKeepServices() => FilteringTextInputFormatter.digitsOnly;
