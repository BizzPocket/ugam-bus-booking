import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// App-wide responsive scale.
///
/// Every screen and component was tuned at a ~[baseline]-logical-width device.
/// On a narrower phone the same fixed pixel sizes (field heights, icon sizes,
/// section seams) and the same font sizes eat a bigger share of the screen, so
/// the UI reads as oversized and needs more scrolling. This returns a single
/// factor that shrinks the UI *proportionally* on smaller devices.
///
/// The factor is clamped to `[_min, _max]`:
///   * capped at `1.0` — large phones and tablets keep the tuned "cockpit"
///     density; nothing ever re-widens past the baseline.
///   * floored at `_min` — the smallest phones don't shrink text/hit-targets to
///     an unreadable/untappable size.
///
/// Text is scaled once, app-wide, by feeding this factor into
/// `MediaQuery.textScaler` at the app root (see `MyApp.build`). That is the
/// ONLY place the factor is applied automatically — it scales text everywhere.
///
/// Fixed-pixel chrome does NOT scale automatically. A component opts in per
/// dimension, and WHICH helper it uses depends on whether the box is tappable:
///
///   * [px] — decorative only (avatars, medallions, hero images, logos,
///     thumbnails, rails). Scales freely with the factor.
///   * [tap] — anything a finger lands on. Scales but is floored at 44pt, the
///     minimum tap target. Using [px] on a tappable box would shrink it below
///     44 on small phones and make the app strictly worse.
///
/// [of] remains available for the raw factor (as `UgamInput` uses it). Do not
/// assume a given widget's paddings/heights track this curve unless it calls
/// one of these itself.
class UgamScale {
  const UgamScale._();

  /// Logical width the design tokens were tuned against (≈ a modern 6.1" phone).
  static const double baseline = 390;

  static const double _min = 0.85;
  static const double _max = 1.0;

  static double _fromWidth(double width) =>
      (width / baseline).clamp(_min, _max);

  /// The responsive factor for the current screen. Reads the *unscaled* media
  /// width, so it is safe to call from the same place that sets `textScaler`
  /// (the two never compound — `textScaler` does not change [MediaQuery.size]).
  static double of(BuildContext context) =>
      _fromWidth(MediaQuery.sizeOf(context).width);

  /// Scale a fixed DECORATIVE dimension (icon medallions, avatars, hero
  /// images, logos, thumbnails, non-interactive rails). Never use for a
  /// tappable box — use [tap].
  static double px(BuildContext context, double v) => v * of(context);

  /// Scale a fixed INTERACTIVE box, floored at the 44pt minimum tap target.
  /// The factor is clamped at 0.85, so e.g. 50 -> 44 and 56 -> 47.6, while
  /// 44 stays 44 on every device.
  static double tap(BuildContext context, double v) =>
      math.max(44.0, v * of(context));
}
