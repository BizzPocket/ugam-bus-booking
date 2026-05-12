import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../controllers/theme_controller.dart';
import '../utils/app_dialogs.dart';
import '../widgets/language_picker_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authCtrl = Get.find<AuthController>();
    final themeCtrl = Get.find<ThemeController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final cardColor = isDark ? AppTheme.cardDark : Colors.white;
    final borderColor = isDark ? AppTheme.borderDark : AppTheme.borderLight;
    final primaryText = theme.colorScheme.onSurface;
    final mutedText = isDark ? const Color(0xFF94A3B8) : AppTheme.textMuted;
    final secondaryText = isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: primaryText),
          onPressed: () => Get.back(),
        ),
        title: Text(
          'Profile',
          style: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: primaryText,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Profile Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                  boxShadow: isDark ? null : AppTheme.cardShadow,
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
                      child: Obx(() => Text(
                            authCtrl.initials.isNotEmpty
                                ? authCtrl.initials
                                : '👋',
                            style: GoogleFonts.inter(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          )),
                    ),
                    const SizedBox(width: 16),
                    // Name + Phone + Badge
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Obx(() => Text(
                                authCtrl.userName.value.isNotEmpty
                                    ? authCtrl.userName.value
                                    : 'Welcome',
                                style: GoogleFonts.inter(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: primaryText,
                                ),
                              )),
                          const SizedBox(height: 2),
                          Obx(() => Text(
                                authCtrl.userPhone.value,
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  color: secondaryText,
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
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Appearance Label
              Text(
                'Appearance',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: primaryText,
                ),
              ),
              const SizedBox(height: 12),

              // Theme toggle row
              Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: Obx(() {
                  final dark = themeCtrl.isDarkMode.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: dark
                                ? const Color(0xFF1E293B)
                                : AppTheme.warningLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            dark
                                ? Icons.dark_mode_rounded
                                : Icons.light_mode_rounded,
                            size: 18,
                            color: dark
                                ? const Color(0xFFFBBF24)
                                : AppTheme.warning,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Dark Mode',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: primaryText,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                dark ? 'Dark theme is on' : 'Light theme is on',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: mutedText,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: dark,
                          activeThumbColor: AppTheme.brand,
                          onChanged: (_) => themeCtrl.toggleTheme(),
                        ),
                      ],
                    ),
                  );
                }),
              ),
              const SizedBox(height: 24),

              // Settings Label
              Text(
                'Settings',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: primaryText,
                ),
              ),
              const SizedBox(height: 12),

              // Settings List
              Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.person_outline_rounded,
                      iconBgColor: AppTheme.brandLight,
                      iconColor: AppTheme.brand,
                      title: 'Account Details',
                      subtitle: 'Name, phone, business info',
                      primaryText: primaryText,
                      mutedText: mutedText,
                      onTap: () {},
                    ),
                    Divider(height: 1, color: borderColor),
                    _SettingsRow(
                      icon: Icons.chat_bubble_outline_rounded,
                      iconBgColor: AppTheme.successLight,
                      iconColor: AppTheme.success,
                      title: 'WhatsApp Settings',
                      subtitle: 'Broadcast, templates, auto-reply',
                      primaryText: primaryText,
                      mutedText: mutedText,
                      onTap: () {},
                    ),
                    Divider(height: 1, color: borderColor),
                    _SettingsRow(
                      icon: Icons.attach_money_rounded,
                      iconBgColor: AppTheme.warningLight,
                      iconColor: AppTheme.warning,
                      title: 'Payment Settings',
                      subtitle: 'Cash collection, receipts',
                      primaryText: primaryText,
                      mutedText: mutedText,
                      onTap: () {},
                    ),
                    Divider(height: 1, color: borderColor),
                    _SettingsRow(
                      icon: Icons.notifications_none_rounded,
                      iconBgColor: AppTheme.infoLight,
                      iconColor: AppTheme.info,
                      title: 'Notifications',
                      subtitle: 'Push, WhatsApp alerts',
                      primaryText: primaryText,
                      mutedText: mutedText,
                      onTap: () {},
                    ),
                    Divider(height: 1, color: borderColor),
                    _SettingsRow(
                      icon: Icons.language_rounded,
                      iconBgColor: AppTheme.brandLight,
                      iconColor: AppTheme.brand,
                      title: tr('settings.language'),
                      subtitle: tr('settings.language_subtitle'),
                      primaryText: primaryText,
                      mutedText: mutedText,
                      onTap: () => LanguagePickerSheet.show(context),
                    ),
                    Divider(height: 1, color: borderColor),
                    _SettingsRow(
                      icon: Icons.logout_rounded,
                      iconBgColor: AppTheme.dangerLight,
                      iconColor: AppTheme.danger,
                      title: 'Log Out',
                      titleColor: AppTheme.danger,
                      subtitle: 'Sign out of your account',
                      showChevron: false,
                      primaryText: primaryText,
                      mutedText: mutedText,
                      onTap: () async {
                        final confirmed = await AppDialogs.confirm(
                          title: 'Log Out',
                          message:
                              'Are you sure you want to sign out of your account?',
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
                        color: mutedText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Made with ♥ in Gujarat',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: mutedText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
  final Color primaryText;
  final Color mutedText;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.icon,
    required this.iconBgColor,
    required this.iconColor,
    required this.title,
    this.titleColor,
    required this.subtitle,
    this.showChevron = true,
    required this.primaryText,
    required this.mutedText,
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
                      color: titleColor ?? primaryText,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: mutedText,
                    ),
                  ),
                ],
              ),
            ),
            if (showChevron)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: mutedText,
              ),
          ],
        ),
      ),
    );
  }
}
