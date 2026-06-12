import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// Shared chrome for the Settings sub-pages (Account, WhatsApp, Payment,
/// Notifications): a back-button + title header, a scrollable form body, and
/// an optional sticky "Save" CTA pinned to the bottom. Keeps the four pages
/// visually identical without each re-implementing the header/CTA scaffold.
class SettingsScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// When provided, a sticky [UgamCTA] is shown. Omit for read-only pages.
  final VoidCallback? onSave;
  final String? saveLabel;
  final bool saving;

  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.onSave,
    this.saveLabel,
    this.saving = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(title: title),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: onSave == null
          ? null
          : UgamStickyCTA(
              child: UgamCTA(
                label: saveLabel ?? tr('app.action.save'),
                leadingIcon: Icons.check_rounded,
                loading: saving,
                onPressed: saving ? null : onSave,
              ),
            ),
    );
  }
}
