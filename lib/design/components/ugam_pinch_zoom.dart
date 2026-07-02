import 'package:flutter/material.dart';

import '../tokens.dart';

/// Pinch-to-zoom + pan wrapper around a [child]. A thin convenience over
/// [InteractiveViewer] with the project's defaults baked in (generous
/// boundary margin so the content can be dragged past the edges, and
/// [Clip.none] so a zoomed seat chart isn't hard-clipped at its box).
///
/// Use for large diagrams the user inspects but doesn't scroll — seat
/// charts, allocation PDFs, route maps.
class UgamPinchZoom extends StatelessWidget {
  final Widget child;
  final double minScale;
  final double maxScale;

  const UgamPinchZoom({
    super.key,
    required this.child,
    this.minScale = 0.6,
    this.maxScale = 2.5,
  });

  @override
  Widget build(BuildContext context) {
    // Referenced so a re-skin (e.g. tokens-driven background) stays a single
    // edit point and to keep the of(context) contract consistent across the
    // component set.
    UgamColors.of(context);
    return InteractiveViewer(
      panEnabled: true,
      scaleEnabled: true,
      minScale: minScale,
      maxScale: maxScale,
      boundaryMargin: const EdgeInsets.all(64),
      clipBehavior: Clip.none,
      constrained: true,
      child: child,
    );
  }
}
