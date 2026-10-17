part of 'board_canvas.dart';

// ─────────────────────────────────────────────────────────────────────────────
// One berth: semantics, dimming, pulse, gestures, drop target.
// ─────────────────────────────────────────────────────────────────────────────

class _BerthHost extends StatefulWidget {
  final BoardBerthSlot slot;
  final Size? naturalSize;
  final BoardController controller;
  final BoardCanvas canvas;

  const _BerthHost({
    required this.slot,
    required this.naturalSize,
    required this.controller,
    required this.canvas,
  });

  @override
  State<_BerthHost> createState() => _BerthHostState();
}

class _BerthHostState extends State<_BerthHost> {
  Offset? _pressAt;
  double _travel = 0;
  BoardDropState _dropState = BoardDropState.none;

  BoardBerthSlot get _slot => widget.slot;

  bool get _canDrag =>
      _slot.seatId != null &&
      (widget.canvas.canDragBerth?.call(_slot) ?? false) &&
      widget.canvas.onDrop != null;

  void _tap() {
    final id = _slot.seatId;
    HapticFeedback.selectionClick();
    if (widget.controller.isMultiSelecting) {
      if (id != null) widget.controller.toggleSelected(id);
      return;
    }
    widget.controller.setCursor(id);
    widget.canvas.onBerthTap?.call(_slot);
  }

  void _longPress() {
    final id = _slot.seatId;
    if (id != null) widget.controller.beginMultiSelect(id);
    widget.canvas.onBerthLongPress?.call(_slot);
  }

  bool _willAccept(BoardDragPayload payload) {
    if (payload.fromSeatId != null && payload.fromSeatId == _slot.seatId) {
      return false;
    }
    return widget.canvas.canDrop?.call(payload, _slot) ?? false;
  }

  void _drop(BoardDragPayload payload) {
    if (_willAccept(payload)) {
      HapticFeedback.lightImpact();
      widget.canvas.onDrop?.call(payload, _slot);
      return;
    }
    // The "no" pattern (spec §12): two heavy taps, not one, so it cannot be
    // mistaken for the success buzz.
    HapticFeedback.heavyImpact();
    Future<void>.delayed(
      const Duration(milliseconds: 90),
      HapticFeedback.heavyImpact,
    );
    widget.canvas.onInvalidDrop?.call(payload, _slot);
  }

  @override
  Widget build(BuildContext context) {
    final slot = _dropState == BoardDropState.none
        ? _slot
        : _copyWithDropState(_slot, _dropState);

    // The tile is given the box and fills it. Dimming is NOT applied here: the
    // canvas decides WHICH berths dim (it is the only thing that knows the
    // active filter, the search and the lens's legend predicates) and the tile
    // renders the fade, because fading a tinted fill by its own alpha reads far
    // better than dropping an opaque tile to 30% over the page.
    final natural = widget.naturalSize;
    Widget tile = SizedBox(
      width: slot.size.width,
      height: slot.size.height,
      child: natural == null
          ? widget.canvas.berthTileBuilder(context, slot)
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: natural.width,
                height: natural.height,
                child: widget.canvas.berthTileBuilder(context, slot),
              ),
            ),
    );

    if (slot.isSearchHit) tile = _BerthPulse(child: tile);

    Widget gestures = UgamTappable(
      onTap: _tap,
      // A draggable berth spends its long-press on the drag; the multi-select
      // that gesture also carries is resolved on release, by travel (see
      // [kBoardDragSlop]).
      onLongPress: _canDrag ? null : _longPress,
      // Berth taps are selectionClick, not the wrapper's lightImpact
      // (spec §12), and a handler tapping down a row of 22 would feel the
      // default as a rattle.
      haptic: false,
      pressedScale: slot.isCompact ? 0.90 : 0.96,
      child: tile,
    );

    if (_canDrag) gestures = _wrapDraggable(gestures);

    if (widget.canvas.canDrop != null) {
      // Captured by VALUE before the reassignment below. A builder that closed
      // over `gestures` itself would return the DragTarget from inside its own
      // builder — an infinite tree that mounts thousands of elements deep and
      // then trips a framework assertion rather than failing cleanly.
      final droppable = gestures;
      gestures = DragTarget<BoardDragPayload>(
        onWillAcceptWithDetails: (details) {
          // Dropping a berth back on itself is a cancel, not a move.
          if (details.data.fromSeatId != null &&
              details.data.fromSeatId == _slot.seatId) {
            return false;
          }
          final ok = _willAccept(details.data);
          // Both answers paint: an invalid target must say so BEFORE the finger
          // lifts, or the handler learns only from a snackbar after the fact.
          setState(
            () =>
                _dropState = ok ? BoardDropState.valid : BoardDropState.invalid,
          );
          // Accept the drop EVEN WHEN IT IS INVALID. Refusing here would make
          // the release fall through to the draggable's cancel path, and spec
          // §7 forbids a silent failure: the berth has to receive the drop in
          // order to flash danger, fire the "no" haptic and name the reason.
          return true;
        },
        onLeave: (_) => setState(() => _dropState = BoardDropState.none),
        onAcceptWithDetails: (details) {
          setState(() => _dropState = BoardDropState.none);
          _drop(details.data);
        },
        builder: (context, candidate, rejected) => droppable,
      );
    }

    // No Semantics wrapper: see [BoardBerthSlot.semanticLabel]. The tile is the
    // one node per berth.
    return gestures;
  }

  Widget _wrapDraggable(Widget child) {
    final payload = BoardDragPayload.fromBerth(
      fromSeatId: _slot.seatId!,
      label: _slot.berth.occupantName ?? _slot.berth.code,
    );

    return Listener(
      // Listener never joins the gesture arena, so it sees the whole pointer
      // stream regardless of who wins it — which is what lets a release be
      // classified as "held still" (multi-select) or "moved" (a drag).
      onPointerDown: (e) {
        _pressAt = e.position;
        _travel = 0;
      },
      onPointerMove: (e) {
        final from = _pressAt;
        if (from == null) return;
        final d = (e.position - from).distance;
        if (d > _travel) _travel = d;
      },
      child: LongPressDraggable<BoardDragPayload>(
        data: payload,
        delay: kBoardDragHold,
        hapticFeedbackOnStart: false,
        maxSimultaneousDrags: 1,
        onDragStarted: HapticFeedback.mediumImpact,
        // `onDragEnd` alone, deliberately. Flutter fires it for EVERY finished
        // drag and then fires `onDraggableCanceled` as well for a refused one,
        // so listening to both would settle a cancelled drag twice — and a
        // settle that lands under the travel threshold enters multi-select, so
        // the second one would announce a long-press the handler never made.
        onDragEnd: (_) => _settleDrag(),
        feedback: _DragChip(label: payload.label),
        childWhenDragging: Opacity(opacity: kBoardDimOpacity, child: child),
        child: child,
      ),
    );
  }

  /// A pick-up that never went anywhere was a long-press, and a long-press is
  /// multi-select (spec §7). Doing it here rather than binding both gestures at
  /// once is what keeps a tired thumb from assigning somebody to the wrong
  /// berth.
  void _settleDrag() {
    if (_travel < kBoardDragSlop) _longPress();
    _pressAt = null;
    _travel = 0;
  }

  static BoardBerthSlot _copyWithDropState(
    BoardBerthSlot slot,
    BoardDropState state,
  ) => BoardBerthSlot(
    cell: slot.cell,
    berth: slot.berth,
    paint: slot.paint,
    semanticLabel: slot.semanticLabel,
    lens: slot.lens,
    density: slot.density,
    size: slot.size,
    aisleIndex: slot.aisleIndex,
    isDimmed: slot.isDimmed,
    isSearchHit: slot.isSearchHit,
    isSelected: slot.isSelected,
    isCursor: slot.isCursor,
    dropState: state,
  );
}

