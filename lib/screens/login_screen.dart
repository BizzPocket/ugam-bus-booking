import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../services/supabase_service.dart';
import '../utils/app_snackbar.dart';

class LoginScreen extends GetView<AuthController> {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: UgamSpacing.xxl),
              Row(
                children: [
                  Text(tr('splash.brand_name'),
                      style: UgamText.titleL.copyWith(color: c.ink)),
                  const Spacer(),
                  Text(
                    tr('login.tagline'),
                    style: UgamText.micro.copyWith(color: c.ink3),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.xxl + UgamSpacing.lg),
              Text(
                tr('login.hero'),
                style: UgamText.display.copyWith(color: c.ink),
              ),
              const SizedBox(height: UgamSpacing.lg),
              Text(
                tr('login.description'),
                style: UgamText.body
                    .copyWith(color: c.ink2, fontSize: 16, height: 1.55),
              ),
              const SizedBox(height: UgamSpacing.huge),
              UgamPhoneInput(
                controller: controller.phoneController,
                label: tr('login.phone_label'),
              ),
              const SizedBox(height: UgamSpacing.xl),
              Obx(() {
                if (!controller.awaitingAdminPassword.value) {
                  return const SizedBox.shrink();
                }
                final adminName = controller.pendingAdmin.value?.name ?? '';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UgamInput(
                      label: tr('login.password_label'),
                      hint: tr('login.password_hint'),
                      controller: controller.passwordController,
                      obscure: true,
                      autofocus: true,
                      inputFormatters: const [],
                      onSubmitted: (_) => controller.verifyAdminPassword(),
                    ),
                    if (adminName.isNotEmpty) ...[
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        tr('login.signing_in_as',
                            namedArgs: {'name': adminName}),
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                  ],
                );
              }),
              Obx(() {
                final showPasswordStep =
                    controller.awaitingAdminPassword.value;
                final loading = controller.isLoading.value;
                return UgamCTA(
                  label: showPasswordStep
                      ? tr('login.btn_sign_in')
                      : tr('app.action.continue_'),
                  loading: loading,
                  onPressed: showPasswordStep
                      ? controller.verifyAdminPassword
                      : controller.submitPhone,
                );
              }),
              Obx(() {
                if (!controller.awaitingAdminPassword.value) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: UgamSpacing.sm),
                  child: Center(
                    child: TextButton(
                      onPressed: controller.cancelAdminPassword,
                      child: Text(tr('login.btn_different_number')),
                    ),
                  ),
                );
              }),
              const SizedBox(height: UgamSpacing.lg),
              Center(
                child: TextButton(
                  onPressed: () => Get.toNamed('/admin-setup'),
                  child: Text(tr('login.btn_setup')),
                ),
              ),
              const SizedBox(height: UgamSpacing.xs),
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => _sendPing(context),
                  icon: const Icon(Icons.network_check_rounded, size: 16),
                  label: Text(tr('login.btn_ping')),
                ),
              ),
              const SizedBox(height: UgamSpacing.lg),
              Center(
                child: Text(
                  tr('login.terms'),
                  textAlign: TextAlign.center,
                  style: UgamText.caption
                      .copyWith(color: c.ink3, height: 1.5),
                ),
              ),
              const SizedBox(height: UgamSpacing.huge),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendPing(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final result = await SupabaseService.instance.ping();
      if (!context.mounted) return;
      Navigator.of(context).pop();
      AppSnackBar.success(
        tr('login.ping_success_msg', namedArgs: {
          'result':
              result.length > 100 ? '${result.substring(0, 100)}...' : result,
        }),
        title: tr('login.ping_success_title'),
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      AppSnackBar.error(
        tr('login.ping_failed_msg', namedArgs: {'error': e.toString()}),
        title: tr('login.ping_failed_title'),
      );
    }
  }
}

// Suppress unused-import lint for `services.dart` since other parts of
// this file may evolve to need its formatters. Kept local so tooling
// stays quiet while the surface settles.
// ignore: unused_element
void _kKeepServices() => FilteringTextInputFormatter.digitsOnly;
