import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          tr(
            'admin_setup.mail_unavailable_body',
            namedArgs: {'email': _supportEmail},
          ),
          title: tr('admin_setup.mail_unavailable_title'),
        );
      }
    } catch (_) {
      AppSnackBar.error(
        tr(
          'admin_setup.mail_unavailable_body',
          namedArgs: {'email': _supportEmail},
        ),
        title: tr('admin_setup.mail_unavailable_title'),
      );
    }
  }

  Future<void> _copyEmail() async {
    await Clipboard.setData(const ClipboardData(text: _supportEmail));
    AppSnackBar.info(
      tr('admin_setup.email_copied', namedArgs: {'email': _supportEmail}),
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
            UgamAppBar(
              title: tr('admin_setup.title'),
              showBack: true,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                child: UgamCard.plain(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Clean tokenized header — the lone champagne signal:
                      // a large support-agent mark on an elevated tile.
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: c.cardElev,
                          borderRadius: BorderRadius.circular(UgamRadius.card),
                          border: Border.all(
                            color: c.accent.withValues(alpha: 0.30),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.support_agent_rounded,
                          size: 36,
                          color: c.accent,
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.lg),
                      Text(
                        tr('admin_setup.support_heading'),
                        style: UgamText.titleL.copyWith(
                          color: c.ink,
                          fontSize: 20,
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        tr('admin_setup.support_body'),
                        style: UgamText.body.copyWith(
                          color: c.ink2,
                          fontSize: 14,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.md),
                      // Email chip: tap to open mail, long-press to copy.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _contactSupport,
                        onLongPress: _copyEmail,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.md,
                            vertical: UgamSpacing.sm,
                          ),
                          decoration: BoxDecoration(
                            color: c.cardElev,
                            borderRadius: BorderRadius.circular(
                              UgamRadius.input,
                            ),
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.mail_outline_rounded,
                                size: 16,
                                color: c.ink2,
                              ),
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
                              const SizedBox(width: 8),
                              Icon(
                                Icons.copy_rounded,
                                size: 14,
                                color: c.ink3,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: tr('admin_setup.btn_contact_support'),
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
