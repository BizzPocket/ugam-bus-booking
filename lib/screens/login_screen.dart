import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../services/appwrite_service.dart';
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
                    'Tour Booking Agent',
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
                'Welcome\nback.',
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
                'Sign in with your phone number to continue planning extraordinary journeys.',
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
                'PHONE NUMBER',
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
                          hintText: 'Enter your phone number',
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
              const SizedBox(height: 28),
              // ── Continue button ──────────────────────────────
              Obx(() => SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: controller.isLoading.value
                          ? null
                          : controller.sendOtp,
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
                      child: controller.isLoading.value
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              'Continue',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  )),
              const SizedBox(height: 16),
              // ── Appwrite connection ping ─────────────────────
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => _sendPing(context),
                  icon: const Icon(Icons.network_check_rounded, size: 16),
                  label: Text(
                    'Send a Ping',
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
                  'By continuing, you agree to our Terms of Service\nand Privacy Policy.',
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
      final result = await AppwriteService().ping();
      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss loader
      AppSnackBar.success(
        'Connection to Appwrite successful.\n${result.length > 100 ? "${result.substring(0, 100)}..." : result}',
        title: 'Ping Success',
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      AppSnackBar.error(
        'Could not reach Appwrite:\n$e',
        title: 'Ping Failed',
      );
    }
  }
}
