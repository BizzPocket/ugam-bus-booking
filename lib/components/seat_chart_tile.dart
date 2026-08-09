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
import 'seat_render.dart';

/// Canonical tile size used by every seat chart in the app so the chart reads
/// identically wherever it appears (auto-fill, assign, rearrange, handler,
/// bus status, seat detail).
///
/// Sized so a booked tile can show a fixed-size name (up to two lines) above the
/// mobile number without shrinking either to unreadable — the 2+2 sleeper grid
/// still fits a phone width at this size.
const double kSeatTileW = 68;
const double kSeatTileH = 74;

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

  /// The leg the viewer holds THIS seat for, in [anonymous] + [mine] mode. A
  /// one-way leg (GO-only / RET-only) means the customer occupies only half the
  /// seat's journey, so the tile fills just half with accent (the travelled leg)
  /// and leaves the other half neutral — a round-trip / null leg fills the whole
  /// chair as before. Never reveals the other half's occupant (privacy-safe:
  /// the empty half reads the same as any un-highlighted seat).
  final TripType? mineLeg;

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
    this.mineLeg,
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

  /// The leg to tint [p] by ON THIS cell: the per-seat [SeatAssignment.leg] via
  /// [Passenger.legForSeat], falling back to the coarse [Passenger.tripType].
  /// Per-seat so a mixed same-type booking (a GO-only seat + a RET-only seat in
  /// one request) tints each cell its own colour instead of the round-trip
  /// summary that collapsed both.
  TripType _seatLeg(Passenger p) =>
      cell.seatId == null ? p.tripType : p.legForSeat(cell.seatId!);

  /// Tile fill, with the optional price-band [bandColor] composited over the
  /// card [base] surface so a banded row reads as a faint price stripe.
  Color _fill(Color base) =>
      bandColor == null ? base : Color.alphaBlend(bandColor!, base);

  /// Small horizontal text padding inside the now-flat rounded tile. (The old
  /// chair silhouette needed a big body inset so text didn't bleed under the
  /// arms; a flat rect just needs a hair of breathing room, so the name gets
  /// nearly the full cell width.)
  double get _bodyInset => 5;

  /// The ONE chair silhouette every filled state shares: an asymmetric box with
  /// a tall back (large top radius = headrest), a shorter base (small bottom
  /// radius), and thin armrest hints down the sides. Painted WITHIN the
  /// canonical [width]×[height] box (the external footprint is unchanged), so a
  /// single/seater reads as a slim 1-seat chair while a double fills wider to
  /// read as a 2-person berth. The [child] (occupant content + badges) layers on
  /// top, clipped to the silhouette so leg-tint halves don't bleed past the arms.
  ///
  /// Replaces the old identical rounded-square `Container` in every variant; the
  /// fill / border colour / width and the inner [child] are passed through
  /// unchanged, so each state keeps its exact colours, badges and tap target.
  Widget _chairFrame({
    required UgamColorSet c,
    required Color fill,
    required Color borderColor,
    required double borderWidth,
    required Widget child,
  }) {
    // Flat, clean rounded tile (Uber/Zomato restraint) — replaces the painted
    // chair silhouette. Fill / border / child pass through unchanged, so every
    // seat state keeps its exact colours and content, just on a rounded rect.
    // Content is clipped to the same radius so split halves round their corners.
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: borderWidth > 0
            ? Border.all(color: borderColor, width: borderWidth)
            : null,
      ),
      child: child,
    );
  }

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

    // The ONE decision (which tile to draw) lives in the pure [resolveSeatRender]
    // so it is unit-tested and identical on every chart; this widget just paints
    // the resolved state. [anonymous] is handled above, so it never reaches here.
    final r = resolveSeatRender(
      cell: cell,
      occupants: occupants,
      markHalfDouble: markHalfDouble,
    );
    final Widget tile;
    final VoidCallback? onTap;
    switch (r.kind) {
      case SeatRenderKind.legShare:
        tile = _legShareTile(c, r.go!, r.ret!);
        onTap = onTapBooked;
      case SeatRenderKind.shared:
        tile = _sharedTile(c);
        onTap = onTapBooked;
      case SeatRenderKind.halfDouble:
        tile = _halfDoubleTile(c, r.primary!);
        onTap = onTapBooked;
      case SeatRenderKind.booked:
        tile = _bookedTile(c, r.primary!);
        onTap = onTapBooked;
      case SeatRenderKind.held:
        tile = _heldTile(c);
        onTap = onTapFree;
      case SeatRenderKind.quad:
        tile = _quadTile(c, r);
        onTap = onTapBooked;
      case SeatRenderKind.anonymous:
      case SeatRenderKind.free:
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
        tile,
        if (showForwardRing)
          Positioned.fill(
            // Warm forward ring on the flat rounded tile.
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(UgamRadius.seat),
                  border: Border.all(color: c.warm, width: 2),
                ),
              ),
            ),
          ),
        Positioned(
          bottom: 4,
          right: 4,
          child: Icon(Icons.tune_rounded, size: 11, color: c.ink3),
        ),
      ],
    );
  }

  // FREE — dashed ink3 hairline, transparent fill, faint glyph + seat id. When
  // the row is in a price band, a faint band stripe sits behind the dashed
  // border so even empty seats read their price tier.
  Widget _freeTile(UgamColorSet c) {
    // Flat dashed rounded tile that RECEDES — a faint outline + faint glyph so
    // booked seats visibly sit "above" empty ones and occupancy reads at a
    // glance. (Was a dashed chair silhouette; now matches the flat booked tile.)
    final content = CustomPaint(
      painter: SeatDashedBorderPainter(
        color: c.ink3.withValues(alpha: 0.4),
        radius: UgamRadius.seat,
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_seat_outlined, size: 17, color: c.ink3),
            const SizedBox(height: 4),
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
    // Band wash clipped to the tile's rounded rect so the price stripe reads
    // inside the tile, not a square behind it.
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.seat),
            child: Container(color: Color.alphaBlend(bandColor!, c.bg)),
          ),
        ),
        content,
      ],
    );
  }

  // RESERVED — dimmed fill, struck lock glyph, "Held" label.
  Widget _heldTile(UgamColorSet c) {
    return _chairFrame(
      c: c,
      fill: _fill(c.cardElev.withValues(alpha: 0.5)),
      borderColor: c.border,
      borderWidth: 1,
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

  // BOOKED — flat tile: family colour on a LEFT BAR (so families cluster
  // visually), leg by the quiet background tint, a copper priority dot, and the
  // name (fixed size, up to 2 lines) over the mobile.
  Widget _bookedTile(UgamColorSet c, Passenger p) {
    final priority = p.isPriorityApproved || cell.forward;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;

    return _chairFrame(
      c: c,
      // One-way legs are marked by the tile COLOUR alone (GO cyan / RET violet);
      // round-trip stays the plain card fill.
      fill: _fill(_legBgFill(c, _seatLeg(p)) ?? c.cardElev),
      borderColor: priority ? c.warm : c.border,
      borderWidth: priority ? 1.5 : 1,
      child: Stack(
        children: [
          if (gColor != null) _familyBar(gColor),
          Center(
            child: Padding(
              // Clear the seat code (top) + the family bar (left) so the name
              // never sits under either; a hair of side padding otherwise.
              padding: EdgeInsets.fromLTRB(
                _bodyInset + (gColor != null ? 5 : 0),
                15,
                _bodyInset,
                8,
              ),
              child: SeatOccupantLabel(
                name: p.displayName,
                phone: p.phone,
                nameColor: c.ink,
                phoneColor: c.ink2,
              ),
            ),
          ),
          _seatCodeTag(c, gColor != null),
          if (priority)
            Positioned(top: 5, right: 6, child: _dot(c.warm, 7)),
          if (moneyDotColor != null)
            Positioned(bottom: 5, right: 6, child: _dot(moneyDotColor!, 8)),
        ],
      ),
    );
  }

  /// The family colour as a rounded left bar — same colour = same booking, so
  /// families read as clusters without opening anyone. Clipped to the tile's
  /// rounded corners by [_chairFrame].
  Widget _familyBar(Color color) => Positioned(
    left: 0,
    top: 0,
    bottom: 0,
    child: Container(width: 5, color: color),
  );

  /// The seat id, top-left, nudged right when a family bar occupies the edge.
  Widget _seatCodeTag(UgamColorSet c, bool hasFamilyBar) => Positioned(
    top: 5,
    left: hasFamilyBar ? 10 : 6,
    child: Text(
      cell.seatId ?? '',
      style: UgamText.tabular(
        UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
      ),
    ),
  );

  // ANONYMOUS — privacy tile for the customer chart: a seat with the seat id
  // only, no occupant identity. Neutral card fill for OTHER seats; accent fill
  // (matching the legend "your seat" swatch) when [mine]. Reuses the canonical
  // surface + corner-id placement of [_bookedTile] so the chart reads
  // identically to the rest of the app, minus the name/phone/ring/leg/money.
  Widget _anonymousTile(UgamColorSet c) {
    // The viewer's OWN seat held for a single leg (GO-only / RET-only) fills
    // only half the chair with accent — they occupy just half the seat's
    // journey — instead of the whole chair. Round-trip / null leg stays whole.
    if (mine && (mineLeg?.isOneWay ?? false)) {
      return _anonymousHalfTile(c, mineLeg!);
    }
    final bg = mine ? c.accent : c.cardElev;
    final ringColor = mine ? c.accent : c.border;
    final idColor = mine ? c.onAccent : c.ink3;
    return _chairFrame(
      c: c,
      fill: bg,
      borderColor: ringColor,
      borderWidth: mine ? 1.5 : 1,
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

  // ANONYMOUS HALF — the viewer's own seat held for ONE leg only. The travelled
  // leg's half is filled accent (GO = top, RET = bottom, matching the app's
  // leg-share stack); the other half stays the neutral surface so the seat reads
  // "half yours". Privacy-safe: the neutral half is identical to any other seat,
  // so it never hints who (if anyone) holds the opposite leg.
  Widget _anonymousHalfTile(UgamColorSet c, TripType leg) {
    final goHalf = leg == TripType.outboundOnly;
    Widget accentHalf() => Container(
          color: c.accent,
          alignment: Alignment.center,
          child: Icon(Icons.event_seat_rounded, size: 15, color: c.onAccent),
        );
    Widget emptyHalf() => Container(
          color: c.cardElev,
          alignment: Alignment.center,
          child: Icon(Icons.event_seat_outlined, size: 15, color: c.ink3),
        );
    return _chairFrame(
      c: c,
      fill: Colors.transparent,
      borderColor: c.accent,
      borderWidth: 1.5,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(child: goHalf ? accentHalf() : emptyHalf()),
              Container(height: 1, color: c.border),
              Expanded(child: goHalf ? emptyHalf() : accentHalf()),
            ],
          ),
          Positioned(
            top: 4,
            left: 5,
            child: Text(
              cell.seatId ?? '',
              // Top half is accent for GO (onAccent id) and neutral for RET (ink id).
              style: UgamText.tabular(
                UgamText.micro.copyWith(
                  color: goHalf ? c.onAccent : c.ink3,
                  fontSize: 8,
                ),
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
    return _chairFrame(
      c: c,
      // Transparent body — the stacked GO/RET halves below carry the leg tint.
      fill: Colors.transparent,
      borderColor: priority ? c.warm : kOneWayTint.withValues(alpha: 0.7),
      borderWidth: priority ? 2 : 1.5,
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
          if (_extraOccupants > 0) _extraBadge(c, _extraOccupants),
        ],
      ),
    );
  }

  Widget _legHalf(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      // The half's COLOUR marks the leg (GO cyan / RET violet) — no text chip.
      // The tint fills the full body; the TEXT is inset to the chair-body width
      // so a leg-share name shrinks to fit instead of bleeding under the arms
      // and being clipped (the booked tile uses the same [_bodyInset]).
      color: _fill(_legBgFill(c, _seatLeg(p)) ?? c.cardElev),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _bodyInset),
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
                  nameSize: 11.5,
                  phoneSize: 8,
                  nameMaxLines: 1,
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
      ),
    );
  }

  // SHARED double — two distinct occupants STACKED top/bottom, so each gets the
  // FULL cell width for their name + mobile (far more legible than side-by-side).
  Widget _sharedTile(UgamColorSet c) {
    final a = _occ[0];
    final b = _occ[1];
    final priority =
        a.isPriorityApproved || b.isPriorityApproved || cell.forward;
    return _chairFrame(
      c: c,
      fill: c.cardElev,
      borderColor: priority ? c.warm : c.border,
      borderWidth: priority ? 1.5 : 1,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _stackedHalf(c, a)),
              Container(height: 1, color: c.border),
              Expanded(child: _stackedHalf(c, b)),
            ],
          ),
          _seatCodeTag(c, false),
          if (priority) Positioned(top: 5, right: 6, child: _dot(c.warm, 7)),
          if (moneyDotColor != null)
            Positioned(bottom: 5, right: 6, child: _dot(moneyDotColor!, 8)),
          if (_extraOccupants > 0) _extraBadge(c, _extraOccupants),
        ],
      ),
    );
  }

  /// One occupant of a STACKED double — full cell width, the leg tint as fill, a
  /// thin family bar, and the name (one line) over the mobile.
  Widget _stackedHalf(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final gColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      color: _fill(_legBgFill(c, _seatLeg(p)) ?? c.cardElev),
      child: Stack(
        children: [
          if (gColor != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 4, color: gColor),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(gColor != null ? 8 : 4, 2, 4, 2),
            child: Center(
              child: SeatOccupantLabel(
                name: p.displayName,
                phone: p.phone,
                nameColor: c.ink,
                phoneColor: c.ink2,
                nameSize: 11.5,
                phoneSize: 8.5,
                nameMaxLines: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // HALF DOUBLE — one person on a single berth of a two-berth sofa. Split tile:
  // the occupant on the left half, an EMPTY placeholder on the right so the seat
  // visibly reads "half taken, half free" instead of fully booked.
  Widget _halfDoubleTile(UgamColorSet c, Passenger p) {
    final priority = p.isPriorityApproved || cell.forward;
    final priorityBorder = priority ? c.warm : c.border;

    return _chairFrame(
      c: c,
      // Tint the WHOLE tile by the sole occupant's leg (GO cyan / RET violet),
      // exactly like _bookedTile — a one-leg double held by one rider must read
      // its single-leg colour, not the neutral round-trip fill. The empty berth
      // below keeps its own dimmed overlay so it still reads as free.
      fill: _fill(_legBgFill(c, _seatLeg(p)) ?? c.cardElev),
      borderColor: priorityBorder,
      borderWidth: priority ? 1.5 : 1,
      child: Stack(
        children: [
          // Occupant on top (full width, readable), the free berth beneath it —
          // the seat reads "half taken, half free" while the name gets full room.
          Column(
            children: [
              Expanded(child: _stackedHalf(c, p)),
              Container(height: 1, color: c.border),
              Expanded(child: _emptyHalf(c)),
            ],
          ),
          _seatCodeTag(c, false),
          if (priority) Positioned(top: 5, right: 6, child: _dot(c.warm, 7)),
          if (moneyDotColor != null)
            Positioned(bottom: 5, right: 6, child: _dot(moneyDotColor!, 8)),
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

  // QUAD — the leg grid, and the ONE tile for any Double Sofa whose two legs
  // carry different riders (1 to 4 of them). Two berths × two legs = four
  // berth-legs, so up to FOUR one-way riders fit. Draw the model's
  // GO-row-over-RET-row split ([SeatRender.quadGo] / [quadRet], each up to 2
  // side-by-side, tinted by its own leg via [_legHalf]) so ALL riders are
  // visible — instead of the old "first two names + a +N badge" that hid riders
  // 3-4 and could drop an entire leg. The "+N" badge now flags only a genuinely
  // OVER-booked leg (3+ on one leg → [SeatRender.extra]).
  //
  // A leg row with ONE rider gives them its FULL width — the sofa's spare berth
  // on that leg is not carved out beside them. An entirely free leg row is what
  // shows remaining capacity, via [_emptyHalf]. Splitting a row per berth is
  // what made a rider on a half-empty sofa look like they held a quarter of it.
  Widget _quadTile(UgamColorSet c, SeatRender r) {
    final priority = cell.forward || _occ.any((p) => p.isPriorityApproved);
    Widget legRow(List<Passenger> riders) {
      if (riders.isEmpty) return _emptyHalf(c);
      return Row(
        children: [
          for (var i = 0; i < riders.length; i++) ...[
            if (i > 0) Container(width: 1, color: c.border),
            Expanded(child: _legHalf(c, riders[i])),
          ],
        ],
      );
    }

    return _chairFrame(
      c: c,
      // Transparent body — the GO/RET rows below carry the leg tint.
      fill: Colors.transparent,
      borderColor: priority ? c.warm : kOneWayTint.withValues(alpha: 0.7),
      borderWidth: priority ? 2 : 1.5,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(child: legRow(r.quadGo)), // GO riders (top)
              Container(height: 1, color: c.border),
              Expanded(child: legRow(r.quadRet)), // RET riders (bottom)
            ],
          ),
          _seatCodeTag(c, false),
          if (priority) Positioned(top: 5, right: 6, child: _dot(c.warm, 7)),
          if (moneyDotColor != null)
            Positioned(bottom: 5, right: 6, child: _dot(moneyDotColor!, 8)),
          if (r.extra > 0) _extraBadge(c, r.extra),
        ],
      ),
    );
  }

  /// A small "+N" pill (bottom-left) flagging riders the tile can't draw — see
  /// [_extraOccupants]. Bottom-left keeps it clear of the seat id (top-left),
  /// the priority dot (top-right) and the money dot (bottom-right).
  Widget _extraBadge(UgamColorSet c, int n) => Positioned(
    bottom: 3,
    left: 4,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: c.ink.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(
        '+$n',
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

/// The shared chair silhouette geometry, computed once for a tile [Size] so the
/// painter, the clipper and the dashed FREE border all draw the identical body.
///
/// The silhouette lives INSIDE the canonical tile box (the external footprint is
/// unchanged): a tall back with a large top radius (the headrest) and a shorter
/// base with a small bottom radius (the seat base). A [isDouble] berth fills the
/// box edge-to-edge to read as a 2-person bench; a single/seater insets its body
/// horizontally so it reads as a slimmer 1-person chair.
class _SeatShape {
  /// Doubles fill wider; singles/seaters inset so a 2-person berth is visibly
  /// bigger than a 1-person seat.
  final bool isDouble;

  const _SeatShape({required this.isDouble});

  /// Horizontal inset of the chair BODY from the tile edge. A double keeps a
  /// hair of inset (so its arms still read); a single insets a touch MORE so it
  /// reads slightly narrower than the double's berth — but only ~10% (was 16%),
  /// because a deeper inset shrank the body below the width an occupant name
  /// needs and the name was hard-clipped to a middle slice by the body ClipPath.
  double _sideInset(Size s) => (isDouble ? 0.06 : 0.10) * s.width;

  /// The rounded chair-body path: large top radius (back/headrest), small bottom
  /// radius (base). This is the clip + fill region every variant shares.
  Path bodyPath(Size s) {
    final inset = _sideInset(s);
    final rect = Rect.fromLTRB(inset, 0, s.width - inset, s.height);
    final topR = Radius.circular(s.height * 0.30); // back / headrest curve
    final botR = Radius.circular(s.height * 0.14); // shorter seat base
    return Path()
      ..addRRect(RRect.fromRectAndCorners(
        rect,
        topLeft: topR,
        topRight: topR,
        bottomLeft: botR,
        bottomRight: botR,
      ));
  }
}

/// Paints a dashed rounded-rectangle border for the FREE tile. Public so the
/// chart legend can reuse the exact same dashed swatch.
class SeatDashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  /// When non-null, dash the shared CHAIR silhouette instead of the plain
  /// rounded rect — the FREE tile passes `false` for a single/seater chair and
  /// `true` for a (wider) double berth, so an empty seat reads as the same chair
  /// outline as a filled one. Null (the legend's swatch) keeps the original
  /// dashed rounded-rectangle unchanged.
  final bool? chairIsDouble;

  SeatDashedBorderPainter({
    required this.color,
    required this.radius,
    this.chairIsDouble,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final Path path;
    if (chairIsDouble != null) {
      path = _SeatShape(isDouble: chairIsDouble!).bodyPath(size);
    } else {
      final rrect = RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(radius),
      );
      path = Path()..addRRect(rrect);
    }
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
      old.color != color ||
      old.radius != radius ||
      old.chairIsDouble != chairIsDouble;
}
