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
/// Fixed-pixel chrome does NOT scale automatically. A shared component MAY opt
/// in for its own fixed dimensions by multiplying by [of] —
/// `final s = UgamScale.of(context);` then `54 * s` — as `UgamInput` does.
/// This is deliberately opt-in: most components rely on the app-wide text
/// scaling plus the `_min` floor rather than per-dimension scaling. Do not
/// assume a given widget's paddings/heights track this curve unless it calls
/// [of] itself.
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
}
