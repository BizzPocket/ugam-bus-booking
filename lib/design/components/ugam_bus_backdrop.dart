import 'package:flutter/material.dart';

import '../tokens.dart';

/// Tokenized graphite placeholder for a tour / bus cover tile.
///
/// Replaces the old warm-brown "fake photo" gradient. Renders a clean
/// graphite surface (a subtle, deterministic-by-[seed] lift between
/// `c.card` and `c.cardElev`) with a faint champagne bus motif, plus an
/// optional champagne route monogram ([label], e.g. `"S→M"`). The accent is
/// rationed — barely-there glyph, single small monogram — so the tile reads
/// as premium graphite, never warm brand.
class UgamBusBackdrop extends StatelessWidget {
  final String seed;

  /// Optional short route monogram (e.g. `"S→M"`). When set, it is rendered
  /// as a centered champagne badge; when null, only the faint bus glyph shows.
  final String? label;

  const UgamBusBackdrop({super.key, required this.seed, this.label});

  /// Deterministic 0..1 lift so adjacent tiles differ slightly without ever
  /// leaving the graphite range.
  double get _lift {
    final h = seed.codeUnits.fold<int>(0, (a, b) => a + b);
    return (h % 7) / 7.0; // 0 .. ~0.86
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final top = Color.lerp(c.card, c.cardElev, 0.25 + _lift * 0.5)!;
    final bottom = Color.lerp(c.card, c.cardElev, 0.10 + _lift * 0.35)!;

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [top, bottom],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Faint champagne bus motif — single rationed accent, very low
            // alpha so it reads as a quiet graphic, not a fog.
            Positioned(
              right: -16,
              top: 18,
              child: Transform.rotate(
                angle: -0.06,
                child: Icon(
                  Icons.directions_bus_filled_rounded,
                  size: 230,
                  color: c.accent.withValues(alpha: 0.06),
                ),
              ),
            ),
            if (label != null && label!.isNotEmpty)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: UgamSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(
                      color: c.accent.withValues(alpha: 0.30),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: c.accent,
                    ),
                  ),
                ),
              ),
            // Subtle bottom scrim — keeps any white chips/titles a host places
            // over the tile (e.g. the 320px hero) legible.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x33000000)],
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
