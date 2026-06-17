import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
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
///     when priority/forward. A one-way leg is marked by tile COLOUR alone
///     (GO cyan [kOneWayTint]; RET violet [kReturnTint]) — no "GO"/"RET" chip.
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

  /// When true, a Double Sofa holding only ONE of its two berths renders as a
  /// split tile (occupant + empty placeholder) instead of a fully-booked tile,
  /// so a half-taken sofa never reads as full. Requires [occupants] to be
  /// BERTH-ACCURATE — one entry per assignment, so a whole double held solo
  /// arrives as the passenger twice. Charts that pass a leg-DEDUPED occupant
  /// list (e.g. the handler manifest, where a round-trip whole double is a
  /// single `sole` entry) MUST leave this off, else a whole double would be
  /// mistaken for a half-share. Off by default.
  final bool markHalfDouble;

  /// PRIVACY mode for the customer-facing chart. When true the tile keeps the
  /// canonical look (size, seat id in the corner, rounded surface) but NEVER
  /// shows occupant identity: every seat renders as a neutral anonymous fill
  /// with the seat id only — no name, phone, group ring, leg tint or money dot,
  /// so the customer cannot learn who (or whether anyone) is on each seat.
  /// [occupants] is ignored in this mode (callers pass an empty list).
  ///
  /// Pair with [mine] to highlight the viewer's OWN seats: an anonymous tile
  /// that is [mine] fills with the accent colour ([UgamColorSet.accent] /
  /// [UgamColorSet.onAccent]) instead of the neutral surface. Off by default so
  /// every existing (admin/handler) caller is untouched.
  final bool anonymous;

  /// Highlights this seat as the viewer's own (accent fill) in [anonymous] mode.
  /// Ignored unless [anonymous] is true. Off by default.
  final bool mine;

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
    this.markHalfDouble = false,
    this.anonymous = false,
    this.mine = false,
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

  /// A genuine SHARED-double split: two DISTINCT passengers sitting side-by-side
  /// on one seatId that is NOT a clean disjoint GO/RETURN leg reuse. Leg reuse
  /// is rendered by the leg-aware path instead.
  ///
  /// Gated to [SeatType.doubleSofa]: a side-by-side split is only physically
  /// meaningful for a TWO-berth sofa. A SINGLE sofa is one berth — it can only
  /// ever be held by one person, or REUSED across disjoint legs (one GO + one
  /// RET), which is the stacked leg-share tile, never a same-time side split. So
  /// a single (or seater) cell never renders the split share even if stale data
  /// somehow lists two same-leg holders; it falls through to the leg-share or
  /// single booked tile, keeping "a single sofa is one person per leg" true on
  /// screen.
  bool get _isShared =>
      cell.seatType == SeatType.doubleSofa &&
      _occ.length > 1 &&
      _legShare == null;

  /// A HALF-occupied Double Sofa: one person holding a SINGLE berth of a
  /// two-berth sofa (a single-on-double / half-share), so the other berth is
  /// still free. Detected by the RAW berth count — a WHOLE double held solo
  /// arrives as the same passenger twice ([occupants].length == 2), while a
  /// half-share is a single berth entry ([occupants].length == 1). Rendered as
  /// a split tile: the occupant on one half, an empty placeholder on the other,
  /// so the chart never reads a half-taken sofa as fully booked.
  bool get _isHalfDouble =>
      markHalfDouble &&
      cell.seatType == SeatType.doubleSofa &&
      _occ.length == 1 &&
      occupants.length == 1;

  /// Free physical berths still bookable on this Double Sofa, under the
  /// leg-aware capacity model (a seat = its BUSIER leg, so berths used =
  /// max(GO, RET) — see project seat-leg-counting). Counts RAW berth entries:
  /// a whole double held solo is the same passenger twice; a round-trip berth
  /// consumes BOTH legs. Returns 0 for non-doubles and whenever [markHalfDouble]
  /// is off (leg-DEDUPED charts can't count berths, so they must never split).
  ///
  /// A GO-only + RET-only leg-share is one berth's worth (go=1, ret=1 →
  /// max=1 → one berth free), so it still has a half to draw empty — the case
  /// that previously read as a fully-booked leg-share.
  int get _freeDoubleBerths {
    if (!markHalfDouble || cell.seatType != SeatType.doubleSofa) return 0;
    var go = 0, ret = 0;
    for (final p in occupants) {
      switch (p.tripType) {
        case TripType.outboundOnly:
          go++;
        case TripType.returnOnly:
          ret++;
        case TripType.roundTrip:
          go++;
          ret++;
      }
    }
    final used = go > ret ? go : ret;
    final free = 2 - used;
    return free < 0 ? 0 : free;
  }

  /// Riders BEYOND the two the tile can draw. A Double Sofa is two berths, each
  /// reusable across legs, so up to four distinct one-way riders can share it;
  /// the tile only ever shows two (a shared split or a GO/RET stack), so a
  /// small "+N" badge flags the rest — the full roster is one tap away in the
  /// occupant sheet. Zero for non-doubles and for two-or-fewer riders.
  int get _extraOccupants {
    if (cell.seatType != SeatType.doubleSofa) return 0;
    final extra = _occ.length - 2;
    return extra > 0 ? extra : 0;
  }

  /// When this seat is reused across disjoint legs — an outbound-only GO holder
  /// AND a return-only RETURN holder — returns that pair (GO first). Otherwise
  /// null. A round-trip occupant holds BOTH legs exclusively, so a pair of
  /// round-trips (or any same-leg pair) is NOT a leg reuse and returns null.
  ///
  /// Tolerant of a stray extra occupant: it scans for the FIRST outbound-only
  /// and FIRST return-only holder rather than requiring exactly two entries, so
  /// a legitimate GO/RET reuse on a single sofa still resolves cleanly even if
  /// an over-capacity stale berth (the kind that inflates a "38/37" tally) also
  /// lists a third holder. The leg-share is what the seat actually IS; the extra
  /// is dropped from view.
  ({Passenger go, Passenger ret})? get _legShare {
    if (_occ.length < 2) return null;
    Passenger? go;
    Passenger? ret;
    for (final p in _occ) {
      if (p.tripType == TripType.outboundOnly) {
        go ??= p;
      } else if (p.tripType == TripType.returnOnly) {
        ret ??= p;
      }
    }
    if (go != null && ret != null) return (go: go, ret: ret);
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

    // PRIVACY path: the customer chart shows only WHERE seats are, never WHO.
    // Every seat reads as the same neutral (or accent, if [mine]) anonymous
    // tile with the seat id alone — the customer has no booked/free signal and
    // must not learn one. None of the identity / leg / money branches below run,
    // and [occupants] is ignored (callers pass an empty list).
    if (anonymous) {
      final tile = _anonymousTile(c);
      if (onTapBooked == null) return tile;
      return GestureDetector(
        onTap: onTapBooked,
        behavior: HitTestBehavior.opaque,
        child: tile,
      );
    }

    final legShare = _legShare;
    final hasFreeHalf = _freeDoubleBerths >= 1;
    final Widget tile;
    final VoidCallback? onTap;
    if (legShare != null) {
      // A GO+RET leg-share on a DOUBLE only consumes one berth's worth of
      // capacity (max(GO,RET) == 1), so the other berth is still bookable —
      // draw that half empty instead of reading the whole sofa as full. On a
      // SINGLE sofa the same reuse fills the one berth, so [hasFreeHalf] is
      // false there (the getter is doubleSofa-only) and it stays a full tile.
      tile = hasFreeHalf
          ? _legShareHalfTile(c, legShare.go, legShare.ret)
          : _legShareTile(c, legShare.go, legShare.ret);
      onTap = onTapBooked;
    } else if (_isShared) {
      tile = _sharedTile(c);
      onTap = onTapBooked;
    } else if (_isHalfDouble) {
      tile = _halfDoubleTile(c, _occ.first);
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
        // One-way legs are marked by the tile COLOUR alone (GO cyan / RET
        // violet); round-trip stays the plain card fill. No "GO"/"RET" text
        // chip — the colour already says the leg, and the chip just cluttered
        // tiles that also carry a name + mobile.
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

  // ANONYMOUS — privacy tile for the customer chart: a seat with the seat id
  // only, no occupant identity. Neutral card fill for OTHER seats; accent fill
  // (matching the legend "your seat" swatch) when [mine]. Reuses the canonical
  // surface + corner-id placement of [_bookedTile] so the chart reads
  // identically to the rest of the app, minus the name/phone/ring/leg/money.
  Widget _anonymousTile(UgamColorSet c) {
    final bg = mine ? c.accent : c.cardElev;
    final ringColor = mine ? c.accent : c.border;
    final idColor = mine ? c.onAccent : c.ink3;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: ringColor, width: mine ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: Icon(
              Icons.event_seat_rounded,
              size: 16,
              color: mine ? c.onAccent : c.ink3,
            ),
          ),
          Positioned(
            top: 4,
            left: 5,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: idColor, fontSize: 8),
              ),
            ),
          ),
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
          if (_extraOccupants > 0) _extraBadge(c),
        ],
      ),
    );
  }

  // LEG-SHARED on a DOUBLE that still has a free berth — the GO/RET reuse
  // occupies ONE berth (stacked GO over RET on the left), the other berth shows
  // an EMPTY placeholder on the right so the sofa reads "half taken, half free"
  // rather than fully booked. Mirrors [_halfDoubleTile]'s split, but the filled
  // half is the leg-reuse pair instead of a single occupant.
  Widget _legShareHalfTile(UgamColorSet c, Passenger go, Passenger ret) {
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
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: _legHalf(c, go)),
                    Container(height: 1, color: c.border),
                    Expanded(child: _legHalf(c, ret)),
                  ],
                ),
              ),
              Container(width: 1, color: c.border),
              Expanded(child: _emptyHalf(c)),
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
          if (_extraOccupants > 0) _extraBadge(c),
        ],
      ),
    );
  }

  Widget _legHalf(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      // The half's COLOUR marks the leg (GO cyan / RET violet) — no text chip.
      color: _fill(_legBgFill(c, p.tripType) ?? c.cardElev),
      child: Center(
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
                nameSize: 12.5,
                phoneSize: 8,
              ),
            ),
            if (gColor != null) ...[
              const SizedBox(width: 4),
              Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: gColor, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
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
          if (_extraOccupants > 0) _extraBadge(c),
        ],
      ),
    );
  }

  Widget _half(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      // A one-way occupant's half is tinted by leg (GO cyan / RET violet) — the
      // colour alone marks the leg, no text chip. Round-trip stays plain fill.
      color: _fill(_legBgFill(c, p.tripType) ?? c.cardElev),
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
              nameSize: 13,
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

  // HALF DOUBLE — one person on a single berth of a two-berth sofa. Split tile:
  // the occupant on the left half, an EMPTY placeholder on the right so the seat
  // visibly reads "half taken, half free" instead of fully booked.
  Widget _halfDoubleTile(UgamColorSet c, Passenger p) {
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
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: ringColor, width: ringWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(child: _half(c, p)),
              Container(width: 1, color: c.border),
              Expanded(child: _emptyHalf(c)),
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

  /// The free half of a half-occupied Double Sofa — a faint seat glyph on the
  /// dimmed surface so the empty berth reads as "available".
  Widget _emptyHalf(UgamColorSet c) {
    return Container(
      color: c.cardElev.withValues(alpha: 0.4),
      alignment: Alignment.center,
      child: Icon(Icons.event_seat_outlined, size: 16, color: c.ink3),
    );
  }

  /// A small "+N" pill (bottom-left) flagging riders the tile can't draw — see
  /// [_extraOccupants]. Bottom-left keeps it clear of the seat id (top-left),
  /// the priority star (top-right) and the money dot (bottom-right).
  Widget _extraBadge(UgamColorSet c) => Positioned(
    bottom: 3,
    left: 4,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: c.ink.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(
        '+$_extraOccupants',
        style: UgamText.micro.copyWith(
          color: c.onAccent,
          fontSize: 7.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );

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
