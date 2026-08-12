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
class FullscreenChartScreen extends StatefulWidget {
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

  /// Render a half-taken Double Sofa as a split (filled + empty) tile. Safe ONLY
  /// when [occupantsBySeat] is berth-accurate (a whole double held solo appears
  /// as the passenger twice). Callers that pass a leg-deduped map — where a whole
  /// double is a single entry — must leave this off. See [SeatChartTile.markHalfDouble].
  final bool markHalfDouble;

  const FullscreenChartScreen({
    super.key,
    required this.layout,
    required this.occupantsBySeat,
    this.groupColors = const GroupColorResolver({}),
    this.title,
    this.driverLabel,
    this.bandColorFor,
    this.markHalfDouble = false,
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
    bool markHalfDouble = false,
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
        markHalfDouble: markHalfDouble,
      ),
      fullscreenDialog: true,
      transition: Transition.downToUp,
    );
  }

  @override
  State<FullscreenChartScreen> createState() => _FullscreenChartScreenState();
}

/// Height the floating top bar reserves out of the chart's own padding, so a
/// tall chart never centres itself underneath the title + close control.
///
/// [UgamIconButton]'s default box is 44 and [UgamScale.tap] floors it there, so
/// this is exact on every device; a title pushed to two lines by a large text
/// scale is still shorter than the button beside it.
const double _kTopBarHeight = 44 + UgamSpacing.sm * 2;

class _FullscreenChartScreenState extends State<FullscreenChartScreen>
    with SingleTickerProviderStateMixin {
  /// Owned so the screen can offer a way BACK from a deep zoom. `minScale: 0.6`
  /// also lets the chart be pinched smaller than its fitted size, which
  /// previously stranded it as a postage stamp in the middle of the screen with
  /// no gesture-free way to restore it.
  final TransformationController _view = TransformationController();

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: UgamMotion.route,
  );
  Animation<Matrix4>? _restore;

  /// True whenever the viewer is off its identity transform — drives both the
  /// reset control and the hiding of the gesture hint.
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _view.addListener(_onViewChanged);
    _anim.addListener(() {
      final tween = _restore;
      if (tween != null) _view.value = tween.value;
    });
  }

  @override
  void dispose() {
    _view.removeListener(_onViewChanged);
    _anim.dispose();
    _view.dispose();
    super.dispose();
  }

  void _onViewChanged() {
    final m = _view.value;
    // Tolerances, not equality: a pinch that lands a hair off 1.0 must still
    // count as "at rest", or the reset control would never retire.
    final moved =
        (m.getMaxScaleOnAxis() - 1).abs() >= 0.01 ||
        m.getTranslation().length >= 0.5;
    if (moved == _zoomed) return;
    setState(() => _zoomed = moved);
  }

  void _resetZoom() {
    HapticFeedback.selectionClick();
    _restore = Matrix4Tween(begin: _view.value, end: Matrix4.identity())
        .animate(CurvedAnimation(parent: _anim, curve: UgamMotion.easeOut));
    _anim.forward(from: 0);
  }

  void _close() {
    HapticFeedback.selectionClick();
    Get.back<void>();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final empty = widget.layout.totalCells == 0;

    return UgamScaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // ── The chart, and only the chart ──────────────────────────────
            Positioned.fill(
              child: empty ? _emptyState() : _viewer(),
            ),

            // ── Floating chrome: caption + reset + close ───────────────────
            //
            // One constrained Row, not two bare `Positioned`s. A Positioned
            // given only `left`/`top` is laid out with UNBOUNDED width, so the
            // caption used to run off the right edge (silently clipped by the
            // Stack) and straight under the close button — which a Gujarati bus
            // name reaches at ~30% fewer characters than an English one.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: (widget.title != null && widget.title!.isNotEmpty)
                          // ink2, not ink3: this is the only thing naming which
                          // bus is on screen, and tertiary ink measures 3.7:1
                          // on the ground — under AA at caption size. Wraps to
                          // two lines rather than ellipsizing on the first.
                          ? Text(
                              widget.title!,
                              style: UgamText.caption.copyWith(color: c.ink2),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          : const SizedBox.shrink(),
                    ),
                    if (_zoomed) ...[
                      const SizedBox(width: UgamSpacing.sm),
                      UgamIconButton(
                        icon: Icons.fit_screen_rounded,
                        iconSize: 20,
                        semanticLabel: tr('fullscreen_chart.reset_zoom'),
                        onTap: _resetZoom,
                      ),
                    ],
                    const SizedBox(width: UgamSpacing.sm),
                    UgamIconButton(
                      icon: Icons.close_rounded,
                      iconSize: 20,
                      semanticLabel: tr('fullscreen_chart.close'),
                      onTap: _close,
                    ),
                  ],
                ),
              ),
            ),

            // ── Gesture hint ───────────────────────────────────────────────
            //
            // The chart is read-only and carries no affordance of its own, so
            // nothing on screen said it could be enlarged. Retires itself the
            // moment the gesture has been used.
            if (!empty && !_zoomed)
              Positioned(
                left: UgamSpacing.gutter,
                right: UgamSpacing.gutter,
                bottom: UgamSpacing.md,
                child: IgnorePointer(
                  child: Text(
                    tr('fullscreen_chart.zoom_hint'),
                    textAlign: TextAlign.center,
                    style: UgamText.micro.copyWith(
                      color: c.ink3,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() => UgamEmpty(
    icon: Icons.grid_off_rounded,
    title: tr('fullscreen_chart.empty'),
    body: tr('fullscreen_chart.empty_body'),
    cta: UgamCTA(
      label: tr('fullscreen_chart.close'),
      leadingIcon: Icons.arrow_back_rounded,
      onPressed: _close,
    ),
  );

  Widget _viewer() => InteractiveViewer(
    transformationController: _view,
    minScale: 0.6,
    maxScale: 4,
    boundaryMargin: const EdgeInsets.all(96),
    child: Center(
      child: Padding(
        // Top clears the floating chrome, bottom clears the gesture hint, so
        // the fitted chart is centred in the space actually left over rather
        // than sliding under either.
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.lg,
          _kTopBarHeight,
          UgamSpacing.lg,
          UgamSpacing.huge2,
        ),
        // Scale the whole chart to fit the screen (both axes) so a tall bus
        // never overflows the bottom; pinch-zoom (maxScale) still enlarges
        // for detail.
        child: FittedBox(
          fit: BoxFit.contain,
          child: UgamBusChassis(
            child: CombinedSeatGrid(
              layout: widget.layout,
              cellWidth: 64,
              cellHeight: 64,
              colGap: 6,
              rowGap: 6,
              driverLabel: widget.driverLabel,
              tileBuilder: (ctx, cell) {
                final occupants = cell.seatId != null
                    ? (widget.occupantsBySeat[cell.seatId] ??
                          const <Passenger>[])
                    : const <Passenger>[];
                return RepaintBoundary(
                  child: SeatChartTile(
                    cell: cell,
                    occupants: occupants,
                    groupColors: widget.groupColors,
                    bandColor: widget.bandColorFor?.call(cell),
                    markHalfDouble: widget.markHalfDouble,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
