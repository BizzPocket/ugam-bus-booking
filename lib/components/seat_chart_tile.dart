import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/trip_type.dart';
import '../utils/passenger_display.dart';
import '../widgets/seat_occupant_label.dart';

/// Canonical tile size used by every seat chart in the app so the chart reads
/// identically wherever it appears (auto-fill, assign, rearrange, handler,
/// bus status, seat detail).
const double kSeatTileW = 60;
const double kSeatTileH = 60;

/// The ONE seat tile used across the whole app.
///
/// This is the "auto-fill" chart look — the locked, final design — extracted so
/// every screen renders the same chart instead of each keeping its own copy.
/// The grid placement is owned by [CombinedSeatGrid]; this widget owns *only*
/// the appearance of a single [SeatCell] plus its tap. Screens layer their own
/// drag/drop or selection behaviour OUTSIDE the tile (it stays purely visual).
///
/// States:
///   * FREE        — dashed ink3 hairline, transparent fill, faint glyph + id.
///   * RESERVED    — dimmed card fill, struck lock glyph, "Held" label.
///   * BOOKED      — occupant initials/name on a card fill. A deterministic
///     group-colour RING (via [groupColors]) when grouped; a WARM ring + star
///     when priority/forward; a one-way corner + "GO"/"RET" pill when the
///     occupant travels a single leg (GO cyan [kOneWayTint]; RET violet
///     [kReturnTint] only under [emphasizeOneWay] — the handler view — else cyan).
///   * SHARED double — two unrelated passengers on one `doubleSofa` seatId,
///     split left/right.
///   * LEG-SHARED  — a GO (outbound-only) holder and a RET (return-only) holder
///     reusing the same physical seat across disjoint legs, stacked GO/RET.
///
/// [moneyDotColor], when non-null, draws a small collection-state dot in the
/// bottom-right corner — the handler chart's one addition over the base look.
class SeatChartTile extends StatelessWidget {
  final SeatCell cell;
  final List<Passenger> occupants;

  /// Resolves a [Passenger.groupId] to its ring colour (infinite golden-angle
  /// generator, stable per group).
  final GroupColorResolver groupColors;

  final double width;
  final double height;

  final VoidCallback? onTapBooked;
  final VoidCallback? onTapFree;

  /// When true the tile draws a small edit affordance and an empty seat in the
  /// forward zone still gets a warm ring so the agent sees the flag take.
  final bool editMode;

  /// Optional handler-only collection-state dot (bottom-right). Null hides it.
  final Color? moneyDotColor;

  /// Optional price-band WASH colour for this seat's row — already at
  /// [kPriceBandWashAlpha] (see `priceBandWash`). When non-null it is composited
  /// over the tile fill so the row reads as a faint price stripe; the group /
  /// priority ring and trip tint still render on top. Null = no band wash.
  final Color? bandColor;

  /// When true, the tile applies the HANDLER's one-way emphasis: the RETURN leg
  /// renders in its distinct violet [kReturnTint] (instead of sharing the GO
  /// cyan), and one-way leg pills carry a "½" half-fare marker so the handler
  /// sees at a glance that the seat pays HALF fare. Handler chart only; the agent
  /// charts leave it off, so there a one-way leg stays plain cyan with no ½.
  final bool emphasizeOneWay;

  const SeatChartTile({
    super.key,
    required this.cell,
    required this.occupants,
    required this.groupColors,
    this.width = kSeatTileW,
    this.height = kSeatTileH,
    this.onTapBooked,
    this.onTapFree,
    this.editMode = false,
    this.moneyDotColor,
    this.bandColor,
    this.emphasizeOneWay = false,
  });

  /// Occupants deduped by passenger id. A WHOLE double held by one person
  /// arrives as that passenger twice (two seat assignments on the same seatId);
  /// left raw it renders as a shared split with the name repeated. Collapsing to
  /// unique ids makes a one-person double show a SINGLE name, while a genuine
  /// shared sofa (two different people) still keeps both halves. Order preserved
  /// so a shared sofa's left/right stays stable.
  List<Passenger> get _occ {
    if (occupants.length < 2) return occupants;
    final seen = <String>{};
    final out = <Passenger>[];
    for (final p in occupants) {
      if (seen.add(p.id)) out.add(p);
    }
    return out;
  }

  bool get _isBooked => _occ.isNotEmpty;

  /// A genuine SHARED-double split: two DISTINCT passengers on one seatId that
  /// is NOT a clean disjoint GO/RETURN leg reuse. Leg reuse is rendered by the
  /// leg-aware path instead.
  bool get _isShared => _occ.length > 1 && _legShare == null;

