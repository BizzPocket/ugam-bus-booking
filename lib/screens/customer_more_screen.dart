import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../config/app_info.dart';
import '../config/i18n_config.dart';
import '../content/legal_content.dart';
import '../components/content_block_view.dart';
import '../design/ugam.dart';
import '../widgets/language_picker_sheet.dart';
import 'legal_document_screen.dart';

/// Customer-facing "More" menu — opened from the explore-tours top bar.
///
/// Groups language, about/legal, and support into one Ugam-styled list.
/// The customer has no account, so there's no profile header — just the
/// brand mark and the destinations they can reach without signing in.
class CustomerMoreScreen extends StatelessWidget {
  const CustomerMoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final activeLanguage = I18nConfig.labelFor(context.locale);

    return UgamScaffold(
      // No bottomNavigationBar and no dock on the customer surface, so nothing
      // else consumes the nav-bar inset — SafeArea must keep its bottom edge or
      // the last menu row and the version footer render under the system bar.
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(showBack: true, title: tr('customer_more.title')),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.lg,
                ),
                // The footer is NOT in this list. On a menu this short the page
                // used to end two-thirds up the screen with the version line
                // floating in the middle of nothing; pinning it to the bottom
                // of the frame (below) turns that leftover space into a
                // deliberate margin instead of an unfinished page.
                children: [
                  // Server-driven slot. Zero-height unless content is
                  // published, so this screen is unchanged by default.
                  const ContentSlot(ContentSlots.customerMoreTop),
                  _BrandHero(c: c),
                  const SizedBox(height: UgamSpacing.xl),

                  // NOTE: "Find my seat" no longer lives here. It is the one
                  // thing a rider who already booked opens the app to do, and
                  // it sat four taps in, behind a menu they had no reason to
                  // press. It is now a bar on the tour list itself — the first
                  // screen. Re-adding a copy here would only give one flow two
                  // doors and put the buried one back in play.

                  // ── Preferences ──
                  _SectionLabel(
                    c: c,
                    label: tr('customer_more.section_preferences'),
                  ),
                  UgamCard.plain(
                    padding: EdgeInsets.zero,
                    child: _MoreRow(
                      c: c,
                      icon: Icons.translate_rounded,
                      tone: UgamStatVariant.accent,
                      title: tr('customer_more.language'),
                      subtitle: activeLanguage,
                      onTap: () => LanguagePickerSheet.show(context),
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.lg),

                  // ── About & legal ──
                  _SectionLabel(
                    c: c,
                    label: tr('customer_more.section_about_legal'),
                  ),
                  UgamCard.plain(
                    padding: EdgeInsets.zero,
                    child: _MoreRow(
                      c: c,
                      icon: Icons.info_outline_rounded,
                      tone: UgamStatVariant.neutral,
                      title: tr('customer_more.about'),
                      subtitle: tr('customer_more.about_subtitle'),
                      onTap: () => _openDoc(LegalContent.about),
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  UgamCard.plain(
                    padding: EdgeInsets.zero,
                    child: _MoreRow(
                      c: c,
                      icon: Icons.shield_outlined,
                      tone: UgamStatVariant.neutral,
                      title: tr('customer_more.privacy'),
                      subtitle: tr('customer_more.privacy_subtitle'),
                      onTap: () => _openDoc(LegalContent.privacy),
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  UgamCard.plain(
                    padding: EdgeInsets.zero,
                    child: _MoreRow(
                      c: c,
                      icon: Icons.description_outlined,
                      tone: UgamStatVariant.neutral,
                      title: tr('customer_more.terms'),
                      subtitle: tr('customer_more.terms_subtitle'),
                      onTap: () => _openDoc(LegalContent.terms),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.md,
                UgamSpacing.gutter,
                UgamSpacing.md,
              ),
              child: _Footer(c: c, version: AppInfo.version),
            ),
          ],
        ),
      ),
    );
  }

  void _openDoc(LegalDoc doc) {
    HapticFeedback.selectionClick();
    Get.to(
      () => LegalDocumentScreen(doc: doc),
      transition: Transition.cupertino,
    );
  }
}

// ─── pieces ─────────────────────────────────────────────────────────────

class _BrandHero extends StatelessWidget {
  final UgamColorSet c;
  const _BrandHero({required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        children: [
          const UgamLogo(size: 56),
          const SizedBox(width: UgamSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ugam Foj',
                  style: UgamText.titleM.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('customer_tour_list.brand_tagline'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Section heading above a group of rows.
///
/// NOT the uppercase `UgamText.micro` eyebrow the admin surface uses.
/// `.toUpperCase()` is a NO-OP in Gujarati and Hindi — the two scripts have no
/// case — so on the primary language that eyebrow was just 10 px of faint ink3
/// with 1.4 letter-spacing prised between the conjuncts. The emphasis is
/// carried by weight and colour instead, which works in every script.
class _SectionLabel extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  const _SectionLabel({required this.c, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.xs,
        0,
        UgamSpacing.xs,
        UgamSpacing.tight,
      ),
      child: Text(label, style: UgamText.bodyStrong.copyWith(color: c.ink2)),
    );
  }
}

class _MoreRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final UgamStatVariant tone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MoreRow({
    required this.c,
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (iconBg, iconFg) = switch (tone) {
      UgamStatVariant.accent => (c.accentFill, c.accent),
      UgamStatVariant.good => (c.goodFill, c.good),
      UgamStatVariant.warm => (c.warmFill, c.warm),
      UgamStatVariant.neutral => (c.cardElev, c.ink2),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: ConstrainedBox(
        // Tap floor, not a fixed height: UgamScale.tap never returns under
        // 44 pt, so the row stays tappable on the smallest phone.
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 56)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md + 2,
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 20, color: iconFg),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 2),
                    // ink2, not ink3. This is the row's actual description —
                    // real content, not meta — and ink3 measures 3.5:1 on the
                    // ground, under AA. It also wraps rather than ellipsing:
                    // the Gujarati strings run ~30% longer than the English.
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final UgamColorSet c;
  final String version;
  const _Footer({required this.c, required this.version});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          tr('customer_more.version', namedArgs: {'version': version}),
          style: UgamText.tabular(UgamText.caption.copyWith(color: c.ink2)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: UgamSpacing.xs),
        // caption, not micro: micro is the UPPERCASE eyebrow style and carries
        // 1.4 letter-spacing, which prises apart Gujarati/Hindi conjuncts for
        // no gain — there is no uppercase in either script to justify it.
        Text(
          tr('customer_more.footer_made_by'),
          style: UgamText.caption.copyWith(color: c.ink3),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
