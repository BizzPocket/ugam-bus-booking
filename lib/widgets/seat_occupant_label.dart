import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../utils/seat_grid_placement.dart';

/// The largest [TextScaler] factor a seat label is allowed to render at.
///
/// **Why a seat label caps accessibility text at all.** `app.dart` lets the
/// user's OS preference through at up to 1.3x (`clamp(0.9, 1.3) *
/// UgamScale.of(context)`), and that factor MULTIPLIES [SeatOccupantLabel]'s
/// font sizes. The tile it lives in does not grow with it: `kSeatTileH` is a
/// fixed 74 logical pixels because the whole chart grid — `CombinedSeatGrid`'s
/// cell metrics, the pan/zoom canvas size, the fullscreen and PDF charts — is
/// laid out from that constant. So past some scale the label provably cannot
/// fit, and it overflowed (silently, as yellow hazard stripes) at 1.3x with a
/// two-line Gujarati name.
///
/// **Where 1.10 comes from.** The tightest of the three tile variants is the
/// booked tile with a priority border:
///
/// ```text
///   budget   = 74 (kSeatTileH) - 2x1.5 (border) - 15 (top pad) - 8 (bottom) = 48.0
///   content  = 2 lines x 13 x 1.12  +  2 (gap)  +  9.5 x 1.2   = 40.52s + 2
///   fits when 40.52s + 2 <= 48  ->  s <= 1.135
/// ```
///
/// 1.10 is that ceiling with ~1.4pt of slack for Skia's line-height rounding
/// and for the platform Indic fallback face, whose metrics this app does not
/// ship and cannot pin. The other two variants (the stacked-double half and the
/// leg-share half, both one-line) clear 1.10 with 3.6pt and 8.3pt to spare.
///
/// **What the user actually loses.** The cap is on the PRODUCT of the OS factor
/// and `UgamScale`, which is the number that reaches the glyphs, so:
///
/// * small phones are effectively untouched — 320pt at OS 1.3 is already only
///   1.105 after the 0.85 `UgamScale` floor;
/// * a 390pt phone at OS 1.3 renders the name at 13 x 1.10 = **14.3pt** instead
///   of 16.9pt;
/// * nothing ever renders SMALLER than it does today. The clamp is upper-bound
///   only, so the 0.85 small-phone shrink still applies unchanged.
///
/// Everything else on a chart screen — the app bar, the legend, the summary
/// bar, every sheet the tile opens — still scales the full 1.3x. This ceiling
/// applies to the ~74 labels inside the fixed grid and nowhere else.
///
/// **Alternatives that were rejected** are recorded on [SeatOccupantLabel].
const double kSeatLabelMaxTextScale = 1.10;

/// Stacked passenger identity for a seat tile: the full name (bold) above the
/// mobile number.
///
/// Name and mobile are mandatory on every passenger, so this is the canonical
/// way a booked seat reads in the grid charts. The name is shown at a fixed
/// point size and WRAPS up to [nameMaxLines] before ellipsis — it never shrinks
/// to unreadable (the old FittedBox scale-down made long names vanish). The
/// number is one tabular line, formatted with [displayPhone] (last-10 /
/// digits-only) and only hidden when a passenger has no digits on file.
///
/// ## Text scale
///
/// The sizes below are fixed *point* sizes, not fixed *rendered* sizes: the
/// ambient [MediaQuery.textScaler] still multiplies them. Because the tile is a
/// fixed-height box, this widget clamps that scaler to
/// [kSeatLabelMaxTextScale] — upper bound only, so `UgamScale`'s small-phone
/// shrink is untouched and the text is never smaller than these numbers times
/// the device factor. Read [kSeatLabelMaxTextScale] before changing a size, a
/// `height`, or the tile's padding: the ceiling is derived from that budget and
/// goes stale if the geometry moves.
///
/// Three fixes were weighed for the 1.3x overflow; the other two were rejected:
///
/// * **Ellipsise instead of wrapping** (drop to one line above some scale).
///   Rejected: at ~51-56pt of tile width a one-line Gujarati name is three or
///   four glyphs and an ellipsis — the exact `બાકી સોં…` failure the overflow
///   guard exists to catch. A reader who turned type UP needs to read the name,
///   not lose it; trading legibility of the *content* for legibility of the
///   *glyphs* is the wrong trade on an identity label.
/// * **Make the tile height track text scale.** Correct in principle and
///   rejected on blast radius: `kSeatTileH` is a compile-time constant that
///   `CombinedSeatGrid`, the fullscreen chart, the PDF export and the pan/zoom
///   canvas all size themselves from, so it would have to become a runtime
///   value threaded through every chart — and a grid that changes height with
///   an OS setting silently rescales every saved zoom/pan offset. Worth doing
///   deliberately one day; not as a bug fix.
///
/// Clamping is also the cheapest of the three on a hot path: it adds one
/// `MediaQuery` read and no extra widget or render object per tile, and a
/// 2+1 sleeper draws up to 74 of these at once.
class SeatOccupantLabel extends StatelessWidget {
  final String name;
  final String? phone;
  final Color nameColor;
  final Color phoneColor;

  /// Point sizes. The text is never rendered SMALLER than these times the
  /// device's own scale factor — it does not shrink to fit (that was the old
  /// FittedBox). It may still grow, up to [kSeatLabelMaxTextScale].
  final double nameSize;
  final double phoneSize;

  /// How many lines the name may wrap to before ellipsis. Two by default so a
  /// medium name stays whole; tight split halves pass 1.
  final int nameMaxLines;

  const SeatOccupantLabel({
    super.key,
    required this.name,
    required this.phone,
    required this.nameColor,
    required this.phoneColor,
    this.nameSize = 13,
    this.phoneSize = 9.5,
    this.nameMaxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final number = displayPhone(phone);
    // Upper bound only — `clamp` leaves the small-phone factor (0.85) alone and
    // only refuses to grow past what the fixed tile can hold. Applied to the
    // two Texts directly rather than through a MediaQuery wrapper so the fix
    // costs no extra element in a grid that renders up to 74 of these.
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: kSeatLabelMaxTextScale);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          name,
          textAlign: TextAlign.center,
          textScaler: scaler,
          maxLines: nameMaxLines,
          overflow: TextOverflow.ellipsis,
          style: UgamText.bodyStrong.copyWith(
            color: nameColor,
            fontSize: nameSize,
            fontWeight: FontWeight.w700,
            height: 1.12,
          ),
        ),
        if (number != null && number.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            number,
            textAlign: TextAlign.center,
            textScaler: scaler,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UgamText.tabular(
              UgamText.micro.copyWith(
                color: phoneColor,
                fontSize: phoneSize,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
