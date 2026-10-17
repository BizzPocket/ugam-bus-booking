part of '../seat_chart_tile.dart';

/// A tiny pill stamp for the one-way leg — "GO" (cyan [kOneWayTint]) / "RET"
/// (violet [kReturnTint]) in its leg [tint]. Used on the booked tile, the
/// leg-shared split, and the shared-double halves so a one-way leg reads the
/// same everywhere. When [half] is set, a "½" follows the label to flag that the
/// leg pays HALF fare — the handler's at-a-glance "collect a different amount"
/// cue.
class SeatLegPill extends StatelessWidget {
  final String label;
  final Color tint;
  final bool half;

  const SeatLegPill({
    super.key,
    required this.label,
    required this.tint,
    this.half = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        border: Border.all(color: tint.withValues(alpha: 0.85), width: 0.8),
      ),
      child: Text(
        half
            ? tr('seat_leg.half_label', namedArgs: {'leg': label})
            : label,
        style: UgamText.micro.copyWith(
          color: tint,
          fontSize: 7.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}


/// The payload carried by a [SeatDragWrapper] long-press drag: the seat the
/// occupant was lifted from. The grid/workbench resolves who is being moved
/// from this seat id, so the wrapper stays purely about the gesture.
class SeatDragData {
  final String fromSeatId;
  const SeatDragData(this.fromSeatId);
}

/// The payload carried when a PENDING (unseated) rider is dragged from the
/// assignment dock onto a seat. Distinct from [SeatDragData] so a seat's two
/// drop targets never cross wires — Flutter routes each drag to the target that
/// matches its payload type.
class PendingRiderDragData {
  final String passengerId;
  const PendingRiderDragData(this.passengerId);
}

/// Wraps a rendered seat [child] with long-press DRAG (when [draggable]) and
/// DROP-target behaviour, so any chart can become move/swap capable without the
/// tile itself knowing about gestures. The wrapper is deliberately *dumb*: it
/// reports a drop as `(fromSeatId, toSeatId)` and lets the caller decide whether
/// that is a move (free target) or a swap (occupied target) and call the
/// group-safe controller. It writes NO data and makes NO move/swap decision.
///
/// While a drag is in flight ([dragActive]) a tile lights up per [highlight]:
///   * [SeatDropHighlight.valid]   — green ring (brighter + a pop when hovered).
///   * [SeatDropHighlight.blocked] — red lock wash (a protected occupant).
///   * [SeatDropHighlight.dim]     — faded (an illegal/ambiguous target).
///   * [SeatDropHighlight.none]    — no overlay.
/// The caller computes [highlight] (it owns the move-vs-swap rules); the wrapper
/// only paints it. The overlay is an [IgnorePointer] so it never steals the
/// drop hit-test.
enum SeatDropHighlight { none, valid, blocked, dim }

class SeatDragWrapper extends StatelessWidget {
  final Widget child;

  /// The seat id this tile represents (the drag source / drop target id).
  final String seatId;

  /// True when this tile can be picked up (a single, unambiguous occupant).
  final bool draggable;

  /// The occupant name shown on the chip that follows the finger.
  final String? dragLabel;

  /// True while SOME drag is in flight (drives whether the highlight paints).
  final bool dragActive;

  /// This tile's classification against the active drag (caller-computed).
  final SeatDropHighlight highlight;

  /// True when this tile WILL accept a drop — gates the drag target's
  /// onWillAcceptWithDetails so an illegal target bounces. The caller may still
  /// want the drop reported (to toast a reason); set [acceptForReason] for that.
  final bool acceptForReason;

  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnd;

  /// Fired when a seat is dropped onto this one. The caller decides move vs swap
  /// from the two seat ids and calls the group-safe controller.
  final void Function(String fromSeatId, String toSeatId)? onSeatDropped;

  /// Fired when a PENDING rider dragged from the dock is dropped onto this seat.
  /// Null disables the pending-rider drop target, so seat→seat-only and
  /// read-only charts are unchanged. The caller validates and places-or-rejects.
  final void Function(String passengerId)? onPendingRiderDropped;

  const SeatDragWrapper({
    super.key,
    required this.child,
    required this.seatId,
    required this.draggable,
    this.dragLabel,
    this.dragActive = false,
    this.highlight = SeatDropHighlight.none,
    this.acceptForReason = false,
    this.onDragStarted,
    this.onDragEnd,
    this.onSeatDropped,
    this.onPendingRiderDropped,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final Widget seatTarget = DragTarget<SeatDragData>(
      onWillAcceptWithDetails: (d) =>
          d.data.fromSeatId != seatId && (acceptForReason || _isValid),
      onAcceptWithDetails: (d) =>
          onSeatDropped?.call(d.data.fromSeatId, seatId),
      builder: (ctx, candidate, rejected) {
        Widget content = child;
        if (draggable) {
          content = LongPressDraggable<SeatDragData>(
            data: SeatDragData(seatId),
            // Short hold so a seat lifts quickly. A longer window lets early
            // finger drift inside the scrolling chart lose the gesture arena to
            // the scroll recognizer ("drag won't start"); 150ms balances that
            // against accidental lifts while scrolling.
            delay: const Duration(milliseconds: 150),
            hapticFeedbackOnStart: true,
            feedback: _SeatDragChip(label: dragLabel ?? '', seatId: seatId),
            childWhenDragging: Opacity(opacity: 0.25, child: content),
            onDragStarted: onDragStarted,
            onDragEnd: (_) => onDragEnd?.call(),
            child: content,
          );
        }
        if (!dragActive || highlight == SeatDropHighlight.none) return content;
        final hovering = candidate.isNotEmpty && _isValid;
        return _decorate(c, content, hovering);
      },
    );

    if (onPendingRiderDropped == null) return seatTarget;
    // A second, distinctly-typed drop target: a PENDING rider dragged from the
    // dock lands here regardless of whether this seat is itself draggable. The
    // caller's dragActive/highlight painting already flags which seats fit, so
    // this target only needs to receive the drop and let the caller validate.
    return DragTarget<PendingRiderDragData>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onPendingRiderDropped!(d.data.passengerId),
      builder: (ctx, candidate, rejected) => seatTarget,
    );
  }

  bool get _isValid => highlight == SeatDropHighlight.valid;

  Widget _decorate(UgamColorSet c, Widget content, bool hovering) {
    switch (highlight) {
      case SeatDropHighlight.valid:
        return AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: hovering ? 1.05 : 1.0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              content,
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.good.withValues(alpha: hovering ? 0.30 : 0.15),
                      borderRadius: BorderRadius.circular(UgamRadius.seat),
                      border: Border.all(
                        color: c.good,
                        width: hovering ? 2.5 : 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case SeatDropHighlight.blocked:
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(opacity: 0.5, child: content),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: c.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(UgamRadius.seat),
                    border: Border.all(
                      color: c.danger.withValues(alpha: 0.7),
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.lock_rounded, size: 15, color: c.danger),
                ),
              ),
            ),
          ],
        );
      case SeatDropHighlight.dim:
        return Opacity(opacity: 0.35, child: content);
      case SeatDropHighlight.none:
        return content;
    }
  }
}

/// The chip that follows the finger while dragging an occupant — seat id +
/// passenger name on a warm pill, matching the assignment workbench.
class _SeatDragChip extends StatelessWidget {
  final String label;
  final String seatId;

  const _SeatDragChip({required this.label, required this.seatId});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.warm,
          borderRadius: BorderRadius.circular(8),
          // Level 2 — the ONE thing on a seat chart that genuinely floats. It
          // rides under the finger, above every berth and the chart plane
          // itself, which is the same contract a sheet or dialog has. There is
          // exactly one of these alive at a time, so it can afford the full
          // two-layer shadow; the 74 berths behind it deliberately cast nothing
          // (see [_chairFrame]).
          //
          // Was a hand-rolled 25% black that predated the scale: identical in
          // both themes, so it was a hard smudge on Midnight's near-black
          // ground and too cold under Daylight's warm neutrals.
          boxShadow: UgamElevation.of(context).raised,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (seatId.isNotEmpty) ...[
              Text(
                seatId,
                style: UgamText.micro.copyWith(
                  color: c.onAccent.withValues(alpha: 0.85),
                  fontSize: 9,
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (label.isNotEmpty)
              Text(
                label,
                style: UgamText.bodyStrong.copyWith(
                  color: c.onAccent,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
