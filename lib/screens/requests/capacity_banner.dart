part of '../requests_screen.dart';

// ─── Capacity banner ──────────────────────────────────────────────────

/// At-a-glance demand-vs-capacity strip: how many berths the ACTIVE (non-
/// waitlisted) requests need, the bus capacity, and whether there's room or
/// an overflow. This is the screen where the agent decides who to waitlist,
/// so the capacity pressure belongs right here. Counted in berths — a Double
/// Sofa request line costs 2 berths — matching [Tour.totalBusSeats].
class _CapacityBanner extends StatefulWidget {
  final UgamColorSet c;
  final Tour tour;
  const _CapacityBanner({required this.c, required this.tour});

  @override
  State<_CapacityBanner> createState() => _CapacityBannerState();
}

class _CapacityBannerState extends State<_CapacityBanner> {
  // Collapsed by default so the passenger cards surface sooner — the agent
  // taps to reveal the full demand/seats/free breakdown only when triaging.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final tour = widget.tour;
    // No-bus demand, counted as WHOLE seats per leg (never the engine's
    // fractional seatLoad, which leaks "1.5" — a number no one can book). Sum
    // the active riders' physical berths on each leg so the no-bus headline can
    // honestly say "Need {go} going · {ret} returning".
    var goDemand = 0;
    var retDemand = 0;
    for (final p in tour.passengers) {
      if (p.isWaitlisted || p.journeyDone) continue;
      goDemand += p.goBerths;
      retDemand += p.retBerths;
    }
    final noBus = tour.buses.isEmpty;
    // Engine-truth occupancy (the single source) — see [computeTourCapacity].
    // The old `capacity − demand` lied "FULL" while a seat sat physically empty,
    // because it counted every non-waitlisted rider as seatable even when the
    // engine could not place them (stranger-share double, leg-blocked single,
    // seater vs sofa). Reading the deterministic plan makes `free` mean GENUINELY
    // empty, and the riders the engine can't auto-seat surface as
    // "needs your decision" instead of hiding inside a phantom full bus.
    final tourCtrl = Get.find<TourController>();
    final cap = tourCtrl.capacityFor(tour);
    // The headline count comes from THE seat meter ([SeatMeter]) so this
    // banner, the dashboard hero and the tour detail all read the same
    // "x / n" — the plan alone under-counted a seated tour (68 vs 72 placed).
    // The plan still owns "needs your decision".
    final meter = tourCtrl.seatMeterFor(tour);
    final free = meter.free;
    final needsDecision = cap.needsDecision;
    // GENUINELY-empty WHOLE tiles per seat type, split by open leg, read from
    // the SAME engine plan as [free] (see [TourCapacity.freeByType]). Each type
    // carries round / go-only / return-only counts, so the by-type row shows the
    // agent both HOW MANY of each seat are open AND which legs they're open on —
    // the one-way surplus now lives per type instead of a separate tour-wide
    // reclaim line. Only types the buses actually have are shown.
    final typeFree = <(String, SeatTypeFree)>[
      for (final st in const [
        SeatType.singleSofa,
        SeatType.doubleSofa,
        SeatType.seater,
      ])
        if ((cap.capByType[st] ?? 0) > 0)
          (st.displayName, meter.freeByType[st] ?? const SeatTypeFree()),
    ];
    // Show the go/return colour caption only when some type actually has a
    // one-way-only opening — the common round-trip case stays clean.
    final anyOneWay = typeFree.any((t) => t.$2.hasOneWay);

    // Capacity has to MEAN something at a glance, so the banner's tone is
    // driven by FILL PRESSURE rather than by a flat "has a bus / doesn't"
    // switch: mint while there is real room, champagne once the bus is nearly
    // gone, red when it is full. The old mapping was mint-or-`ink3`, which
    // painted a full bus in tertiary grey — the least alarming colour in the
    // set for the one state that stops the agent taking bookings.
    //
    // NOTE (V-06): the BAR itself still fills in neutral `ink2`, because that
    // fill lives inside the shared `UgamCapacityMeter` and is not this
    // screen's to change. Everything the banner owns — icon, glyph, card tone
    // and the pressure chip below — now carries the semantic colour instead.
    const double kTightFrac = 0.85;
    final double fillFrac = meter.capacity <= 0
        ? 0
        : (meter.occupied / meter.capacity).clamp(0.0, 1.0);
    // A locked / completed tour is not "filling" any more — booking is shut.
    // The pressure chip then names the tour's real phase instead.
    final bool closed = tour.status == TourStatus.locked ||
        tour.status == TourStatus.completed;
    final bool full = !noBus && free <= 0;
    final bool tight =
        !noBus && !full && !closed && fillFrac >= kTightFrac;

