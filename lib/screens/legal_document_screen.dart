import 'package:flutter/material.dart';

import '../components/ugam_logo.dart';
import '../content/legal_content.dart';
import '../design/ugam.dart';

/// Renders a [LegalDoc] (Privacy Policy / Terms / About) natively in the
/// Ugam dark-first style, so legal pages read as part of the app rather than
/// as an embedded off-theme web page.
class LegalDocumentScreen extends StatelessWidget {
  final LegalDoc doc;
  const LegalDocumentScreen({super.key, required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(title: doc.title),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.xl,
                  UgamSpacing.sm,
                  UgamSpacing.xl,
                  UgamSpacing.huge2,
                ),
                children: [
                  if (doc.showLogo) ...[
                    const Center(child: UgamLogo(size: 84)),
                    const SizedBox(height: UgamSpacing.lg),
                  ],
                  Text(
                    doc.title,
                    style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 26),
                    textAlign: doc.showLogo ? TextAlign.center : TextAlign.start,
                  ),
                  if (doc.meta != null) ...[
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      doc.meta!,
                      style: UgamText.caption.copyWith(color: c.ink3, height: 1.4),
                      textAlign:
                          doc.showLogo ? TextAlign.center : TextAlign.start,
                    ),
                  ],
                  const SizedBox(height: UgamSpacing.md),
                  Container(height: 3, width: 48, color: c.accent),
                  const SizedBox(height: UgamSpacing.lg),
                  for (final block in doc.blocks) _Block(block: block, c: c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  final LegalBlock block;
  final UgamColorSet c;
  const _Block({required this.block, required this.c});

  @override
  Widget build(BuildContext context) {
    switch (block.kind) {
      case LegalBlockKind.section:
        return Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.xl, bottom: UgamSpacing.sm),
          child: Text(
            block.text!,
            style: UgamText.titleM.copyWith(
              color: c.ink,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
        );
      case LegalBlockKind.sub:
        return Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.md, bottom: UgamSpacing.xs),
          child: Text(
            block.text!,
            style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
          ),
        );
      case LegalBlockKind.paragraph:
        final body = Text(
          block.text!,
          style: UgamText.body.copyWith(color: c.ink2, height: 1.55, fontSize: 14.5),
        );
        if (!block.boxed) {
          return Padding(
            padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
            child: body,
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
          child: Container(
            padding: const EdgeInsets.all(UgamSpacing.lg),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.row),
              border: Border.all(color: c.border),
            ),
            child: body,
          ),
        );
      case LegalBlockKind.bullets:
        return Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.xs, bottom: UgamSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in block.items!)
                Padding(
                  padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7, right: UgamSpacing.sm),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: c.ink3,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          item,
                          style: UgamText.body.copyWith(
                            color: c.ink2,
                            height: 1.5,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
    }
  }
}

