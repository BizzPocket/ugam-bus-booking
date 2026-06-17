import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../services/supabase_service.dart';
import '../utils/app_snackbar.dart';

class LoginScreen extends GetView<AuthController> {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // LoginScreen is usually the root, but it can be pushed (e.g. via the
    // hidden long-press on customer-home). When it sits on the stack, give
    // the user a visible way back so they are never stranded.
    final canPop = Navigator.canPop(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (canPop) ...[
                const SizedBox(height: UgamSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: UgamIconButton(
                    icon: Icons.close_rounded,
                    onTap: Get.back,
                    semanticLabel: tr('app.action.back'),
                  ),
                ),
              ],
              const SizedBox(height: UgamSpacing.xl),
              // Brand logo + a clean graphite headline block (no fake hero).
              const UgamLogo(size: 56),
              const SizedBox(height: UgamSpacing.xxl),
              Text(
                'UGAM',
                style: UgamText.display.copyWith(
                  color: c.ink,
                  fontSize: 52,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                tr('login.tagline'),
                style: UgamText.body.copyWith(
                  color: c.ink2,
                  fontSize: 15,
                  height: 1.45,
                ),
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
                        tr(
                          'login.signing_in_as',
                          namedArgs: {'name': adminName},
                        ),
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                  ],
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
              const SizedBox(height: UgamSpacing.lg),
              // The network-check 'Ping' is a developer affordance. It is no
              // longer a first-class button — it only surfaces in debug builds
              // and behind a long-press on the terms text, so production users
              // never see it.
              GestureDetector(
                onLongPress: kDebugMode ? () => _sendPing(context) : null,
                child: Text(
                  tr('login.terms'),
                  textAlign: TextAlign.center,
                  style: UgamText.caption.copyWith(color: c.ink3, height: 1.5),
                ),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: UgamSpacing.sm),
                Center(
                  child: TextButton.icon(
                    onPressed: () => _sendPing(context),
                    icon: const Icon(Icons.network_check_rounded, size: 14),
                    label: Text(
                      tr('login.btn_ping'),
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: UgamSpacing.huge),
            ],
          ),
        ),
      ),
      bottomNavigationBar: UgamStickyCTA(
        child: Obx(() {
          final showPasswordStep = controller.awaitingAdminPassword.value;
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
      ),
    );
  }

  Future<void> _sendPing(BuildContext context) async {
    final c = UgamColors.of(context);
    UgamDialog.show<void>(
      context,
      title: tr('login.ping_loading'),
      barrierDismissible: false,
      content: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('login.btn_ping'),
              style: UgamText.body.copyWith(color: c.ink2),
            ),
          ),
        ],
      ),
      actions: (_) => const [SizedBox.shrink()],
    );
    try {
      final result = await SupabaseService.instance.ping();
      if (!context.mounted) return;
      Navigator.of(context).pop();
      AppSnackBar.success(
        tr(
          'login.ping_success_msg',
          namedArgs: {
            'result': result.length > 100
                ? '${result.substring(0, 100)}...'
                : result,
          },
        ),
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