    // The bar is a quiet soft card — surface, radius, shadow and press ink all
    // come from [UgamCard] so it reads as the same card family as the request
    // rows below it. The surface itself only tints for the two states that
    // need the whole strip to shout: no bus at all (warm) and a full bus
    // (danger). "Tight" stays a neutral card and speaks through the chip.
    final (Color tone, IconData icon, String statusLabel) = noBus
        ? (c.warm, Icons.directions_bus_outlined,
            tr('requests.capacity.no_buses'))
        : full
            ? (c.danger, Icons.event_seat_rounded, tr('capacity.full'))
            : tight
                ? (c.accent, Icons.event_seat_rounded,
                    tr('requests.capacity.tight'))
                : (c.good, Icons.event_seat_outlined,
                    tr('requests.capacity.free'));

    final UgamCardTone cardTone = noBus
        ? UgamCardTone.warm
        : full
            ? UgamCardTone.danger
            : UgamCardTone.none;

    // Decorative glyphs in this banner must shrink WITH the meter text beside
    // them, otherwise they dominate the number they annotate at 0.85x.
    final s = UgamScale.of(context);

    return AnimatedSize(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      alignment: Alignment.topCenter,
      child: UgamCard.plain(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _expanded = !_expanded);
        },
        tone: cardTone,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Collapsed glance line: status icon + the per-leg capacity meter
            // + a chevron. The meter (UgamCapacityMeter.tour) replaces the old
            // merged "$occupied/$capacity" fraction + percentage bar + FREE
            // cluster — it shows each leg as whole seats with its own free
            // count, never a percentage and never the engine's fractional load.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, size: 18 * s, color: tone),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: noBus
                      ? Text(
                          (goDemand > 0 || retDemand > 0)
                              ? tr('capacity.demand_legs', namedArgs: {
                                  'go': '$goDemand',
                                  'ret': '$retDemand',
                                })
                              : statusLabel,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                        )
                      : UgamCapacityMeter.seats(meter),
                ),
                // Pressure chip — the semantic read the neutral meter bar
                // cannot give. Shown ONLY for the two states worth
                // interrupting a scan for, so a healthy bus stays quiet.
                if (!noBus && closed) ...[
                  const SizedBox(width: UgamSpacing.sm),
                  UgamReqChip(
                    label: tour.status.displayName,
                    variant: UgamChipVariant.neutral,
                  ),
                ] else if (!noBus && (full || tight)) ...[
                  const SizedBox(width: UgamSpacing.sm),
                  UgamReqChip(
                    label: statusLabel.toUpperCase(),
                    variant: full
                        ? UgamChipVariant.danger
                        : UgamChipVariant.accent,
                  ),
                ],
                const SizedBox(width: UgamSpacing.sm),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18 * s,
                  color: c.ink3,
                ),
              ],
            ),
            // Honest "blocked" line: riders the engine can't auto-seat under
            // the hard rules (stranger-share double, leg conflict, wrong seat
            // type). Shown right under the glance line so an empty-but-blocked
            // seat is never mistaken for a miscalculated "full".
            if (!noBus && needsDecision > 0) ...[
              const SizedBox(height: UgamSpacing.sm),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  Get.toNamed(
                    AppRoutes.seatingExceptions,
                    arguments: {'tourId': tour.id},
                  );
                },
                // This sliver is the ONLY route into the seating-decisions
                // screen and was a ~17px strip — a miss fell through to the
                // card's own tap and animated the banner instead. The painted
                // content is unchanged; only the hit box is floored at 44.
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 14 * s, color: c.warm),
                      const SizedBox(width: UgamSpacing.xs),
                      Expanded(
                        child: Text(
                          tr('requests.capacity.needs_decision',
                              namedArgs: {'n': '$needsDecision'}),
                          style: UgamText.micro.copyWith(color: c.warm),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 14 * s, color: c.warm),
                    ],
                  ),
                ),
              ),
            ],
            // Expanded detail: the opposite-leg reclaim hint + free-by-type
            // pills. The headline meter already shows the per-leg placed/cap/
            // free whole-seat counts, so the old three-segment "requested /
            // seats / free" row (which leaked the fractional 1.5) is gone.
            if (_expanded) ...[
              // Free-by-type breakdown — which KIND of seat is still open AND
              // on which legs, so the agent can match a request precisely: a
              // Double Sofa pair to a round-trip-free double, a return-only
              // rider to a return-only-open seat. Each pill shows the round
              // count plus cyan (go-only) / violet (return-only) leg badges;
              // the one-way surplus lives here per type instead of a separate
              // tour-wide reclaim line. Only shown when the bus mixes seat
              // types; a single-type bus already says it in the headline free.
              if (!noBus && typeFree.length >= 2) ...[
                const SizedBox(height: UgamSpacing.tight),
                Row(
                  children: [
                    Text(
                      tr('requests.capacity.free_by_type'),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const Spacer(),
                    // Colour key for the leg badges — shown only when some type
                    // actually has a going-/returning-only opening, so the
                    // common round-trip case stays uncluttered.
                    if (anyOneWay) const UgamLegCaption(),
                  ],
                ),
                const SizedBox(height: UgamSpacing.sm),
                Wrap(
                  spacing: UgamSpacing.sm,
                  runSpacing: UgamSpacing.sm,
                  alignment: WrapAlignment.start,
                  children: [
                    for (final (label, free) in typeFree)
                      UgamTypeFreePill(c: c, label: label, free: free),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
