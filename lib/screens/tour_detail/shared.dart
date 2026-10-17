part of '../tour_detail_screen.dart';

// ─── HELPERS / SHARED MODELS ──────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink3));
  }
}

/// Compact live-vitals strip for the hero: "N riders" from tour-only data.
/// The seat fact lives in the Overview vitals + next-step card, not here.
/// Renders nothing until the tour has riders, so a brand-new tour's hero
/// stays clean.
class _HeroVitals extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroVitals({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    // Riders only. The seat count used to lead this line too — the same
    // "x / y seats" the vitals grid and the next-step card already carry, so
    // the header said it a third time. Seats live in the vitals now.
    if (tour.passengerCount <= 0) return const SizedBox.shrink();
    final riders = tour.passengerCount == 1
        ? tr('tour_detail.vitals_riders_one')
        : tr('tour_detail.vitals_riders_other',
            namedArgs: {'n': '${tour.passengerCount}'});
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          Icon(Icons.people_alt_rounded, size: 13, color: c.ink3),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              riders,
              style: UgamText.tabular(
                UgamText.caption.copyWith(color: c.ink2),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full tour-actions list — every per-tour workspace in one clean, labeled
/// surface. Restored after the BUG-001 slim removed Seats/Buses/Requests; the
/// agent wanted all shortcuts back, so the fix is presentation (tidy labeled
/// groups) rather than removal. Each row lands straight on its real workspace
/// screen (no forwarding hop), and these are the SAME destinations the tabs /
/// Next-Action card use. The Lock/Send row highlights (and flips Lock→Send)
/// once the tour is ready to lock (all seats assigned + handler set) or is
/// locked, so the next milestone still stands out among neutral rows.
///
/// FLAT BY DESIGN. This used to show three rows plus a "More tools" expander
/// hiding Buses / Groups / Lock — an affordance from when the list rendered
/// INLINE on the Overview tab. Its only caller is now the sheet the Overview's
/// More tile opens, which is itself titled "More tools": the screen read
/// "More tools ▸ More tools" and buried half the tools behind a second tap
/// inside the surface opened to reveal them. Six rows fit; nothing is hidden.
/// Two eyebrows carry the grouping the expander used to imply — ACTIONS is the
/// tour lifecycle (requests → seats → money → lock/send), MANAGE is setup.
class _ActionsGrid extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActionsGrid({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final locked = tour.status == TourStatus.locked;
    final completed = tour.status == TourStatus.completed;
    // Riders whose last message no longer matches reality — seats MOVED, or
    // taken back entirely. The predicate here used to be `assignedSeats
    // .isNotEmpty && seatsChangedSinceNotified`: the first half is redundant
    // (the getter already requires seats) and its real effect was to hide the
    // rider whose seat was WITHDRAWN after they were told — the one person who
    // turns up on the day expecting a berth. [Passenger.notifiedSeatsAreStale]
    // is the single "does this rider still need telling?" question.
    final stale =
        tour.passengers.where((p) => locked && p.notifiedSeatsAreStale).toList();
    final needsRenotify = stale.isNotEmpty;
    // A withdrawal cannot be WhatsApp'd (no approved template), so Notify shows
    // the phone number and an "I've told them" acknowledgement instead. The row
    // must not promise a re-send it will not offer.
    final anyWithdrawn = stale.any((p) => p.seatsRemovedSinceNotified);
    final readyToLock = !locked &&
        tour.passengers.isNotEmpty &&
        tour.allSeatsAssigned &&
        tour.handlerId != null;

    void push(Widget screen) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => screen),
        );

    // Mobile-native: the icon-grid launcher is a vertical list of full-width
    // tool rows (icon left + label + chevron, 56dp), all of them visible.
    final requests = _TourToolRow(
      icon: Icons.how_to_reg_rounded,
      label: tr('tour_detail.tool_requests'),
      c: c,
      onTap: () => push(RequestsScreen(initialTourId: tour.id)),
    );
    final seats = _TourToolRow(
      icon: Icons.event_seat_rounded,
      label: tr('tour_detail.tool_seats'),
      c: c,
      // A completed tour's live GO chart has been recycled, so its Seats row
      // opens the frozen read-only seat HISTORY instead of the live editor.
      onTap: () => push(
        tour.status == TourStatus.completed
            ? PastTourSeatHistoryScreen(tourId: tour.id)
            : SeatsScreen(tourId: tour.id, initialMode: SeatsMode.summary),
      ),
    );
    final money = _TourToolRow(
      icon: Icons.account_balance_wallet_rounded,
      label: tr('tour_detail.tool_money'),
      c: c,
      onTap: () => push(TourMoneyBoardScreen(tourId: tour.id)),
    );

    final buses = _TourToolRow(
      icon: Icons.directions_bus_rounded,
      label: tr('tour_detail.tool_buses'),
      c: c,
      onTap: () => push(ManageBusesScreen(tourId: tour.id)),
    );
    final groups = _TourToolRow(
      icon: Icons.groups_rounded,
      label: tr('tour_detail.tool_groups'),
      c: c,
      onTap: () => push(TourGroupsScreen(tourId: tour.id)),
    );
    final lockSend = _TourToolRow(
      icon: needsRenotify
          ? (anyWithdrawn ? Icons.phone_in_talk_rounded : Icons.chat_rounded)
          : locked
              ? Icons.send_rounded
              : Icons.lock_rounded,
      label: needsRenotify
          ? (anyWithdrawn
              ? tr('tour_detail.action_seat_removed_cta')
              : tr('tour_detail.action_renotify_cta'))
          : locked
              ? tr('notify.title')
              : tr('tour_detail.tool_lock'),
      c: c,
      highlight: readyToLock || locked,
      warmHighlight: needsRenotify,
      onTap: () => push(NotifyScreen(tourId: tour.id)),
    );

    const gap = UgamSpacing.tight;

    // Six rows always drawn is taller than the sheet's 92%-of-screen cap on a
    // short phone (or at a large text scale), and the shell's Flexible would
    // clip rather than scroll. Scrolling here keeps every row reachable, so
    // dropping the expander doesn't trade a hidden section for a hidden edge.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionEyebrow(label: tr('tour_detail.actions_section'), c: c),
          const SizedBox(height: UgamSpacing.md),
          requests,
          const SizedBox(height: gap),
          seats,
          const SizedBox(height: gap),
          money,
          // The milestone closes the lifecycle group, where it reads as the
          // next step rather than as one more shortcut — and a COMPLETED tour
          // has already passed it. NotifyScreen refuses a finished tour
          // outright ("Tour is completed"), so the row could only dead-end;
          // worse, `locked` is false for a completed tour, so it rendered as a
          // HIGHLIGHTED "Lock" — the next step on a trip that is already over.
          // Hidden, not disabled or relabelled: the other surfaces offering
          // this action already omit it for a completed tour
          // (tours_screen._actionFor returns null, dashboard._needsAttention
          // filters completed out), and Notify has no read-only "who was
          // notified" view a relabel could honestly point at.
          if (!completed) ...[
            const SizedBox(height: gap),
            lockSend,
          ],
          const SizedBox(height: UgamSpacing.lg),
          _SectionEyebrow(label: tr('tour_detail.manage'), c: c),
          const SizedBox(height: UgamSpacing.md),
          buses,
          const SizedBox(height: gap),
          groups,
        ],
      ),
    );
  }
}

