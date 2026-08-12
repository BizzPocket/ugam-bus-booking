import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// The eyebrow above a section ("Seat types", "Today", "Paid").
///
/// Renders on [UgamText.label] — Inter 13 / w700 / no tracking / sentence
/// case — because every string that reaches this widget is translated copy.
///
/// ## Why this is not uppercase Sora any more
///
/// It used to render `label.toUpperCase()` on [UgamText.micro]. That styling
/// only works in Latin, and Gujarati is this app's primary language, so the
/// component that exists to CENTRALISE section eyebrows was also centralising
/// three bugs at once — see [UgamText.micro] for the full account:
///
///   * `.toUpperCase()` is a no-op in Gujarati and Devanagari, so the caps
///     device that the whole look rested on did literally nothing;
///   * `letterSpacing` 1.4 pulls apart conjuncts that are meant to join —
///     it damages the script rather than styling it;
///   * Sora 10 lands at 8.5 under `UgamScale`'s 0.85 small-phone factor,
///     below the size a conjunct stack survives — and Sora has no Indic
///     coverage anyway, so the run fell back to the platform face regardless.
///
/// The emphasis that caps and tracking used to carry now comes from weight
/// (w700, a full step above [UgamText.bodyStrong]) and from colour, which per
/// [UgamText] is the one emphasis device that survives a fallback Indic face.
/// Net of the swap an eyebrow is *more* prominent than before, not less: 13/
/// w700 against the old 10/w600.
///
/// ## There is deliberately no "Latin chrome" opt-in
///
/// [UgamText.micro] keeps one legitimate use — fixed Latin/numeric chrome such
/// as seat codes, `PNR`, `AC` and plate numbers, where the caps device really
/// does fire. This widget intentionally exposes **no flag to opt back into
/// it**, for two reasons:
///
///   1. Nothing needs it. All 21 call sites pass a `tr(...)` string (a few via
///      a local wrapper such as `add_bus_screen`'s `_Label`/`_GroupHeader`).
///      Not one passes fixed Latin chrome — which follows from the name: a
///      plate number is *data* a section might display, never the section's
///      own heading.
///   2. It would be a footgun. `latin: true` reads as harmless to anyone
///      working in English, but the day that string gets translated the bug
///      returns silently, in the primary language, with nothing to catch it.
///      Re-admitting [UgamText.micro] through this door would recreate exactly
///      the drift this widget was created to stop.
///
/// If you genuinely have fixed Latin chrome, reach for
/// `Text(code, style: UgamText.micro)` directly at the call site. That is the
/// escape hatch, and it costs this component no surface area.
///
/// Pass the label in natural sentence case. Do **not** pre-uppercase it: that
/// would style the English build alone and leave gu/hi looking undesigned.
///
/// Scope note: this is deliberately NOT swept across the remaining raw
/// `UgamText.micro` eyebrows — that is an app-wide restyle. Adopt it inside a
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
      label,
      style: UgamText.label.copyWith(color: color ?? c.ink3),
    );
  }
}
