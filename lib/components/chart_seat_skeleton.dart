import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import 'chart_seat_tile.dart';

/// First-load placeholder for the CUSTOMER seat chart.
///
/// *** WHY A SKELETON AND NOT A SPINNER ***
/// The screen used to render a bare centred [CircularProgressIndicator] and
/// then replace it with a full ListView + seat grid once the RPC landed. That
/// swap changed the body's entire structure — and it usually happened while the
/// push transition was still animating, so the content visibly jumped into
/// place. That was the "janky transition into the chart" report.
///
/// The transition builder was never the problem: Flutter already supplies a
/// platform-appropriate one (PredictiveBack on Android, Cupertino on iOS), and
/// overriding Android's would throw away predictive-back gestures.
///
/// So this reserves the seats' shape up front, at the SAME
/// [ChartSeatMetrics] footprint the real tiles use, and the real chart lands
/// inside the space it already held.
class ChartSeatSkeleton extends StatelessWidget {
  /// Rows of placeholder berths. Six matches the common sleeper deck; the
  /// exact number only has to be close, since it is replaced the moment the
  /// real layout arrives.
  final int rows;

  const ChartSeatSkeleton({super.key, this.rows = 6});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    Widget berth() => const UgamSkeleton(
          width: ChartSeatMetrics.width,
          height: ChartSeatMetrics.height,
          radius: UgamRadius.seat,
        );

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mirrors CombinedSeatGrid's driver strip so the header does not
          // shift when the real grid replaces this.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              UgamSteeringWheel(size: 15, color: c.ink3),
              const SizedBox(width: 6),
              Text(
                tr('seat_ui.driver').toUpperCase(),
                style: UgamText.micro.copyWith(letterSpacing: 1, color: c.ink3),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Divider(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          for (var r = 0; r < rows; r++) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                berth(),
                const SizedBox(width: 6),
                berth(),
                // The aisle, same width as a berth slot.
                const SizedBox(width: 6),
                const SizedBox(width: ChartSeatMetrics.width),
                const SizedBox(width: 6),
                berth(),
                const SizedBox(width: 6),
                berth(),
              ],
            ),
            if (r < rows - 1) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}
