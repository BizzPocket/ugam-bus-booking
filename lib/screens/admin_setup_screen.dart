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
      // Localized subject. Dart's Uri normalizer preserves valid %XX escapes,
      // so encodeComponent's output is not double-encoded here.
      query: 'subject=${Uri.encodeComponent(tr('admin_setup.mail_subject'))}',
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
                      // Purely decorative -> px(), never tap(): the halo and
                      // the tile are not hit targets, so they shrink with the
                      // device instead of crowding out the copy beneath them.
                      SizedBox(
                        width: UgamScale.px(context, 96),
                        height: UgamScale.px(context, 96),
                        child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: UgamScale.px(context, 96),
                              height: UgamScale.px(context, 96),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [c.glow, c.glow.withValues(alpha: 0)],
                                  stops: const [0.0, 0.72],
                                ),
                              ),
                            ),
                            Container(
                              width: UgamScale.px(context, 52),
                              height: UgamScale.px(context, 52),
                              decoration: BoxDecoration(
                                color: c.accentFill,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.card,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.support_agent_rounded,
                                size: UgamScale.px(context, 28),
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
                      // The hand-rolled Container was a like-for-like neutral
                      // button (cardElev fill, UgamRadius.input, icon + label)
                      // that merely LOOKED like a static info strip, so it is
                      // now the real thing. UgamButton has no long-press slot,
                      // so the copy gesture rides an outer GestureDetector —
                      // its LongPressGestureRecognizer and the button's inner
                      // tap recognizer resolve cleanly in the gesture arena.
                      GestureDetector(
                        onLongPress: _copyEmail,
                        child: UgamButton(
                          kind: UgamButtonKind.neutral,
                          label: _supportEmail,
                          icon: Icons.mail_outline_rounded,
                          expand: true,
                          onPressed: _contactSupport,
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
