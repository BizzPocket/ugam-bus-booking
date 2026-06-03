import 'package:flutter/material.dart';

/// Visual fallback for bus / destination photography.
///
/// Renders a deterministic gradient (palette chosen by [seed]) with a
/// rotated bus silhouette overlay and a bottom darkening gradient so
/// titles + chips stay legible. Used everywhere a real photo would go
/// until the asset library lands in a later phase.
class UgamBusBackdrop extends StatelessWidget {
  final String seed;

  const UgamBusBackdrop({super.key, required this.seed});

  // Cohesive coffee/espresso family — one flat solid per tour, varying in
  // lightness so tours stay distinct while the app reads as one warm-brown
  // system. All shades keep overlaid white chips/scrim legible.
  static const _solids = <Color>[
    Color(0xFF3B2A20),       // dark coffee (brand primary)
    Color(0xFF4A3326),       // lifted brown
    Color(0xFF5C4130),       // mid mocha
    Color(0xFF6F4E39),       // light mocha
    Color(0xFF2E211A),       // deep espresso
    Color(0xFF7A5640),       // caramel-brown (lightest)
  ];

  Color get _solid {
    final h = seed.codeUnits.fold<int>(0, (a, b) => a + b);
    return _solids[h % _solids.length];
  }

  @override
  Widget build(BuildContext context) {
    final fill = _solid;
    return RepaintBoundary(
      child: Container(
        color: fill,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              right: -16,
              top: 18,
              child: Transform.rotate(
                angle: -0.06,
                child: Icon(
                  Icons.directions_bus_filled_rounded,
                  size: 230,
                  // Crisp, single-tone motif — slightly darkened shade of the
                  // fill rather than a hazy translucent white, so it reads as
                  // a clean graphic instead of fog.
                  color: Color.alphaBlend(
                    Colors.black.withValues(alpha: 0.14),
                    fill,
                  ),
                ),
              ),
            ),
            // Subtle, crisp bottom scrim only — just enough to keep overlaid
            // titles/chips legible on the hero, without muddying the tile.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color(0x4D000000), // 30% black, sharp toward the base
                  ],
                  stops: [0.55, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
