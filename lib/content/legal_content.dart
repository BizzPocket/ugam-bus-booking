/// Structured, render-ready legal + about documents shown by
/// [LegalDocumentScreen]. The canonical Privacy Policy text is the
/// publish-ready `privacy_policy.html` at the repo root — this is the same
/// content ported into Ugam-native blocks so it reads on-brand inside the
/// dark-first app instead of as an off-theme embedded web page.
///
/// Body text is localised via easy_localization (`tr('legal.…')` keys live in
/// `assets/translations/*.json`). Because `tr()` is not a `const` expression,
/// each document is exposed as a runtime getter rather than a `const` field.
library;

import 'package:easy_localization/easy_localization.dart';

enum LegalBlockKind { section, sub, paragraph, bullets }

/// One renderable unit of a [LegalDoc].
class LegalBlock {
  final LegalBlockKind kind;

  /// Text for [LegalBlockKind.section] / [LegalBlockKind.sub] /
  /// [LegalBlockKind.paragraph].
  final String? text;

  /// Items for [LegalBlockKind.bullets].
  final List<String>? items;

  /// When true the block renders inside a raised card (the html `.box`).
  final bool boxed;

  const LegalBlock._(this.kind, {this.text, this.items, this.boxed = false});

  const LegalBlock.section(String text) : this._(LegalBlockKind.section, text: text);
  const LegalBlock.sub(String text) : this._(LegalBlockKind.sub, text: text);
  const LegalBlock.paragraph(String text, {bool boxed = false})
      : this._(LegalBlockKind.paragraph, text: text, boxed: boxed);
  const LegalBlock.bullets(List<String> items)
      : this._(LegalBlockKind.bullets, items: items);
}

/// A full document: title, optional meta line, and the ordered blocks.
class LegalDoc {
  final String title;
  final String? meta;
  final List<LegalBlock> blocks;

  /// About-style docs show the brand logo above the title.
  final bool showLogo;

  const LegalDoc({
    required this.title,
    this.meta,
    required this.blocks,
    this.showLogo = false,
  });
}

class LegalContent {
  LegalContent._();

  // ─── PRIVACY POLICY ──────────────────────────────────────────────────
  // Ported verbatim (meaning-preserving) from privacy_policy.html.

  static LegalDoc get privacy => LegalDoc(
        title: tr('legal.privacy.title'),
        meta: tr('legal.privacy.meta'),
        blocks: [
          LegalBlock.paragraph(tr('legal.privacy.intro')),

          LegalBlock.section(tr('legal.privacy.s1_title')),
          LegalBlock.sub(tr('legal.privacy.s1_provide_sub')),
          LegalBlock.bullets([
            tr('legal.privacy.s1_provide_b1'),
            tr('legal.privacy.s1_provide_b2'),
          ]),
          LegalBlock.sub(tr('legal.privacy.s1_contacts_sub')),
          LegalBlock.paragraph(tr('legal.privacy.s1_contacts'), boxed: true),
          LegalBlock.sub(tr('legal.privacy.s1_device_sub')),
          LegalBlock.bullets([
            tr('legal.privacy.s1_device_b1'),
            tr('legal.privacy.s1_device_b2'),
            tr('legal.privacy.s1_device_b3'),
          ]),
          LegalBlock.paragraph(tr('legal.privacy.s1_no_collect')),

          LegalBlock.section(tr('legal.privacy.s2_title')),
          LegalBlock.bullets([
            tr('legal.privacy.s2_b1'),
            tr('legal.privacy.s2_b2'),
            tr('legal.privacy.s2_b3'),
            tr('legal.privacy.s2_b4'),
          ]),

          LegalBlock.section(tr('legal.privacy.s3_title')),
          LegalBlock.bullets([
            tr('legal.privacy.s3_b1'),
            tr('legal.privacy.s3_b2'),
          ]),

          LegalBlock.section(tr('legal.privacy.s4_title')),
          LegalBlock.bullets([
            tr('legal.privacy.s4_b1'),
            tr('legal.privacy.s4_b2'),
            tr('legal.privacy.s4_b3'),
            tr('legal.privacy.s4_b4'),
          ]),
          LegalBlock.paragraph(tr('legal.privacy.s4_no_sell')),

          LegalBlock.section(tr('legal.privacy.s5_title')),
          LegalBlock.paragraph(tr('legal.privacy.s5_body')),

          LegalBlock.section(tr('legal.privacy.s6_title')),
          LegalBlock.paragraph(tr('legal.privacy.s6_body')),

          LegalBlock.section(tr('legal.privacy.s7_title')),
          LegalBlock.paragraph(tr('legal.privacy.s7_body')),

          LegalBlock.section(tr('legal.privacy.s8_title')),
          LegalBlock.bullets([
            tr('legal.privacy.s8_b1'),
            tr('legal.privacy.s8_b2'),
            tr('legal.privacy.s8_b3'),
          ]),
          LegalBlock.paragraph(tr('legal.privacy.s8_body')),

          LegalBlock.section(tr('legal.privacy.s9_title')),
          LegalBlock.paragraph(tr('legal.privacy.s9_body')),

          LegalBlock.section(tr('legal.privacy.s10_title')),
          LegalBlock.paragraph(tr('legal.privacy.s10_body')),
        ],
      );

