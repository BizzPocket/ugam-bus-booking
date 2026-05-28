import 'package:flutter/material.dart';

/// Ugam Booking brand mark — the terracotta rising-sun, cream `ઉગમ`
/// word-mark, and deep-brown yatra-bus on cream, per the DEVAM brand.
///
/// Rendered from the single canonical asset (`assets/icon/ugam_logo.png`)
/// that ALSO feeds the platform launcher icons, so the in-app logo and the
/// app icon can never drift apart again (the old hand-painted CustomPaint
/// version had drifted to an off-brand red). Clipped to a rounded tile so
/// the cream artwork reads cleanly on the dark splash background.
class UgamLogo extends StatelessWidget {
  final double size;

  /// Corner radius of the logo tile. Defaults to a soft round proportional
  /// to [size].
  final double? borderRadius;

  const UgamLogo({
    super.key,
    this.size = 180,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    // The source PNG is 1024×1024 (it doubles as the launcher-icon master).
    // Decode it at the actual on-screen pixel size instead of inflating a
    // full ~4 MB bitmap for a small logo — cheaper decode + far less memory
    // on the splash, which is the very first screen.
    final cachePx = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius ?? size * 0.22),
      child: Image.asset(
        'assets/icon/ugam_logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: cachePx,
        cacheHeight: cachePx,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