/// The chip that follows the finger. Deliberately plain — the information is
/// WHO is moving, not a second copy of the tile.
class _DragChip extends StatelessWidget {
  final String label;

  const _DragChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final e = UgamElevation.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.tight,
          vertical: UgamSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          boxShadow: e.raised,
        ),
        child: Text(
          label,
          style: UgamText.caption.copyWith(color: c.ink),
        ),
      ),
    );
  }
}

/// The search highlight (spec §10): the matching berth pulses while everything
/// else dims. Under reduced motion the pulse becomes a static accent ring —
/// still a second, non-colour signal, just not a moving one.
class _BerthPulse extends StatefulWidget {
  final Widget child;

  const _BerthPulse({required this.child});

  @override
  State<_BerthPulse> createState() => _BerthPulseState();
}

class _BerthPulseState extends State<_BerthPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: UgamMotion.shimmer,
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.stop();
      _ctrl.value = 1;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true, min: 0.25);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(UgamRadius.seat),
          border: Border.all(
            color: c.accent,
            width: BoardCanvasMetrics.pulseRing,
          ),
          boxShadow: [
            BoxShadow(
              color: c.glow.withValues(
                alpha: BoardCanvasMetrics.pulseGlowAlpha * _ctrl.value,
              ),
              blurRadius: BoardCanvasMetrics.pulseBlur * _ctrl.value,
              spreadRadius: BoardCanvasMetrics.pulseSpread * _ctrl.value,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// The multi-bus page indicator (spec §3). Dots, because the count is small and
/// the gesture is the real control — this exists to say "there is another bus"
/// and to give the switch a keyboard/screen-reader route.
class _BusPageDots extends StatelessWidget {
  final int count;
  final int index;
  final String Function(int i) labelOf;
  final void Function(int i) onSelect;

  const _BusPageDots({
    required this.count,
    required this.index,
    required this.labelOf,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tap = UgamScale.tap(context, 44);

    return Semantics(
      label: tr(
        'board_canvas.bus_position',
        namedArgs: {'index': '${index + 1}', 'total': '$count'},
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              UgamTappable(
                onTap: i == index ? null : () => onSelect(i),
                semanticLabel: labelOf(i),
                pressedScale: 0.9,
                child: SizedBox(
                  width: tap / 2,
                  height: tap / 2,
                  child: Center(
                    child: AnimatedContainer(
                      duration: UgamMotion.tab,
                      curve: UgamMotion.easeOut,
                      width: i == index
                          ? BoardCanvasMetrics.dotActiveWidth
                          : BoardCanvasMetrics.dotSize,
                      height: BoardCanvasMetrics.dotSize,
                      decoration: BoxDecoration(
                        color: i == index ? c.accent : c.ink3,
                        borderRadius: BorderRadius.circular(UgamRadius.chip),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
