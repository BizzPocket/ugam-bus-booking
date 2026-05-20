import 'package:flutter/material.dart';

import '../tokens.dart';

/// Visual fallback for bus / destination photography.
///
/// Renders a deterministic gradient (palette chosen by [seed]) with a
/// rotated bus silhouette overlay and a bottom darkening gradient so
/// titles + chips stay legible. Used everywhere a real photo would go
/// until the asset library lands in a later phase.
class UgamBusBackdrop extends StatelessWidget {
  final String seed;

  const UgamBusBackdrop({super.key, required this.seed});

  static const _palettes = <List<Color>>[
    [Color(0xFF1E3A8A), Color(0xFF0F172A)],   // deep blue
    [Color(0xFF7C2D12), Color(0xFF1F0A06)],   // burnt amber
    [Color(0xFF134E4A), Color(0xFF052E2B)],   // teal
    [Color(0xFF581C87), Color(0xFF1E0936)],   // royal purple
    [Color(0xFF064E3B), Color(0xFF021F18)],   // forest
    [Color(0xFFB91C1C), Color(0xFF450707)],   // crimson
  ];

  List<Color> get _palette {
    final h = seed.codeUnits.fold<int>(0, (a, b) => a + b);
    return _palettes[h % _palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _palette,
        ),
      ),
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
                color: c.ink.withValues(alpha: 0.18),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.45),
                ],
                stops: const [0.45, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
