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

    return UgamScaffold(
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
                  padding: const EdgeInsets.all(UgamSpacing.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Clean tokenized header — the lone copper signal: a
                      // support-agent mark floating on a soft copper halo
                      // (depth from light, not a border).
                      SizedBox(
                        width: 96,
                        height: 96,
                        child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [c.glow, c.glow.withValues(alpha: 0)],
                                  stops: const [0.0, 0.72],
                                ),
                              ),
                            ),
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: c.accentFill,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.card,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.support_agent_rounded,
                                size: 28,
                                color: c.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.xl),
                      Text(
                        tr('admin_setup.support_heading'),
                        style: UgamText.titleL.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        tr('admin_setup.support_body'),
                        style: UgamText.body.copyWith(color: c.ink2),
                      ),
                      const SizedBox(height: UgamSpacing.lg),
                      // Email chip: tap to open mail, long-press to copy.
                      // No border — a quiet elevated fill separates it.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _contactSupport,
                        onLongPress: _copyEmail,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.md,
                            vertical: UgamSpacing.md,
                          ),
                          decoration: BoxDecoration(
                            color: c.cardElev,
                            borderRadius: BorderRadius.circular(
                              UgamRadius.input,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.mail_outline_rounded,
                                size: 16,
                                color: c.ink2,
                              ),
                              const SizedBox(width: UgamSpacing.sm),
                              Flexible(
                                child: Text(
                                  _supportEmail,
                                  style: UgamText.bodyStrong.copyWith(
                                    color: c.ink,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: UgamSpacing.sm),
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
