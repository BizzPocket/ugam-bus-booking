part of 'board_canvas.dart';

// ─────────────────────────────────────────────────────────────────────────────
// One bus: zoom + scroll + grid.
// ─────────────────────────────────────────────────────────────────────────────

class _BoardBusView extends StatefulWidget {
  final PageStorageKey<String> storageKey;
  final BoardController controller;
  final BoardBusPage page;
  final BoardLens lens;
  final BoardCanvas canvas;
  final bool isCurrent;

  const _BoardBusView({
    super.key,
    required this.storageKey,
    required this.controller,
    required this.page,
    required this.lens,
    required this.canvas,
    required this.isCurrent,
  });

  @override
  State<_BoardBusView> createState() => _BoardBusViewState();
}

class _BoardBusViewState extends State<_BoardBusView> {
  final _scroll = ScrollController();

  BoardGridGeometry _geometry = BoardGridGeometry.empty;

  /// The full extent of the scroll viewport along its axis — padding included,
  /// because that is the frame a scroll offset is measured in.
  double _viewportExtent = 0;

  /// The scroll view's gutter at the near end of the axis.
  double _pad = 0;

  /// The berth the handler is looking at, remembered on every scroll stop so a
  /// density switch has something to restore to.
  String? _anchor;

  BoardDensity? _lastDensity;
  String? _pendingReveal;
  bool _revealAnimated = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  /// Brings [seatId] to the middle of the viewport. Under reduced motion this
  /// is an instant jump, not a scroll (spec §11).
  void reveal(String seatId, {bool animate = true}) {
    _revealAnimated = animate;
    final target = _geometry.offsetToCentre(
      seatId,
      _viewportExtent,
      leading: _pad,
      trailing: _pad,
    );
    if (target == null || !_scroll.hasClients) {
      // The frame that owns this berth has not been laid out yet — most often
      // the very first reveal, before the first paint. Hold it for that frame.
      _pendingReveal = seatId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _drainReveal());
      return;
    }
    if ((target - _scroll.offset).abs() < 1) return;
    if (!animate || _reduceMotion) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: UgamMotion.sheet,
        curve: UgamMotion.easeOut,
      );
    }
  }

  void _drainReveal() {
    final id = _pendingReveal;
    if (id == null || !mounted) return;
    _pendingReveal = null;
    reveal(id, animate: _revealAnimated);
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollEndNotification && _scroll.hasClients) {
      _anchor = _geometry.centredBerth(
        _scroll.offset,
        _viewportExtent,
        leading: _pad,
      );
    }
    return false;
  }

  /// A density switch changes every extent on the chart, so a pixel offset is
  /// meaningless across it. The BERTH is not: hold the one that was in the
  /// middle and put it back there (spec §3 — "switching cleanly without losing
  /// scroll position").
  void _handleDensityChange(BoardDensity next) {
    final was = _lastDensity;
    _lastDensity = next;
    if (was == null || was == next) return;
    final anchor =
        _anchor ??
        (_scroll.hasClients
            ? _geometry.centredBerth(
                _scroll.offset,
                _viewportExtent,
                leading: _pad,
              )
            : null);
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reveal(anchor, animate: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final density = controller.density;
        _handleDensityChange(density);

        final lanes = boardLanes(widget.page.layout);
        const padding = EdgeInsets.all(UgamSpacing.md);
        _pad = UgamSpacing.md;
        final crossAvailable = landscape
            ? constraints.maxHeight - padding.vertical
            : constraints.maxWidth - padding.horizontal;

        // A tile with a fixed footprint can be wider than the phone once a back
        // bench splits the aisle into six lanes. The chart only scrolls one
        // way, so the sixth lane would simply be gone; instead the whole bus is
        // scaled down to fit across, exactly as the existing seat chart does.
        // The SCALED box is what the geometry records, so hit-testing and
        // reveals stay honest, and the tile is painted at its natural size
        // inside a FittedBox so its internal layout is untouched.
        final fixed = widget.canvas.slotSizeOf?.call(context, density);
        Size? natural;
        final BoardTileMetrics metrics;
        if (fixed != null) {
          final perLane = landscape ? fixed.height : fixed.width;
          final needed = perLane * lanes.length;
          final scale = needed <= 0
              ? 1.0
              : math.min(1.0, crossAvailable / needed);
          metrics = BoardTileMetrics.fixed(fixed * scale, landscape: landscape);
          if (scale < 1) natural = fixed;
        } else {
          metrics = BoardTileMetrics.resolve(
            density: density,
            landscape: landscape,
            crossExtent: crossAvailable,
            laneCount: lanes.length,
          );
        }
        _geometry = BoardGridGeometry.of(
          layout: widget.page.layout,
          metrics: metrics,
        );
        _viewportExtent = landscape
            ? constraints.maxWidth
            : constraints.maxHeight;

        if (_geometry.isEmpty) return const SizedBox.shrink();

        final grid = _BoardGrid(
          geometry: _geometry,
          naturalTileSize: natural,
          controller: controller,
          page: widget.page,
          lens: widget.lens,
          canvas: widget.canvas,
          isCurrent: widget.isCurrent,
        );

        // Clipped because UgamPinchZoom deliberately does NOT clip (it is built
        // for diagrams that may be dragged past their box); on the Board a
        // zoomed chart bleeding over the sticky strip would hide the one number
        // that must never leave the screen.
        return ClipRect(
          child: UgamPinchZoom(
            // Gesture order, outside in: the page swipe and the chart scroll
            // both claim a one-finger drag at kTouchSlop (18) and so win the
            // arena ahead of InteractiveViewer's pan, which needs kPanSlop
            // (36). Two fingers reach the zoom, because a scale gesture is
            // something neither of the other two ever claims.
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: SingleChildScrollView(
                key: widget.storageKey,
                controller: _scroll,
                scrollDirection: _geometry.axis,
                padding: padding,
                child: Center(child: grid),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The grid itself.
// ─────────────────────────────────────────────────────────────────────────────

class _BoardGrid extends StatelessWidget {
  final BoardGridGeometry geometry;

  /// The tile's own footprint when the whole bus had to be scaled down to fit
  /// across the phone; null when the slot the geometry reserved IS the tile's
  /// natural size.
  final Size? naturalTileSize;

  final BoardController controller;
  final BoardBusPage page;
  final BoardLens lens;
  final BoardCanvas canvas;
  final bool isCurrent;

  const _BoardGrid({
    required this.geometry,
    required this.naturalTileSize,
    required this.controller,
    required this.page,
    required this.lens,
    required this.canvas,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final colors = UgamColors.of(context);
    final berths = <BoardBerth>[
      for (final placed in geometry.cells)
        boardBerthFor(placed.cell, page.berths),
    ];
    // Rows nothing matches are dropped (spec §13), and the filter is asked
    // against the lens's OWN predicate rather than a bucket key re-invented per
    // tile — see BoardController.isBerthDimmed.
    final legend = lens.legendFor(berths, colors);
    final walk = controller.walk.value;

    final tiles = <Widget>[];
    for (var i = 0; i < geometry.cells.length; i++) {
      final placed = geometry.cells[i];
      final berth = berths[i];
      final seatId = placed.cell.seatId;

      final slot = BoardBerthSlot(
        cell: placed.cell,
        berth: berth,
        paint: lens.paint(berth, colors),
        semanticLabel: lens.semanticLabel(berth),
        lens: lens,
        density: controller.density,
        size: placed.rect.size,
        aisleIndex: walk.indexOf(seatId) ?? i,
        isDimmed: controller.isBerthDimmed(berth, legend),
        isSearchHit: controller.isBerthSearchHit(berth),
        isSelected: seatId != null && controller.isSelected(seatId),
        isCursor: isCurrent && seatId != null && controller.cursor.value == seatId,
      );

      tiles.add(
        Positioned.fromRect(
          rect: placed.rect,
          child: _BerthHost(
            slot: slot,
            naturalSize: naturalTileSize,
            controller: controller,
            canvas: canvas,
          ),
        ),
      );
    }

    return SizedBox(
      width: geometry.size.width,
      height: geometry.size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _walkway(colors),
          // Below the tiles: a tap that lands in the gaps between compact
          // tiles is resolved to the berth nearest the thumb (spec §3).
          if (controller.isCompact) _nearestBerthCatcher(context, colors),
          ...tiles,
        ],
      ),
    );
  }

  /// The centre aisle as a quiet floor line — the same walkway guide the
  /// existing seat chart draws, so the Board still reads as a bus rather than
  /// as a spreadsheet. Decorative only; never the accent.
  Widget _walkway(UgamColorSet colors) {
    // A coach with a back bench splits the aisle into two lanes (the bench's
    // upper and lower berths). The handler still walks ONE aisle, so the guide
    // is drawn down the middle of whatever block of aisle lanes exists.
    final first = geometry.lanes.indexWhere((l) => l.isAisle);
    if (first < 0) return const SizedBox.shrink();
    final last = geometry.lanes.lastIndexWhere((l) => l.isAisle);

    final m = geometry.metrics;
    final stride = m.laneExtent + m.gap;
    final at =
        (first * stride + last * stride + m.laneExtent) / 2;
    final color = colors.ink3.withValues(
      alpha: BoardCanvasMetrics.walkwayAlpha,
    );

    return m.landscape
        ? Positioned(
            top: at,
            left: 0,
            width: geometry.size.width,
            height: BoardCanvasMetrics.walkwayThickness,
            child: ColoredBox(color: color),
          )
        : Positioned(
            left: at,
            top: 0,
            width: BoardCanvasMetrics.walkwayThickness,
            height: geometry.size.height,
            child: ColoredBox(color: color),
          );
  }

  Widget _nearestBerthCatcher(BuildContext context, UgamColorSet colors) =>
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            final cell = geometry.nearest(details.localPosition);
            if (cell == null) return;
            _handleBerthTap(
              cell,
              controller: controller,
              page: page,
              lens: lens,
              canvas: canvas,
              density: controller.density,
              // The berth's OWN box, so a slot handed out by the gap-catcher is
              // indistinguishable from one handed out by the tile itself.
              size: geometry.rectOf(cell.seatId)?.size ?? geometry.metrics.size,
              aisleIndex: controller.walk.value.indexOf(cell.seatId) ?? 0,
              colors: colors,
            );
          },
        ),
      );
}

/// Shared tap handling for both routes into a berth (the tile itself, and the
/// compact-mode nearest-berth catcher), so the two can never drift.
void _handleBerthTap(
  SeatCell cell, {
  required BoardController controller,
  required BoardBusPage page,
  required BoardLens lens,
  required BoardCanvas canvas,
  required BoardDensity density,
  required Size size,
  required int aisleIndex,
  required UgamColorSet colors,
}) {
  final seatId = cell.seatId;
  HapticFeedback.selectionClick();

  if (controller.isMultiSelecting) {
    if (seatId != null) controller.toggleSelected(seatId);
    return;
  }

  // Park the walk where the handler actually is, so "next outstanding" carries
  // on from here rather than from wherever the last auto-advance left off.
  controller.setCursor(seatId);

  final berth = boardBerthFor(cell, page.berths);
  canvas.onBerthTap?.call(
    BoardBerthSlot(
      cell: cell,
      berth: berth,
      paint: lens.paint(berth, colors),
      semanticLabel: lens.semanticLabel(berth),
      lens: lens,
      density: density,
      size: size,
      aisleIndex: aisleIndex,
    ),
  );
}
