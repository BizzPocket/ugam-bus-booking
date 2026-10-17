part of '../seat_chart_tile.dart';

/// The shared chair silhouette geometry, computed once for a tile [Size] so the
/// painter, the clipper and the dashed FREE border all draw the identical body.
///
/// The silhouette lives INSIDE the canonical tile box (the external footprint is
/// unchanged): a tall back with a large top radius (the headrest) and a shorter
/// base with a small bottom radius (the seat base). A [isDouble] berth fills the
/// box edge-to-edge to read as a 2-person bench; a single/seater insets its body
/// horizontally so it reads as a slimmer 1-person chair.
class _SeatShape {
  /// Doubles fill wider; singles/seaters inset so a 2-person berth is visibly
  /// bigger than a 1-person seat.
  final bool isDouble;

  const _SeatShape({required this.isDouble});

  /// Horizontal inset of the chair BODY from the tile edge. A double keeps a
  /// hair of inset (so its arms still read); a single insets a touch MORE so it
  /// reads slightly narrower than the double's berth — but only ~10% (was 16%),
  /// because a deeper inset shrank the body below the width an occupant name
  /// needs and the name was hard-clipped to a middle slice by the body ClipPath.
  double _sideInset(Size s) => (isDouble ? 0.06 : 0.10) * s.width;

  /// The rounded chair-body path: large top radius (back/headrest), small bottom
  /// radius (base). This is the clip + fill region every variant shares.
  Path bodyPath(Size s) {
    final inset = _sideInset(s);
    final rect = Rect.fromLTRB(inset, 0, s.width - inset, s.height);
    final topR = Radius.circular(s.height * 0.30); // back / headrest curve
    final botR = Radius.circular(s.height * 0.14); // shorter seat base
    return Path()
      ..addRRect(RRect.fromRectAndCorners(
        rect,
        topLeft: topR,
        topRight: topR,
        bottomLeft: botR,
        bottomRight: botR,
      ));
  }
}

/// Paints a dashed rounded-rectangle border for the FREE tile. Public so the
/// chart legend can reuse the exact same dashed swatch.
class SeatDashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  /// When non-null, dash the shared CHAIR silhouette instead of the plain
  /// rounded rect — the FREE tile passes `false` for a single/seater chair and
  /// `true` for a (wider) double berth, so an empty seat reads as the same chair
  /// outline as a filled one. Null (the legend's swatch) keeps the original
  /// dashed rounded-rectangle unchanged.
  final bool? chairIsDouble;

  SeatDashedBorderPainter({
    required this.color,
    required this.radius,
    this.chairIsDouble,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final Path path;
    if (chairIsDouble != null) {
      path = _SeatShape(isDouble: chairIsDouble!).bodyPath(size);
    } else {
      final rrect = RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(radius),
      );
      path = Path()..addRRect(rrect);
    }
    const dash = 4.0;
    const gap = 3.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant SeatDashedBorderPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.chairIsDouble != chairIsDouble;
}
