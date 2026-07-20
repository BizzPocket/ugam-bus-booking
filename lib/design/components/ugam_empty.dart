import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_cta.dart';

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

  /// Shared "couldn't load — check your connection" state with a Retry button.
  /// Structurally identical to the empty state (icon + title + body + one CTA),
  /// so it lives here as a factory instead of a near-duplicate sibling widget.
  /// Use everywhere a read fails (a smartFetch result with `failed` set) and
  /// there is nothing already on screen to keep. [onRetry] re-runs the load.
  factory UgamEmpty.error({
    Key? key,
    required VoidCallback onRetry,
    String? title,
    String? message,
  }) {
    return UgamEmpty(
      key: key,
      icon: Icons.cloud_off_rounded,
      title: title ?? tr('errors.connection_error'),
      body: message ?? tr('errors.load_failed'),
      cta: UgamCTA(
        label: tr('actions.retry'),
        leadingIcon: Icons.refresh_rounded,
        onPressed: onRetry,
      ),
    );
  }

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
