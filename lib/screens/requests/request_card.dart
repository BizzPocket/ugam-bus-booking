part of '../requests_screen.dart';

// ─── Passenger card ───────────────────────────────────────────────────

class _RequestCard extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final UgamColorSet c;
  final bool selectionMode;
  final bool selected;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onLongPress;
  final VoidCallback onSelectTap;

  const _RequestCard({
    required this.passenger,
    required this.tour,
    required this.c,
    required this.selectionMode,
    required this.selected,
    required this.expanded,
    required this.onToggleExpand,
    required this.onLongPress,
    required this.onSelectTap,
  });

  /// Initials for the leading disc — one glyph per name word, max two.
  /// Built from runes, not `[0]`, so a Gujarati or Devanagari name yields its
  /// real first character instead of half a code point.
  String get _initials {
    final parts = passenger.displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final first = String.fromCharCode(parts.first.runes.first);
    if (parts.length == 1) return first.toUpperCase();
    return '$first${String.fromCharCode(parts[1].runes.first)}'.toUpperCase();
  }

  /// New or waitlisted, not yet seated, no pending cancellation — the rows
  /// whose positive move is "Confirm & seat" (same gate as the right swipe).
  bool get _canQuickConfirm =>
      !passenger.isConfirmed &&
      !passenger.isFullyAssigned &&
      !passenger.isCancelRequested;

  /// The cross-booking group this rider belongs to, if any.
  PassengerGroup? get _group => passenger.groupId == null
      ? null
      : tour.groups.firstWhereOrNull((g) => g.id == passenger.groupId);

  bool get _hasPickup =>
      passenger.pickupLocationName != null &&
      passenger.pickupLocationName!.isNotEmpty;

  bool get _hasNote => passenger.note != null && passenger.note!.isNotEmpty;

  /// The row's state as ONE chip label + variant.
  ///
  /// State used to be encoded by painting the seat-summary subtitle amber,
  /// which broke the accent's "this is yours" contract (V-09) AND left New /
  /// Accepted / Allotted rows structurally identical — 48 of them in a column
  /// with nothing but the words to tell them apart. Colour now lives on the
  /// chip and the leading disc; the subtitle drops to plain secondary ink.
  ///
  /// Labels reuse the tab vocabulary (`requests.filter.*`) on purpose: those
  /// strings are already length-tuned to survive four abreast in Gujarati, so
  /// they can never blow out the row's right cluster.
  (String, UgamChipVariant) get _status {
    if (passenger.isCancelRequested) {
      // Warm, matching the full "cancellation requested" chip the expanded
      // body already renders — one state, one colour.
      return (tr('requests.status.cancel_short'), UgamChipVariant.warm);
    }
    if (passenger.isFullyAssigned) {
      return (tr('requests.filter.assigned'), UgamChipVariant.good);
    }
    if (passenger.isPartiallyAssigned) {
      return (tr('requests.status.partial'), UgamChipVariant.warm);
    }
    if (passenger.isConfirmed) {
      return (tr('requests.filter.confirmed'), UgamChipVariant.good);
    }
    if (passenger.isWaitlisted) {
      return (tr('requests.filter.waitlist'), UgamChipVariant.warm);
    }
    return (tr('requests.filter.new'), UgamChipVariant.neutral);
  }

  /// (fill, ink) for a chip variant. The leading disc wears the same pair the
  /// status chip does, so one glance down the left rail reads every row's
  /// state without reading a single word.
  (Color, Color) _tonal(UgamChipVariant v) => switch (v) {
        UgamChipVariant.accent => (c.accentFill, c.accent),
        UgamChipVariant.warm => (c.warmFill, c.warm),
        UgamChipVariant.good => (c.goodFill, c.good),
        UgamChipVariant.danger => (c.dangerFill, c.danger),
        UgamChipVariant.neutral => (c.cardElev, c.ink2),
      };

  /// Leading disc: the passenger's initials normally, the selection check
  /// while multi-selecting. Both are the same diameter so entering selection
  /// swaps the glyph without reflowing the row. Decorative (the whole card is
  /// the tap target), hence [UgamScale.px] rather than `tap`.
  Widget _leadingDisc(BuildContext context, UgamChipVariant variant) {
    final double d = UgamScale.px(context, 38);
    if (selectionMode) {
      return Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          // Tonal, not a solid accent disc: selecting five rows used to put
          // six solid coppers on screen (five discs + the bulk bar's
          // Confirm), so the bar's Confirm — the one action the bar exists
          // for — stopped being the eye's landing point.
          color: selected ? c.accentFill : c.cardElev,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? c.accent : c.border,
            width: 1.5,
          ),
        ),
        alignment: Alignment.center,
        child: selected
            ? Icon(
                Icons.check_rounded,
                size: UgamScale.px(context, 18),
                color: c.accent,
              )
            : null,
      );
    }
    final (bg, fg) = _tonal(variant);
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xs),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          _initials,
          maxLines: 1,
          style: UgamText.bodyStrong.copyWith(color: fg),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) {
      return tr('requests.time.days_ago', namedArgs: {'n': '${diff.inDays}'});
    }
    if (diff.inHours > 0) {
      return tr('requests.time.hours_ago', namedArgs: {'n': '${diff.inHours}'});
    }
    if (diff.inMinutes > 0) {
      return tr(
        'requests.time.minutes_ago',
        namedArgs: {'n': '${diff.inMinutes}'},
      );
    }
    return tr('requests.time.just_now');
  }

  /// "BUS 1 · L3, L4" chips — one per bus this passenger holds berths on, so
  /// the agent sees WHERE someone is seated without opening the assignment.
  /// Seat IDs are deduped because a whole double sofa books one seatId twice.
  List<Widget> _assignedSeatChips() {
    if (passenger.assignedSeats.isEmpty) return const [];
    final byBus = <String, List<String>>{};
    for (final a in passenger.assignedSeats) {
      final list = byBus.putIfAbsent(a.busId, () => <String>[]);
      if (!list.contains(a.seatId)) list.add(a.seatId);
    }
    final chips = <Widget>[];
    byBus.forEach((busId, seats) {
      final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
      final busName = bus?.name ?? tr('requests.assigned.bus_fallback');
      chips.add(
        UgamReqChip(
          label: '$busName · ${seats.join(', ')}'.toUpperCase(),
          variant: UgamChipVariant.good,
        ),
      );
    });
    return chips;
  }

  /// Plural-free collapsed summary: "1/2 · Double Sofa + Seater" (or "2 · …").
  /// Uses plain interpolation — NEVER plural() — so it is safe in the test
  /// harness and stays a single scannable line.
  String _seatSummary() {
    if (passenger.requestLines.isEmpty) return '';
    final types = passenger.requestLines.map((l) => l.label).join(' + ');
    return '${_seatCount()} · $types';
  }

  /// "assigned/berths" while partially seated, else just the berth count.
  String _seatCount() => passenger.isPartiallyAssigned
      ? '${passenger.totalSeatsAssigned}/${passenger.seatBerths}'
      : '${passenger.seatBerths}';

  /// Small Material-icon strip on the collapsed row's second line. STRICTLY
  /// Icons.* glyphs tinted with tokens — no emoji. One icon per active flag,
  /// mirroring the full labelled chips shown on expand.
  List<Widget> _indicatorIcons(BuildContext context) {
    final group = _group;
    final raw = <Widget>[
      if (passenger.isCancelRequested)
        Icon(Icons.event_busy_rounded, size: 14, color: c.warm),
      if (passenger.isPriorityApproved)
        Icon(Icons.star_rounded, size: 14, color: c.warm),
      if (passenger.tripType.isOneWay)
        Icon(
          passenger.tripType == TripType.outboundOnly
              ? Icons.arrow_forward_rounded
              : Icons.arrow_back_rounded,
          size: 14,
          color: c.warm,
        ),
      if (group != null) GroupDot(colorIndex: group.colorIndex, size: 8),
      if (_hasPickup) Icon(Icons.place_outlined, size: 14, color: c.ink3),
      if (_hasNote)
        Icon(Icons.chat_bubble_outline_rounded, size: 14, color: c.ink3),
    ];
    return [
      for (final w in raw)
        Padding(
          padding: const EdgeInsets.only(left: UgamSpacing.sm),
          child: w,
        ),
    ];
  }

  /// Tap-to-call phone shown only in the expanded body.
  Widget _phoneRow(BuildContext context) {
    if (passenger.phone.trim().isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => PhoneDialer.call(passenger.phone),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(top: UgamSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phone_rounded, size: 14, color: c.ink2),
            const SizedBox(width: 4),
            Text(
              passenger.phone,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
          ],
        ),
      ),
    );
  }

  /// The note quote box (moved verbatim from the old build()).
  Widget _noteBox(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.tight,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 16, color: c.ink3),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                '"${passenger.note}"',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(
                  color: c.ink2,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The full info-chip list — the EXACT chip set the old card built, returned
  /// raw so the expanded body wraps it. The `plural()` seat chips are guarded
  /// by `requestLines.isNotEmpty` and only ever run inside the expand region.
  List<Widget> _infoChips(BuildContext context) {
    final isAssigned = passenger.isFullyAssigned;
    final group = _group;
    return <Widget>[
      if (passenger.requestLines.isNotEmpty)
        UgamReqChip(
          // Count BERTHS (a Double Sofa = 2 seats), so "2 × Double Sofa" reads
          // as 4 SEATS. Unit word is localized + pluralised.
          label: '${_seatCount()} ${plural('requests.chip.seats_unit', passenger.seatBerths)}'
              .toUpperCase(),
          variant:
              isAssigned ? UgamChipVariant.good : UgamChipVariant.accent,
        ),
      if (passenger.requestLines.isNotEmpty)
        UgamReqChip(
          label: passenger.requestLines
              .map((l) => l.label)
              .join(' + ')
              .toUpperCase(),
          variant:
              isAssigned ? UgamChipVariant.good : UgamChipVariant.accent,
        ),
      if (passenger.tripType.isOneWay)
        UgamReqChip(
          // One-way loads a single leg, so it weighs HALF a physical seat per
          // berth — surface that weight on the trip chip.
          label: (passenger.tripType == TripType.outboundOnly
                  ? tr(
                      'requests.chip.trip_outbound',
                      namedArgs: {'from': tour.fromCity, 'to': tour.toCity},
                    )
                  : tr(
                      'requests.chip.trip_return',
                      namedArgs: {'from': tour.toCity, 'to': tour.fromCity},
                    ))
              .toUpperCase(),
          variant: UgamChipVariant.warm,
        ),
      if (passenger.isPartiallyAssigned)
        UgamReqChip(
          label: tr('requests.status.partial').toUpperCase(),
          variant: UgamChipVariant.warm,
        ),
      // Priority + group ride the SAME UgamReqChip as every other chip in this
      // Wrap. They used to be private widgets with their own pill geometry
      // (radius 999, 10pt) sitting immediately beside 6-radius 9.5pt chips —
      // two chip languages inside one row of one card. The star / group dot
      // come from UgamReqChip's leading slot.
      if (passenger.isPriorityApproved)
        UgamReqChip(
          label: tr('requests.chip.priority').toUpperCase(),
          variant: UgamChipVariant.warm,
          leading: Icons.star_rounded,
        ),
      // Group badge taps into the single Groups & Priority home.
      if (group != null)
        GestureDetector(
          onTap: selectionMode
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  Get.toNamed(
                    AppRoutes.tourGroups,
                    arguments: {'tourId': tour.id},
                  );
                },
          behavior: HitTestBehavior.opaque,
          child: UgamReqChip(
            label: (group.label.isEmpty
                    ? tr('tour_groups.group')
                    : group.label)
                .toUpperCase(),
            variant: UgamChipVariant.neutral,
            leadingWidget: GroupDot(colorIndex: group.colorIndex, size: 8),
          ),
        ),
      if (_hasPickup)
        // "PICKUP: ST · SURAT" when a short code exists, else the name-only
        // "PICKUP: SURAT". Wrapped in Obx so the code fills in if the pickup
        // list finishes loading after first paint; degrades to name-only when
        // the controller isn't registered.
        Builder(
          builder: (_) {
            final pickup = Get.isRegistered<PickupController>()
                ? Get.find<PickupController>()
                : null;
            final name = passenger.pickupLocationName;
            UgamReqChip chip(String? code) {
              final tail =
                  (code == null || code.isEmpty) ? name : '$code · $name';
              return UgamReqChip(
                label: '${tr('pickup.reflect_label')}: $tail'.toUpperCase(),
                variant: UgamChipVariant.neutral,
              );
            }

            // With no controller there is nothing observable to watch, so
            // render the name-only chip directly — an Obx whose closure reads
            // no observable throws.
            if (pickup == null) return chip(null);
            return Obx(
              () => chip(pickup.codeFor(passenger.pickupLocationId)),
            );
          },
        ),
      // Customer has asked to cancel this confirmed/seated booking
      // (migration 035). Warm badge so the organiser triages it; the ACTION
      // (approve → free seat) lives on the card's primary CTA.
      if (passenger.isCancelRequested)
        UgamReqChip(
          label: tr('requests.chip.cancel_requested').toUpperCase(),
          variant: UgamChipVariant.warm,
        ),
      ..._assignedSeatChips(),
    ];
  }

  /// Everything revealed on tap: phone, chips, note, and today's action row.
  Widget _expandedBody(BuildContext context) {
    final chips = _infoChips(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _phoneRow(context),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.sm),
          Wrap(
            spacing: UgamSpacing.sm,
            runSpacing: UgamSpacing.sm,
            children: chips,
          ),
        ],
        if (_hasNote) _noteBox(context),
        const SizedBox(height: UgamSpacing.md),
        _CardActions(
          passenger: passenger,
          tour: tour,
          isAssigned: passenger.isFullyAssigned,
          isWaitlisted: passenger.isWaitlisted,
          isConfirmed: passenger.isConfirmed,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final (statusLabel, statusVariant) = _status;

    // Attention edge: a pending customer cancellation gets a warm left edge so
    // it pops during a scan; a selected row keeps the accent edge.
    final Color edge = passenger.isCancelRequested
        ? c.warm
        : (selected ? c.accent : Colors.transparent);

    final card = AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border(left: BorderSide(color: edge, width: 3)),
      ),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Collapsed header (always shown) ──
            //
            // Two clusters, not a spreadsheet line. LEFT = who: the initial
            // disc, the name, and the seat summary with its indicator glyphs
            // hugging it. RIGHT = what state: the status chip on the name's
            // line, the age under it. The old row put the summary in an
            // `Expanded` and pushed the glyphs to the far edge, which is what
            // opened the wide dead gap through the middle of every row.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _leadingDisc(context, statusVariant),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 2 lines before ellipsis — app-wide name rule, see
                      // UgamRequestRow.
                      Text(
                        passenger.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.titleS.copyWith(color: c.ink),
                      ),
                      // Line 2 — seat summary + a Material-icon indicator strip
                      // (priority / group / pickup / note / one-way). Rendered
                      // only when there's a summary or at least one indicator.
                      Builder(builder: (context) {
                        final summary = _seatSummary();
                        final indicators = _indicatorIcons(context);
                        if (summary.isEmpty && indicators.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              if (summary.isNotEmpty)
                                // Flexible, not Expanded: the glyphs sit right
                                // after the text instead of being flung to the
                                // opposite margin.
                                Flexible(
                                  child: Text(
                                    summary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    // ink2, never the accent. Amber means
                                    // "this is yours" — it is not a subtitle
                                    // colour (V-09). State is the chip's job.
                                    style: UgamText.caption
                                        .copyWith(color: c.ink2),
                                  ),
                                ),
                              ...indicators,
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                // Right cluster — the row's state and its age, both flush to
                // the margin so the row has two anchors instead of one long
                // empty middle.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UgamReqChip(
                      label: statusLabel.toUpperCase(),
                      variant: statusVariant,
                    ),
                    const SizedBox(height: UgamSpacing.xs),
                    Text(
                      _timeAgo(passenger.createdAt),
                      maxLines: 1,
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ],
            ),
            // ── One visible "Accept" on rows that can still be confirmed ──
            // Confirm & seat used to be reachable only by a right-swipe (an
            // invisible gesture) or by expanding the row first. The swipe
            // stays; this is the same action as a tonal button the agent can
            // see. Hidden while expanded (the action row there carries it)
            // and while multi-selecting (the bulk bar owns Confirm).
            if (!expanded && !selectionMode && _canQuickConfirm)
              Padding(
                padding: const EdgeInsets.only(top: UgamSpacing.sm),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: IntrinsicWidth(
                    child: UgamButton(
                      label: tr('requests.action.accept'),
                      icon: Icons.verified_rounded,
                      kind: UgamButtonKind.tonal,
                      onPressed: () =>
                          _RequestActions(passenger: passenger, tour: tour)
                              .confirmAndSeat(),
                    ),
                  ),
                ),
              ),
            // ── Expand region (single-open accordion) ──
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              alignment: Alignment.topCenter,
              child: expanded
                  ? _expandedBody(context)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );

    // Same gestures as before, plus the press scale + button semantics the
    // shared wrapper ships. `haptic: false` because both callbacks already
    // fire their own (selectionClick on select, mediumImpact on long-press) —
    // letting the wrapper add its own would double-buzz every selection.
    return UgamTappable(
      onLongPress: selectionMode ? null : onLongPress,
      onTap: selectionMode ? onSelectTap : onToggleExpand,
      haptic: false,
      semanticLabel: passenger.displayName,
      child: card,
    );
  }
}
