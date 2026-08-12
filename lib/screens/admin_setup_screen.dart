import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

// Not re-exported by design/ugam.dart, so it has to be reached directly.
import '../design/components/ugam_tappable.dart';
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
              // The card is CENTRED in the leftover height rather than parked
              // under the app bar: it is ~300pt of content on an 812pt screen,
              // and top-aligning it left the bottom half of the page as
              // undesigned void above the sticky CTA. `minHeight` gives the
              // Center something to centre inside; the moment the content or
              // the text scale outgrows the viewport it scrolls exactly as
              // before.
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.md,
                    UgamSpacing.gutter,
                    UgamSpacing.xxl,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      // Less the vertical padding above, so a page that fits
                      // does not become scrollable by exactly that much.
                      minHeight: constraints.maxHeight -
                          UgamSpacing.md -
                          UgamSpacing.xxl,
                    ),
                    child: Center(
                      child: UgamCard.plain(
                        padding: const EdgeInsets.all(UgamSpacing.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Clean tokenized header — the lone copper signal:
                            // a support-agent mark floating on a soft copper
                            // halo (depth from light, not a border).
                            // Purely decorative -> px(), never tap(): the halo
                            // and the tile are not hit targets, so they shrink
                            // with the device instead of crowding out the copy
                            // beneath them.
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
                                        colors: [
                                          c.glow,
                                          c.glow.withValues(alpha: 0),
                                        ],
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
                            const SizedBox(height: UgamSpacing.md),
                            // A blocking gate has to say what to DO, not just
                            // who to ask. Without this the operator emails
                            // "please give me access" from an address support
                            // cannot match to a phone number, and the 24-hour
                            // promise above becomes a round trip.
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Icon(
                                    Icons.checklist_rounded,
                                    size: UgamScale.px(context, 14),
                                    color: c.ink3,
                                  ),
                                ),
                                const SizedBox(width: UgamSpacing.sm),
                                Expanded(
                                  child: Text(
                                    tr('admin_setup.support_include'),
                                    style: UgamText.caption
                                        .copyWith(color: c.ink3),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: UgamSpacing.lg),
                            // THE ADDRESS IS TEXT, NOT A BUTTON LABEL.
                            //
                            // It used to be the label of a full-width
                            // UgamButton — a fixed-height single line with
                            // `overflow: ellipsis`. The Gujarati overflow guard
                            // (test/overflow) measures it wanting 315pt inside
                            // a 229pt slot at the DEFAULT text scale on a 375pt
                            // phone, i.e. the one string this entire screen
                            // exists to hand over was already shipping as
                            // "support@ugambook…" to a locked-out operator who
                            // has no other way to reach anyone.
                            //
                            // Free text wraps, so it cannot truncate at any
                            // width or scale. The button's mail action was pure
                            // duplication of the sticky CTA below and is gone;
                            // copy is now a visible disc instead of a
                            // long-press with no on-screen existence (the
                            // long-press still works, and still opens nothing
                            // by accident because the address is inert).
                            Row(
                              children: [
                                Expanded(
                                  child: UgamTappable(
                                    onLongPress: _copyEmail,
                                    semanticLabel:
                                        tr('admin_setup.copy_email'),
                                    child: Text(
                                      _supportEmail,
                                      style: UgamText.bodyStrong
                                          .copyWith(color: c.ink),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: UgamSpacing.sm),
                                UgamIconButton(
                                  icon: Icons.copy_rounded,
                                  onTap: _copyEmail,
                                  semanticLabel: tr('admin_setup.copy_email'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
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
