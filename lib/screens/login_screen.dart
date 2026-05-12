import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../services/supabase_service.dart';
import '../utils/app_snackbar.dart';

class LoginScreen extends GetView<AuthController> {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // ── Brand header ─────────────────────────────────
              Row(
                children: [
                  Text(
                    'Ugam Booking',
                    style: GoogleFonts.inter(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    tr('login.tagline'),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: colorScheme.onSurfaceVariant,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // ── Divider ──────────────────────────────────────
              Container(
                height: 1,
                color: colorScheme.outline,
              ),
              const SizedBox(height: 48),
              // ── Hero text ────────────────────────────────────
              Text(
                tr('login.hero'),
                style: GoogleFonts.inter(
                  fontSize: 42,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                  letterSpacing: -1.5,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 20),
              // ── Description ──────────────────────────────────
              Text(
                tr('login.description'),
                style: GoogleFonts.inter(
                  fontSize: 17,
                  fontWeight: FontWeight.w400,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 48),
              // ── Phone label ──────────────────────────────────
              Text(
                tr('login.phone_label'),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              // ── Phone input row ──────────────────────────────
              Row(
                children: [
                  // Country code box
                  Container(
                    width: 90,
                    height: 54,
                    decoration: BoxDecoration(
                      color: isDark ? colorScheme.surfaceContainerHighest : Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colorScheme.outline),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('🇮🇳', style: TextStyle(fontSize: 18)),
                        const SizedBox(width: 4),
                        Text(
                          '+91',
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Phone input
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: TextField(
                        controller: controller.phoneController,
                        keyboardType: TextInputType.phone,
                        maxLength: 10,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: tr('login.phone_hint'),
                          hintStyle: GoogleFonts.inter(
                            fontSize: 15,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          filled: true,
                          fillColor: isDark ? colorScheme.surfaceContainerHighest : Colors.white,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide:
                                BorderSide(color: colorScheme.outline),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(
                                color: AppTheme.brand, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // ── Password section (shown only when phone matched an admin)
              Obx(() {
                if (!controller.awaitingAdminPassword.value) {
                  return const SizedBox.shrink();
                }
                final adminName = controller.pendingAdmin.value?.name ?? '';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('login.password_label'),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 54,
                      child: TextField(
                        controller: controller.passwordController,
                        obscureText: true,
                        autofocus: true,
                        onSubmitted: (_) => controller.verifyAdminPassword(),
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                        decoration: InputDecoration(
                          hintText: tr('login.password_hint'),
                          hintStyle: GoogleFonts.inter(
                            fontSize: 15,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? colorScheme.surfaceContainerHighest
                              : Colors.white,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide:
                                BorderSide(color: colorScheme.outline),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(
                                color: AppTheme.brand, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                    if (adminName.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr('login.signing_in_as', namedArgs: {'name': adminName}),
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                  ],
                );
              }),
              // ── Continue / Sign-in button ───────────────────
              Obx(() {
                final showPasswordStep =
                    controller.awaitingAdminPassword.value;
                final loading = controller.isLoading.value;
                return SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: loading
                        ? null
                        : (showPasswordStep
                            ? controller.verifyAdminPassword
                            : controller.submitPhone),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          AppTheme.brand.withValues(alpha: 0.6),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            showPasswordStep ? tr('login.btn_sign_in') : tr('app.action.continue_'),
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                  ),
                );
              }),
              // ── Cancel password step ─────────────────────────
              Obx(() {
                if (!controller.awaitingAdminPassword.value) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(
                    child: TextButton(
                      onPressed: controller.cancelAdminPassword,
                      child: Text(
                        tr('login.btn_different_number'),
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 16),
              // ── First-time admin setup link ──────────────────
              Center(
                child: TextButton(
                  onPressed: () => Get.toNamed('/admin-setup'),
                  child: Text(
                    tr('login.btn_setup'),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // ── Supabase connection ping ──────────────────────
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => _sendPing(context),
                  icon: const Icon(Icons.network_check_rounded, size: 16),
                  label: Text(
                    tr('login.btn_ping'),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ── Terms ────────────────────────────────────────
              Center(
                child: Text(
                  tr('login.terms'),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 48),
              // ── Bottom decorative labels ─────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'FIG. 001',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textMuted,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Text(
                    'AUTHENTICATION',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textMuted,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Text(
                    'SECURE',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textMuted,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
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
      Navigator.of(context).pop(); // dismiss loader
      AppSnackBar.success(
        tr('login.ping_success_msg', namedArgs: {'result': result.length > 100 ? '${result.substring(0, 100)}...' : result}),
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
