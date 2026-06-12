import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

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

  static const String _appVersion = '1.0.0';

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final activeLanguage = I18nConfig.labelFor(context.locale);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(c: c),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.huge2,
                ),
                children: [
                  _BrandHero(c: c),
                  const SizedBox(height: UgamSpacing.xl),

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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MoreRow(
                          c: c,
                          icon: Icons.info_outline_rounded,
                          tone: UgamStatVariant.neutral,
                          title: tr('customer_more.about'),
                          subtitle: tr('customer_more.about_subtitle'),
                          onTap: () => _openDoc(LegalContent.about),
                        ),
                        _Divider(c: c),
                        _MoreRow(
                          c: c,
                          icon: Icons.shield_outlined,
                          tone: UgamStatVariant.neutral,
                          title: tr('customer_more.privacy'),
                          subtitle: tr('customer_more.privacy_subtitle'),
                          onTap: () => _openDoc(LegalContent.privacy),
                        ),
                        _Divider(c: c),
                        _MoreRow(
                          c: c,
                          icon: Icons.description_outlined,
                          tone: UgamStatVariant.neutral,
                          title: tr('customer_more.terms'),
                          subtitle: tr('customer_more.terms_subtitle'),
                          onTap: () => _openDoc(LegalContent.terms),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xl),

                  _Footer(c: c, version: _appVersion),
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

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  const _TopBar({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('customer_more.title'),
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 24),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandHero extends StatelessWidget {
  final UgamColorSet c;
  const _BrandHero({required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(10),
            child: Image.asset(
              'assets/icon/ugam_logo.png',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ugam Foj',
                  style: UgamText.titleM.copyWith(color: c.ink, fontSize: 17),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('customer_tour_list.brand_tagline'),
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
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
        UgamSpacing.sm,
      ),
      child: Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(
          color: c.ink3,
          fontSize: 11,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
        ),
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
                  borderRadius: BorderRadius.circular(12),
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
                      style: UgamText.titleS.copyWith(
                        color: c.ink,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(
                        color: c.ink3,
                        fontSize: 12,
                      ),
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

class _Divider extends StatelessWidget {
  final UgamColorSet c;
  const _Divider({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
      child: Divider(height: 1, color: c.border),
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
          style: UgamText.caption.copyWith(color: c.ink3, fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(
          tr('customer_more.footer_made_by'),
          style: UgamText.micro.copyWith(color: c.ink3, fontSize: 11),
        ),
      ],
    );
  }
}