  // ─── TERMS OF SERVICE ────────────────────────────────────────────────
  // App-appropriate terms for a booking-request handoff tool where payment
  // and confirmation happen directly with the tour organiser.

  static LegalDoc get terms => LegalDoc(
        title: tr('legal.terms.title'),
        meta: tr('legal.terms.meta'),
        blocks: [
          LegalBlock.paragraph(tr('legal.terms.intro')),

          LegalBlock.section(tr('legal.terms.s1_title')),
          LegalBlock.paragraph(tr('legal.terms.s1_body')),

          LegalBlock.section(tr('legal.terms.s2_title')),
          LegalBlock.paragraph(tr('legal.terms.s2_body')),

          LegalBlock.section(tr('legal.terms.s3_title')),
          LegalBlock.bullets([
            tr('legal.terms.s3_b1'),
            tr('legal.terms.s3_b2'),
            tr('legal.terms.s3_b3'),
          ]),

          LegalBlock.section(tr('legal.terms.s4_title')),
          LegalBlock.paragraph(tr('legal.terms.s4_body')),

          LegalBlock.section(tr('legal.terms.s5_title')),
          LegalBlock.paragraph(tr('legal.terms.s5_body')),

          LegalBlock.section(tr('legal.terms.s6_title')),
          LegalBlock.paragraph(tr('legal.terms.s6_body')),

          LegalBlock.section(tr('legal.terms.s7_title')),
          LegalBlock.bullets([
            tr('legal.terms.s7_b1'),
            tr('legal.terms.s7_b2'),
            tr('legal.terms.s7_b3'),
          ]),

          LegalBlock.section(tr('legal.terms.s8_title')),
          LegalBlock.paragraph(tr('legal.terms.s8_body')),

          LegalBlock.section(tr('legal.terms.s9_title')),
          LegalBlock.paragraph(tr('legal.terms.s9_body')),

          LegalBlock.section(tr('legal.terms.s10_title')),
          LegalBlock.paragraph(tr('legal.terms.s10_body')),

          LegalBlock.section(tr('legal.terms.s11_title')),
          LegalBlock.paragraph(tr('legal.terms.s11_body')),
        ],
      );

  // ─── ABOUT ───────────────────────────────────────────────────────────

  static LegalDoc get about => LegalDoc(
        title: tr('legal.about.title'),
        showLogo: true,
        meta: tr('legal.about.meta'),
        blocks: [
          LegalBlock.paragraph(tr('legal.about.intro')),

          LegalBlock.section(tr('legal.about.travellers_title')),
          LegalBlock.paragraph(tr('legal.about.travellers_body')),

          LegalBlock.section(tr('legal.about.organisers_title')),
          LegalBlock.paragraph(tr('legal.about.organisers_body')),

          LegalBlock.section(tr('legal.about.who_title')),
          LegalBlock.paragraph(tr('legal.about.who_body')),
        ],
      );
}
