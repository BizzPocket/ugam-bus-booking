import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/ugam.dart';
import '../utils/app_snackbar.dart';

/// Post-Supabase: admin accounts are provisioned via the Supabase
/// dashboard, not from the app. This screen is now a single explainer
/// card that points the user at the Ugam support team.
class AdminSetupScreen extends StatelessWidget {
  const AdminSetupScreen({super.key});

  static const _supportEmail = 'support@ugambooking.com';

  Future<void> _contactSupport() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      query: 'subject=Admin%20Access%20Request',
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        AppSnackBar.error(
          'Could not open your mail app. Please email $_supportEmail.',
          title: 'Mail unavailable',
        );
      }
    } catch (_) {
      AppSnackBar.error(
        'Could not open your mail app. Please email $_supportEmail.',
        title: 'Mail unavailable',
      );
    }
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                child: UgamCard.media(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius:
                            BorderRadius.circular(UgamRadius.photo),
                        child: const SizedBox(
                          height: 120,
                          width: double.infinity,
                          child: UgamBusBackdrop(seed: 'admin-setup'),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.md,
                          UgamSpacing.lg,
                          UgamSpacing.md,
                          UgamSpacing.md,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: c.accentFill,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.support_agent_rounded,
                                size: 24,
                                color: c.accent,
                              ),
                            ),
                            const SizedBox(height: UgamSpacing.md),
                            Text(
                              'Admin accounts are managed by the Ugam team',
                              style: UgamText.titleL.copyWith(
                                color: c.ink,
                                fontSize: 20,
                              ),
                            ),
                            const SizedBox(height: UgamSpacing.sm),
                            Text(
                              "Contact our support team to add or modify admin access. "
                              "You'll be added to the system within 24 hours.",
                              style: UgamText.body.copyWith(
                                color: c.ink2,
                                fontSize: 14,
                                height: 1.55,
                              ),
                            ),
                            const SizedBox(height: UgamSpacing.md),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: UgamSpacing.md,
                                vertical: UgamSpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: c.cardElev,
                                borderRadius: BorderRadius.circular(
                                    UgamRadius.input),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.mail_outline_rounded,
                                      size: 16, color: c.ink2),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _supportEmail,
                                      style: UgamText.bodyStrong.copyWith(
                                        color: c.ink,
                                        fontSize: 13,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: 'Contact support',
                leadingIcon: Icons.mail_outline_rounded,
                onPressed: _contactSupport,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
