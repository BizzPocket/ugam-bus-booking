import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../config/app_info.dart';
import '../config/i18n_config.dart';
import '../content/legal_content.dart';
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
                children: [
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
                  const SizedBox(height: UgamSpacing.xl),

                  _Footer(c: c, version: AppInfo.version),
                ],
              ),
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
        UgamSpacing.sm + 2,
      ),
      child: Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink3),
      ),
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
        constraints: const BoxConstraints(minHeight: 56),
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
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(color: c.ink3),
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
          style: UgamText.caption.copyWith(color: c.ink3),
        ),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          tr('customer_more.footer_made_by'),
          style: UgamText.micro.copyWith(color: c.ink3),
        ),
      ],
    );
  }
}
