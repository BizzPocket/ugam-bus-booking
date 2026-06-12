import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// The one "expand chart to full screen" control, shared by every seat-chart
/// card. It is a [Positioned] overlay, so it must sit directly inside a [Stack]
/// wrapping the chart.
///
/// Pinned to the **top-left** on purpose: the chart's driver indicator owns the
/// top-right, so a left anchor never collides with it. Using a single widget
/// keeps the icon, placement, and a11y label identical on every screen instead
/// of each one re-deciding.
class ChartExpandButton extends StatelessWidget {
  final VoidCallback onTap;

  const ChartExpandButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: UgamSpacing.sm,
      left: UgamSpacing.sm,
      child: UgamIconButton(
        icon: Icons.open_in_full_rounded,
        onTap: onTap,
        semanticLabel: tr('fullscreen_chart.open'),
      ),
    );
  }
}
