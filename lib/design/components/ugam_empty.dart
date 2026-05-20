import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Empty state. Single thin-stroke icon + title + optional body + optional
/// CTA. No illustrations — illustrations read AI in this aesthetic.
class UgamEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? cta;

  const UgamEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.cta,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.huge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: c.ink3),
            const SizedBox(height: UgamSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: UgamText.titleM.copyWith(color: c.ink),
            ),
            if (body != null) ...[
              const SizedBox(height: UgamSpacing.sm),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: UgamText.body.copyWith(color: c.ink2),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (cta != null) ...[
              const SizedBox(height: UgamSpacing.xl),
              cta!,
            ],
          ],
        ),
      ),
    );
  }
}
