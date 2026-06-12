import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';

/// The single, app-wide full-screen seat chart.
///
/// Every screen that shows a seat chart ([handler_bus_chart], [seat_detail],
/// [bus_status], the Assign / Rearrange seat workspaces, …) opens *this* one
/// view for its "expand" affordance — so the blown-up chart reads identically
/// everywhere. It deliberately shows **only** the chart: no roster, no stats,
/// no bus pills — just the canonical [CombinedSeatGrid] + [SeatChartTile]
/// inside a pinch-to-zoom / pan [InteractiveViewer], with a single close
/// control. Read-only by design: tiles carry no tap, drag, or edit affordance.
class FullscreenChartScreen extends StatelessWidget {
  /// The bus layout to render.
  final BusLayout layout;

  /// Seat-id → occupants of that seat. Same shape the chart screens already
  /// build (`length 0` free, `1` owned/whole-double, `2` shared).
  final Map<String, List<Passenger>> occupantsBySeat;

  /// Resolves a group id to its stable ring colour. Defaults to a hash-based
  /// resolver so a caller without a `PassengerGroup` index map still gets
  /// consistent group colours.
  final GroupColorResolver groupColors;

  /// Optional caption shown as a faint label (e.g. the bus name). Purely
  /// informational; the chart is the focus.
  final String? title;

  /// Driver-row label passed through to [CombinedSeatGrid].
  final String? driverLabel;

  /// Optional per-cell price-band WASH colour (already at `kPriceBandWashAlpha`).
  /// Returns the band colour for a seat cell's row, or null when the row is
  /// unbanded. Only the handler chart wires this so the expanded chart shows the
  /// same price stripes as the inline grid; other callers leave it null.
  final Color? Function(SeatCell cell)? bandColorFor;

  /// When true, the handler's one-way emphasis is applied: RET reads its distinct
  /// violet (vs GO cyan) and one-way leg pills carry a "½" half-fare marker — the
  /// at-a-glance "collect a different amount" cue. Off for non-handler callers.
  final bool emphasizeOneWay;

  const FullscreenChartScreen({
    super.key,
    required this.layout,
    required this.occupantsBySeat,
    this.groupColors = const GroupColorResolver({}),
    this.title,
    this.driverLabel,
    this.bandColorFor,
    this.emphasizeOneWay = false,
  });

  /// Push the full-screen chart over the current route.
  static Future<void>? open(
    BuildContext context, {
    required BusLayout layout,
    required Map<String, List<Passenger>> occupantsBySeat,
    GroupColorResolver groupColors = const GroupColorResolver({}),
    String? title,
    String? driverLabel,
    Color? Function(SeatCell cell)? bandColorFor,
    bool emphasizeOneWay = false,
  }) {
    HapticFeedback.selectionClick();
    return Get.to<void>(
      () => FullscreenChartScreen(
        layout: layout,
        occupantsBySeat: occupantsBySeat,
        groupColors: groupColors,
        title: title,
        driverLabel: driverLabel,
        bandColorFor: bandColorFor,
        emphasizeOneWay: emphasizeOneWay,
      ),
      fullscreenDialog: true,
      transition: Transition.downToUp,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final empty = layout.totalCells == 0;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Stack(
          children: [
            // ── The chart, and only the chart ──────────────────────────────
            Positioned.fill(
              child: empty
                  ? Center(
                      child: Text(
                        tr('fullscreen_chart.empty'),
                        style: UgamText.body.copyWith(color: c.ink2),
                      ),
                    )
                  : InteractiveViewer(
                      minScale: 0.6,
                      maxScale: 4,
                      boundaryMargin: const EdgeInsets.all(96),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            UgamSpacing.lg,
                            UgamSpacing.huge,
                            UgamSpacing.lg,
                            UgamSpacing.lg,
                          ),
                          // Scale the whole chart to fit the screen (both
                          // axes) so a tall bus never overflows the bottom;
                          // pinch-zoom (maxScale) still enlarges for detail.
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: CombinedSeatGrid(
                              layout: layout,
                              cellWidth: 64,
                              cellHeight: 64,
                              colGap: 6,
                              rowGap: 6,
                              driverLabel: driverLabel,
                              tileBuilder: (ctx, cell) {
                                final occupants = cell.seatId != null
                                    ? (occupantsBySeat[cell.seatId] ??
                                          const <Passenger>[])
                                    : const <Passenger>[];
                                return RepaintBoundary(
                                  child: SeatChartTile(
                                    cell: cell,
                                    occupants: occupants,
                                    groupColors: groupColors,
                                    bandColor: bandColorFor?.call(cell),
                                    emphasizeOneWay: emphasizeOneWay,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
            ),

            // ── Optional faint caption (top-left) ──────────────────────────
            if (title != null && title!.isNotEmpty)
              Positioned(
                left: UgamSpacing.gutter,
                top: UgamSpacing.md,
                child: Text(
                  title!,
                  style: UgamText.caption.copyWith(
                    color: c.ink3,
                    letterSpacing: 0.4,
                  ),
                ),
              ),

            // ── Single close control (top-right) ───────────────────────────
            Positioned(
              right: UgamSpacing.gutter,
              top: UgamSpacing.sm,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  Get.back<void>();
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.close_rounded, size: 20, color: c.ink),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