/// A full-width tool row (56dp): leading icon chip, label, trailing chevron.
/// Replaces the old 3×2 icon grid tile with a thumb-friendly list item.
class _TourToolRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final UgamColorSet c;

  /// Draws the row in the "good" accent — used for Lock/Send when the tour is
  /// ready to lock or already locked, so the next step stands out.
  final bool highlight;

  /// When true with [highlight], uses warm (re-notify) instead of good.
  final bool warmHighlight;

  const _TourToolRow({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.c,
    this.highlight = false,
    this.warmHighlight = false,
  });

  @override
  Widget build(BuildContext context) {
    // Ordinary tool rows are NEUTRAL (graphite chip + ink glyph): a shortcut
    // list is navigation, and colouring all six would rank none of them. Only
    // the lifecycle milestone is tinted — `good` once the tour is ready to lock
    // or locked, `warm` for post-lock re-notify urgency. Both are semantic
    // states, so neither is the accent; nothing in this list is ever amber.
    final (iconColor, fill) = !highlight
        ? (c.ink, c.cardElev)
        : warmHighlight
            ? (c.warm, c.warmFill)
            : (c.good, c.goodFill);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: Container(
          // Six of these stack on the Overview tab; at a fixed 56 they stayed
          // full size while their labels shrank to 0.85x on a 360pt phone.
          height: UgamScale.tap(context, 56),
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(UgamRadius.row),
          ),
          child: Row(
            children: [
              Container(
                width: UgamScale.px(context, 40),
                height: UgamScale.px(context, 40),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(icon,
                    size: UgamScale.px(context, 19), color: iconColor),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: UgamScale.px(context, 20), color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lifecycle → tone. THREE bands, and the status LABEL (not the colour) is what
/// names the exact stage:
///
///   * `warm`    — pre-lock. The tour still needs the agent: riders to collect,
///                 a bus to book, seats to place.
///   * `good`    — locked. Set up, confirmed, running.
///   * `neutral` — completed. Archived; nothing to do.
///
/// Planning / bus-booked / assigning were `accent`, which made the amber a
/// STATUS colour — the one role the token's own doc rules out — and meant most
/// tours in the app wore the "this is yours" hue for no reason. They are all
/// the same thing operationally ("not ready yet"), so they share one tone and
/// the label carries the detail.
UgamStatusTone _toneFor(TourStatus s) => switch (s) {
      TourStatus.planning => UgamStatusTone.warm,
      TourStatus.collecting => UgamStatusTone.warm,
      TourStatus.busBooked => UgamStatusTone.warm,
      TourStatus.assigning => UgamStatusTone.warm,
      TourStatus.locked => UgamStatusTone.good,
      TourStatus.completed => UgamStatusTone.neutral,
    };

// The `accent` arms below are now unreachable from this screen — nothing here
// produces [UgamStatusTone.accent] any more. They stay because the switches are
// exhaustive over a shared design-system enum, and because the mapping itself
// is correct: if a genuinely OWNED thing ever lands on this screen, it maps
// here. Do not re-point an ordinary status at it to "use up" the branch.
Color _toneColor(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };

Color _toneFill(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accentFill,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.cardElev,
    };
