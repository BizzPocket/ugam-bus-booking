import 'package:flutter/material.dart';

import '../../design/ugam.dart';

/// The circular from → to connector between the From and To city fields —
/// ONE widget shared by the create-tour and edit-tour forms, so the two forms
/// stay one design.
///
/// Decorative chrome: it separates two inputs, it is not a thing the agent
/// selected, so it carries no accent (see [Brand] — the amber means "this is
/// yours" and nothing else). It was once `accentFill` + `accent` in both
/// orientations, and the edit screen was spending copper on it three times
/// over (here, and on both preview pills) while the actual amber signal, the
/// focused field ring, had to compete with all of it.
class TourRouteArrow extends StatelessWidget {
  final UgamColorSet c;
  final bool vertical;

  const TourRouteArrow({super.key, required this.c, required this.vertical});

  @override
  Widget build(BuildContext context) {
    final d = UgamScale.px(context, 30);
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        vertical ? Icons.arrow_downward_rounded : Icons.arrow_forward_rounded,
        size: UgamScale.px(context, 14),
        color: c.ink2,
      ),
    );
  }
}