  /// When this seat is reused across disjoint legs — exactly one outbound-only
  /// GO holder and one return-only RETURN holder — returns that pair. Otherwise
  /// null. A round-trip occupant holds BOTH legs exclusively, so its presence
  /// rules out leg reuse.
  ({Passenger go, Passenger ret})? get _legShare {
    if (_occ.length != 2) return null;
    final a = _occ[0];
    final b = _occ[1];
    if (a.tripType == TripType.outboundOnly &&
        b.tripType == TripType.returnOnly) {
      return (go: a, ret: b);
    }
    if (a.tripType == TripType.returnOnly &&
        b.tripType == TripType.outboundOnly) {
      return (go: b, ret: a);
    }
    return null;
  }

  static String initials(String displayName) {
    final n = displayName.trim();
    if (n.isEmpty) return '?';
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  /// Short leg badge for a one-way occupant: "GO" (outbound-only) or "RET"
  /// (return-only). Null for round-trip (no badge).
  static String? legBadge(TripType t) {
    switch (t) {
      case TripType.outboundOnly:
        return 'GO';
      case TripType.returnOnly:
        return 'RET';
      case TripType.roundTrip:
        return null;
    }
  }

  /// Soft BACKGROUND fill marking a one-way leg by colour instead of a chip:
  /// GO (outbound-only) reads cyan [kOneWayTint], RET (return-only) reads violet
  /// [kReturnTint] — always distinct. Composited over the card surface so the
  /// occupant text stays readable. Null for round-trip (plain card fill).
  Color? _legBgFill(UgamColorSet c, TripType t) {
    switch (t) {
      case TripType.outboundOnly:
        return Color.alphaBlend(
            kOneWayTint.withValues(alpha: 0.22), c.cardElev);
      case TripType.returnOnly:
        return Color.alphaBlend(
            kReturnTint.withValues(alpha: 0.22), c.cardElev);
      case TripType.roundTrip:
        return null;
    }
  }

  /// Tile fill, with the optional price-band [bandColor] composited over the
  /// card [base] surface so a banded row reads as a faint price stripe.
  Color _fill(Color base) =>
      bandColor == null ? base : Color.alphaBlend(bandColor!, base);

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final legShare = _legShare;
    final Widget tile;
    final VoidCallback? onTap;
    if (legShare != null) {
      tile = _legShareTile(c, legShare.go, legShare.ret);
      onTap = onTapBooked;
    } else if (_isShared) {
      tile = _sharedTile(c);
      onTap = onTapBooked;
    } else if (_isBooked) {
      tile = _bookedTile(c, _occ.first);
      onTap = onTapBooked;
    } else if (cell.reserved) {
      tile = _heldTile(c);
      onTap = onTapFree;
    } else {
      tile = _freeTile(c);
      onTap = onTapFree;
    }

    final rendered = editMode ? _withEditAffordance(c, tile) : tile;
    if (onTap == null) return rendered;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: rendered,
    );
  }

  /// In edit mode, overlay a tiny tune glyph and (for an empty forward seat) a
  /// warm ring so toggling a flag is visibly reflected on every seat state.
  Widget _withEditAffordance(UgamColorSet c, Widget tile) {
    final showForwardRing = !_isBooked && cell.forward;
    return Stack(
      children: [
        if (showForwardRing)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(UgamRadius.seat),
                border: Border.all(color: c.warm, width: 2),
              ),
            ),
          ),
        tile,
        Positioned(
          bottom: 3,
          right: 3,
          child: Icon(Icons.tune_rounded, size: 11, color: c.ink3),
        ),
      ],
    );
  }

  // FREE — dashed ink3 hairline, transparent fill, faint glyph + seat id. When
  // the row is in a price band, a faint band stripe sits behind the dashed
  // border so even empty seats read their price tier.
  Widget _freeTile(UgamColorSet c) {
    final content = CustomPaint(
      painter: SeatDashedBorderPainter(
        color: c.ink3.withValues(alpha: 0.55),
        radius: UgamRadius.seat,
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_seat_outlined, size: 16, color: c.ink3),
            const SizedBox(height: 3),
            Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 9.5),
              ),
            ),
          ],
        ),
      ),
    );
    if (bandColor == null) return content;
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: Color.alphaBlend(bandColor!, c.bg),
              borderRadius: BorderRadius.circular(UgamRadius.seat),
            ),
          ),
        ),
        content,
      ],
    );
  }

  // RESERVED — dimmed fill, struck lock glyph, "Held" label.
  Widget _heldTile(UgamColorSet c) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _fill(c.cardElev.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: c.ink3),
          const SizedBox(height: 3),
          Text(
            tr('seat_ui.held'),
            style: UgamText.micro.copyWith(
              color: c.ink3,
              decoration: TextDecoration.lineThrough,
              decorationColor: c.ink3,
            ),
          ),
        ],
      ),
    );
  }

  // BOOKED — initials on card fill; group ring + warm priority ring/badge.
  Widget _bookedTile(UgamColorSet c, Passenger p) {
    final priority = p.isPriorityApproved || cell.forward;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;

    final Color ringColor;
    final double ringWidth;
    if (priority) {
      ringColor = c.warm;
      ringWidth = 2;
    } else if (gColor != null) {
      ringColor = gColor;
      ringWidth = 2;
    } else {
      ringColor = c.border;
      ringWidth = 1;
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        // One-way legs are now marked by the TILE COLOUR (GO cyan / RET violet)
        // instead of a corner + chip; round-trip stays the plain card fill.
        color: _fill(_legBgFill(c, p.tripType) ?? c.cardElev),
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: ringColor, width: ringWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(3, 12, 3, 6),
              child: SeatOccupantLabel(
                name: p.displayName,
                phone: p.phone,
                nameColor: c.ink,
                phoneColor: c.ink2,
              ),
            ),
          ),
          Positioned(
            top: 4,
            left: 5,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
              ),
            ),
          ),
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            ),
          if (priority && gColor != null)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  color: gColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          if (moneyDotColor != null)
            Positioned(bottom: 4, right: 4, child: _dot(moneyDotColor!, 8)),
        ],
      ),
    );
  }

  // LEG-SHARED — one GO holder + one RETURN holder reuse the same physical seat
  // across disjoint legs. Stacked top (GO) / bottom (RET).
  Widget _legShareTile(UgamColorSet c, Passenger go, Passenger ret) {
    final priority =
        go.isPriorityApproved || ret.isPriorityApproved || cell.forward;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(
          color: priority ? c.warm : kOneWayTint.withValues(alpha: 0.7),
          width: priority ? 2 : 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _legHalf(c, go)),
              Container(height: 1, color: c.border),
              Expanded(child: _legHalf(c, ret)),
            ],
          ),
          Positioned(
            top: 3,
            left: 4,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 7.5),
              ),
            ),
          ),
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 11, color: c.warm),
            ),
          if (moneyDotColor != null)
            Positioned(bottom: 3, right: 4, child: _dot(moneyDotColor!, 7)),
        ],
      ),
    );
  }

  Widget _legHalf(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      // The half's COLOUR marks the leg (GO cyan / RET violet) — no chip.
      color: _fill(_legBgFill(c, p.tripType) ?? c.cardElev),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SeatOccupantLabel(
              name: p.displayName,
              phone: p.phone,
              nameColor: c.ink,
              phoneColor: c.ink2,
              nameSize: 11,
              phoneSize: 8,
            ),
          ),
          if (gColor != null) ...[
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: gColor, shape: BoxShape.circle),
            ),
          ],
        ],
      ),
    );
  }

  // SHARED double — split left/right, both (distinct) occupants.
  Widget _sharedTile(UgamColorSet c) {
    final a = _occ[0];
    final b = _occ[1];
    final priority =
        a.isPriorityApproved || b.isPriorityApproved || cell.forward;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(
          color: priority ? c.warm : c.border,
          width: priority ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(child: _half(c, a)),
              Container(width: 1, color: c.border),
              Expanded(child: _half(c, b)),
            ],
          ),
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                cell.seatId ?? '',
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
                ),
              ),
            ),
          ),
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            ),
          if (moneyDotColor != null)
            Positioned(bottom: 4, right: 4, child: _dot(moneyDotColor!, 8)),
        ],
      ),
    );
  }

  Widget _half(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      // A one-way occupant's half is tinted by leg (GO cyan / RET violet); the
      // chip is gone. Round-trip stays the plain card fill.
      color: _fill(_legBgFill(c, p.tripType) ?? c.cardElev),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 12, 2, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Shared sofa: two people on one half-width tile — a name AND a
            // mobile won't both fit, so each half shows the NAME only. The
            // mobile is one tap away (the occupant action sheet).
            SeatOccupantLabel(
              name: p.displayName,
              phone: null,
              nameColor: c.ink,
              phoneColor: c.ink2,
              nameSize: 12,
              phoneSize: 8,
            ),
            if (gColor != null) ...[
              const SizedBox(height: 3),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: gColor,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _dot(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

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
        half ? '$label ½' : label,
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
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return DragTarget<SeatDragData>(
      onWillAcceptWithDetails: (d) =>
          d.data.fromSeatId != seatId && (acceptForReason || _isValid),
      onAcceptWithDetails: (d) =>
          onSeatDropped?.call(d.data.fromSeatId, seatId),
      builder: (ctx, candidate, rejected) {
        Widget content = child;
        if (draggable) {
          content = LongPressDraggable<SeatDragData>(
            data: SeatDragData(seatId),
            delay: const Duration(milliseconds: 220),
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
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              offset: Offset(0, 4),
              blurRadius: 12,
            ),
          ],
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

/// Paints a dashed rounded-rectangle border for the FREE tile. Public so the
/// chart legend can reuse the exact same dashed swatch.
class SeatDashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  SeatDashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
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
      old.color != color || old.radius != radius;
}
