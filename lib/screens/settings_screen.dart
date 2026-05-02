import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../utils/app_dialogs.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authCtrl = Get.find<AuthController>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Profile',
              style: GoogleFonts.inter(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),

            // Profile Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderLight),
                boxShadow: AppTheme.cardShadow,
              ),
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: AppTheme.brand,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'ZS',
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Name + Phone + Badge
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Obx(() => Text(
                              authCtrl.userName.value,
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            )),
                        const SizedBox(height: 2),
                        Obx(() => Text(
                              authCtrl.userPhone.value,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: const Color(0xFF475569),
                              ),
                            )),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.brandLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'ADMIN',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                              color: AppTheme.brand,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Pencil icon
                  Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: AppTheme.textMuted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Stats Row
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    value: '12',
                    label: 'Tours',
                    valueColor: AppTheme.brand,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatCard(
                    value: '248',
                    label: 'Passengers',
                    valueColor: const Color(0xFFF59E0B),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatCard(
                    value: '\u20B93.6L',
                    label: 'Revenue',
                    valueColor: const Color(0xFF059669),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Settings Label
            Text(
              'Settings',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 12),

            // Settings List
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.person_outline_rounded,
                    iconBgColor: AppTheme.brandLight,
                    iconColor: AppTheme.brand,
                    title: 'Account Details',
                    subtitle: 'Name, phone, business info',
                    onTap: () {},
                  ),
                  const Divider(height: 1, color: AppTheme.borderLight),
                  _SettingsRow(
                    icon: Icons.chat_bubble_outline_rounded,
                    iconBgColor: AppTheme.successLight,
                    iconColor: AppTheme.success,
                    title: 'WhatsApp Settings',
                    subtitle: 'Broadcast, templates, auto-reply',
                    onTap: () {},
                  ),
                  const Divider(height: 1, color: AppTheme.borderLight),
                  _SettingsRow(
                    icon: Icons.attach_money_rounded,
                    iconBgColor: AppTheme.warningLight,
                    iconColor: AppTheme.warning,
                    title: 'Payment Settings',
                    subtitle: 'Cash collection, receipts',
                    onTap: () {},
                  ),
                  const Divider(height: 1, color: AppTheme.borderLight),
                  _SettingsRow(
                    icon: Icons.notifications_none_rounded,
                    iconBgColor: AppTheme.infoLight,
                    iconColor: AppTheme.info,
                    title: 'Notifications',
                    subtitle: 'Push, WhatsApp alerts',
                    onTap: () {},
                  ),
                  const Divider(height: 1, color: AppTheme.borderLight),
                  _SettingsRow(
                    icon: Icons.logout_rounded,
                    iconBgColor: AppTheme.dangerLight,
                    iconColor: AppTheme.danger,
                    title: 'Log Out',
                    titleColor: AppTheme.danger,
                    subtitle: 'Sign out of your account',
                    showChevron: false,
                    onTap: () async {
                      final confirmed = await AppDialogs.confirm(
                        title: 'Log Out',
                        message: 'Are you sure you want to sign out of your account?',
                        confirmText: 'Log Out',
                        isDestructive: true,
                      );
                      if (confirmed) authCtrl.logout();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // App Info Footer
            Center(
              child: Column(
                children: [
                  Text(
                    'Ugam Booking v1.0.0',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Made with \u2665 in Gujarat',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color valueColor;

  const _StatCard({
    required this.value,
    required this.label,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final Color iconBgColor;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String subtitle;
  final bool showChevron;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.icon,
    required this.iconBgColor,
    required this.iconColor,
    required this.title,
    this.titleColor,
    required this.subtitle,
    this.showChevron = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: titleColor ?? AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (showChevron)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppTheme.textMuted,
              ),
          ],
        ),
      ),
    );
  }
}
