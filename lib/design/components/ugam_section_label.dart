import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// The uppercase eyebrow above a section ("SEAT TYPES", "TODAY", "PAID").
///
/// [UgamText.micro] already IS this style, but ~130 sites re-derive it by hand
/// and several drifted (a forked `letterSpacing`, a `.toUpperCase()` the next
/// one forgot). Naming it means a section eyebrow is one widget, and the
/// uppercasing happens in exactly one place.
///
/// Pass the label in natural case — [UgamSectionLabel] uppercases it. Callers
/// that already hold an uppercase string can pass it unchanged.
///
/// Scope note: this is deliberately NOT swept across the existing raw
/// `UgamText.micro` sites — that is an app-wide restyle. Adopt it inside a
/// file a wave is already editing.
class UgamSectionLabel extends StatelessWidget {
  final String label;

  /// Defaults to [UgamColorSet.ink3] — the tertiary/meta ink an eyebrow wants.
  final Color? color;

  const UgamSectionLabel(this.label, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Text(
      label.toUpperCase(),
      style: UgamText.micro.copyWith(color: color ?? c.ink3),
    );
  }
}
