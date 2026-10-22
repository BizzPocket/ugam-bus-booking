part of '../tour_detail_screen.dart';

// ─── STICKY ACTION BAR ────────────────────────────────────────────────

class _StickyAction extends StatelessWidget {
  final Tour tour;
  final int tab;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _StickyAction({
    required this.tour,
    required this.tab,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    if (tab == 4) {
      // Activity tab → no sticky action (back button is enough).
      return const SizedBox.shrink();
    }

    final cta = _buildCta(context);
    if (cta == null) return const SizedBox.shrink();

    return UgamStickyCTA(child: cta);
  }

  Widget? _buildCta(BuildContext context) {
    switch (tab) {
      case 1:
        {
          // Hide the sticky "Seats" button until seating is actually
          // actionable: there must be at least one bus AND at least one
          // passenger. Otherwise it's a dead-end tap (BUG-001) — the empty
          // state owns the share CTA.
          if (tour.buses.isEmpty || tour.passengers.isEmpty) return null;
          // While seats are still pending, action-word the CTA ("Assign seats"
          // + "N left") so the next step is explicit; once everything is placed
          // it settles to the neutral "Seats x/y" status label. Same
          // destination either way: the SeatsScreen SUMMARY.
          final pending = tour.pendingSeatsToAssign;
          final assigning = pending > 0;
          return UgamCTA(
            label:
                assigning ? tr('tour_detail.assign_seats') : tr('seats.title'),
            leadingIcon: Icons.event_seat_rounded,
            trailingValue: assigning
                ? tr('tour_detail.seats_left', namedArgs: {'n': '$pending'})
                : (() {
                    // THE seat meter — the raw entry count here read past
                    // capacity on a leg-shared seat ([SeatMeter]).
                    final m = Get.find<TourController>().seatMeterFor(tour);
                    return m.capacity > 0 ? '${m.occupied}/${m.capacity}' : null;
                  })(),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => SeatsScreen(
                  tourId: tour.id,
                  initialMode: SeatsMode.summary,
                ),
              ),
            ),
          );
        }
      case 2:
        // When empty, the body's UgamEmpty already owns the "Add bus" CTA
        // (next to its explanatory text) — don't duplicate it here. The sticky
        // bar only owns the "Add another bus" affordance once buses exist.
        if (tour.buses.isEmpty) return null;
        return UgamCTA(
          label: tr('tour_detail.add_another_bus'),
          leadingIcon: Icons.add_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => AddBusScreen(tourId: tour.id),
            ),
          ),
        );
      default:
        // Overview (1st) tab: NO sticky CTA. The Next-Action card in the tab
        // body is itself tappable and fires the exact same _runAction (and also
        // exposes the secondary action + the compact More-tools row above), so a
        // bottom CTA here only duplicates what the tab already covers. Every
        // action it could offer is already reachable from the tab body.
        return null;
    }
  }
}

void _runAction(
  BuildContext context,
  _NextAction action,
  Tour tour,
  ValueChanged<int> onSwitchTab,
) =>
    _runKind(context, action.kind, tour, onSwitchTab);

void _runKind(
  BuildContext context,
  _NextActionKind kind,
  Tour tour,
  ValueChanged<int> onSwitchTab,
) {
  switch (kind) {
    case _NextActionKind.addBus:
    // Handler picking lives in ManageBusesScreen (per-bus handler picker),
    // not the seat screen — route the agent there.
    case _NextActionKind.pickHandler:
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ManageBusesScreen(tourId: tour.id),
        ),
      );
    case _NextActionKind.assignSeats:
      // "Seats" entry -> SeatsScreen SUMMARY (tourOverview), never the bare grid.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SeatsScreen(
            tourId: tour.id,
            initialMode: SeatsMode.summary,
          ),
        ),
      );
    case _NextActionKind.lockAndNotify:
    case _NextActionKind.renotify:
      // Push the tour-scoped Notify screen for THIS tour.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => NotifyScreen(tourId: tour.id),
        ),
      );
    case _NextActionKind.completeGoLeg:
      () async {
        final ctrl = Get.find<TourController>();
        final n = ctrl.outboundOnlyActiveCount(tour.id);
        final ok = await UgamDialog.confirm(
          context,
          title: tr('tour_detail.complete_go_confirm_title'),
          message: tr('tour_detail.complete_go_confirm_body',
              namedArgs: {'count': '$n'}),
          confirmLabel: tr('tour_detail.complete_go_cta'),
        );
        if (ok) {
          final cleared = await ctrl.completeOutboundLeg(tour.id);
          if (!context.mounted) return;
          AppSnackBar.success(tr('tour_detail.complete_go_done',
              namedArgs: {'count': '$cleared'}));
        }
      }();
    case _NextActionKind.markCompleted:
      () async {
        final ok = await UgamDialog.confirm(
          context,
          title: tr('tour_detail.complete_confirm_title'),
          message: tr('tour_detail.complete_confirm_body',
              namedArgs: {'title': tour.title}),
          confirmLabel: tr('tour_detail.mark_completed'),
        );
        if (ok) {
          await Get.find<TourController>().completeTour(tour.id);
        }
      }();
    case _NextActionKind.addReturnTicket:
      // Return phase: book a new return-only ticket past the lock gate. Uses the
      // overlay context since this dispatcher is a top-level function.
      final ctx = Get.context;
      if (ctx != null) AddReturnTicketSheet.show(ctx, tour);
    case _NextActionKind.allSet:
      onSwitchTab(4); // jump to activity (0 Overview … 3 Money, 4 Activity)
  }
}

enum _NextActionKind {
  addBus,
  assignSeats,
  pickHandler,
  lockAndNotify,
  renotify,
  completeGoLeg,
  addReturnTicket,
  markCompleted,
  allSet,
}

class _NextAction {
  final _NextActionKind kind;
  final String title;
  final String? subtitle;
  final String ctaLabel;
  final IconData icon;
  final UgamStatusTone tone;

  /// Optional second action shown as a subtle in-card link (e.g. the return
  /// phase offers "Add return ticket" as the primary CTA and "Complete trip"
  /// here as the secondary).
  final _NextActionKind? secondaryKind;
  final String? secondaryCtaLabel;

  const _NextAction({
    required this.kind,
    required this.title,
    this.subtitle,
    required this.ctaLabel,
    required this.icon,
    required this.tone,
    this.secondaryKind,
    this.secondaryCtaLabel,
  });
}

_NextAction _nextActionFor(Tour tour) {
  // A tour with no buses can never get anyone seated, so "add a bus" is always
  // the next step — including a brand-new, passenger-less tour that previously
  // fell through to the terminal "You're all set" card.
  if (tour.buses.isEmpty) {
    return _NextAction(
      kind: _NextActionKind.addBus,
      title: tr('tour_detail.action_add_bus_title'),
      subtitle: tour.passengers.isEmpty
          ? tr('tour_detail.action_add_bus_subtitle_empty')
          : tour.passengers.length == 1
              ? tr('tour_detail.action_add_bus_subtitle_one')
              : tr('tour_detail.action_add_bus_subtitle_other',
                  namedArgs: {'n': '${tour.passengers.length}'}),
      ctaLabel: tr('tour_detail.add_bus'),
      icon: Icons.directions_bus_rounded,
      tone: UgamStatusTone.warm,
    );
  }
  // A rider whose seat was taken back AFTER they were told holds a WhatsApp
  // message naming a berth that no longer exists.
  //
  // *** WHY THIS SITS ABOVE "N seats to place" ***
  // Removing the seat also makes that rider's berths unassigned again, so
  // `pendingSeatsToAssign` goes up and the branch below would answer with
  // "1 seat to place" — silently re-seating them is NOT enough, because the
  // number in their hand is wrong either way and only a phone call fixes it.
  // Ranking it here is what makes the stale-notification check further down
  // reachable at all for a withdrawal. Plain seat MOVES keep their old rank:
  // they leave nothing unassigned, so nothing competes with them.
  if (tour.status == TourStatus.locked) {
    final stranded =
        tour.passengers.where((p) => p.seatsRemovedSinceNotified).length;
    if (stranded > 0) {
      return _NextAction(
        kind: _NextActionKind.renotify,
        title: tr('tour_detail.action_seat_removed_title',
            namedArgs: {'n': '$stranded'}),
        subtitle: tr('tour_detail.action_seat_removed_subtitle'),
        // Deliberately NOT "Re-notify": there is no approved WhatsApp template
        // for a withdrawal, so Notify offers their phone number and an "I've
        // told them" acknowledgement rather than a send.
        ctaLabel: tr('tour_detail.action_seat_removed_cta'),
        icon: Icons.phone_in_talk_rounded,
        tone: UgamStatusTone.warm,
      );
    }
  }
  // (Buses are non-empty from here on — the no-bus case returned above.)
  if (tour.pendingSeatsToAssign > 0) {
    final remaining = tour.pendingSeatsToAssign;
    // Active-only totals so a finished GO-leg rider neither inflates the
    // fraction nor resurfaces as pending demand (mirrors pendingSeatsToAssign).
    final active = tour.passengers.where((p) => !p.journeyDone);
    final activeAssigned =
        active.fold(0, (s, p) => s + p.totalSeatsAssigned);
    final activeRequested = active.fold(0, (s, p) => s + p.seatBerths);
    return _NextAction(
      kind: _NextActionKind.assignSeats,
      title: remaining == 1
          ? tr('tour_detail.action_assign_title_one')
          : tr('tour_detail.action_assign_title_other',
              namedArgs: {'n': '$remaining'}),
      subtitle: tr('tour_detail.action_assign_subtitle', namedArgs: {
        'assigned': '$activeAssigned',
        'requested': '$activeRequested',
      }),
      ctaLabel: tr('seats.title'),
      icon: Icons.event_seat_rounded,
      // Warm, like every other "there is work outstanding" next action on this
      // screen (add a bus, re-notify). It was the one accent-toned action,
      // which tinted the card, its medallion, its NEXT ACTION eyebrow, its
      // arrow and its secondary link copper — five accent marks for a state.
      tone: UgamStatusTone.warm,
    );
  }
  if (tour.allSeatsAssigned && tour.handlerId == null) {
    return _NextAction(
      kind: _NextActionKind.pickHandler,
      title: tr('tour_detail.action_pick_handler_title'),
      subtitle: tr('tour_detail.action_pick_handler_subtitle'),
      ctaLabel: tr('tour_detail.pick_handler'),
      icon: Icons.person_pin_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.allSeatsAssigned &&
      tour.handlerId != null &&
      tour.status != TourStatus.locked &&
      tour.status != TourStatus.completed) {
    return _NextAction(
      kind: _NextActionKind.lockAndNotify,
      title: tr('tour_detail.action_lock_title'),
      subtitle: tr('tour_detail.action_lock_subtitle'),
      ctaLabel: tr('tour_detail.action_lock_cta'),
      icon: Icons.lock_rounded,
      tone: UgamStatusTone.good,
    );
  }
  // Post-lock seat edits that haven't been WhatsApp'd yet outrank leg
  // completion — passengers are sitting on wrong-confirmed seats until then.
  // Asks [Passenger.notifiedSeatsAreStale], the canonical question, rather than
  // the old `assignedSeats.isNotEmpty && seatsChangedSinceNotified` (redundant
  // first half, and it dropped withdrawals). Withdrawals are already answered
  // by the higher-ranked block above, so `changed` here is seat MOVES only and
  // the "moved since the last send" copy stays true.
  if (tour.status == TourStatus.locked) {
    final changed =
        tour.passengers.where((p) => p.notifiedSeatsAreStale).length;
    if (changed > 0) {
      return _NextAction(
        kind: _NextActionKind.renotify,
        title: tr('tour_detail.action_renotify_title'),
        subtitle: tr('tour_detail.action_renotify_subtitle',
            namedArgs: {'n': '$changed'}),
        ctaLabel: tr('tour_detail.action_renotify_cta'),
        icon: Icons.chat_rounded,
        tone: UgamStatusTone.warm,
      );
    }
  }
  if (tour.status == TourStatus.locked &&
      tour.passengers.any(
        (p) => p.tripType == TripType.outboundOnly && !p.journeyDone,
      )) {
    return _NextAction(
      kind: _NextActionKind.completeGoLeg,
      title: tr('tour_detail.action_complete_go_title'),
      subtitle: tr('tour_detail.action_complete_go_subtitle'),
      ctaLabel: tr('tour_detail.complete_go_cta'),
      icon: Icons.logout_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.isReturnPhase) {
    final free =
        Get.find<TourController>().capacityFor(tour).returnSeatsFree;
    return _NextAction(
      kind: _NextActionKind.addReturnTicket,
      title: tr('tour_detail.action_return_leg_title'),
      subtitle: tr('tour_detail.action_return_leg_subtitle',
          namedArgs: {'free': '$free'}),
      ctaLabel: tr('tour_detail.add_return_ticket'),
      icon: Icons.event_seat_rounded,
      tone: UgamStatusTone.good,
      secondaryKind: _NextActionKind.markCompleted,
      secondaryCtaLabel: tr('tour_detail.mark_completed'),
    );
  }
  if (tour.status == TourStatus.locked) {
    return _NextAction(
      kind: _NextActionKind.markCompleted,
      title: tr('tour_detail.action_complete_title'),
      subtitle: tr('tour_detail.action_complete_subtitle'),
      ctaLabel: tr('tour_detail.mark_completed'),
      icon: Icons.check_circle_rounded,
      tone: UgamStatusTone.good,
    );
  }
  return _NextAction(
    kind: _NextActionKind.allSet,
    title: tour.status == TourStatus.completed
        ? tr('tour_detail.action_done_title_completed')
        : tr('tour_detail.action_done_title_ready'),
    subtitle: tour.status == TourStatus.completed
        ? tr('tour_detail.action_done_subtitle_completed')
        : tr('tour_detail.action_done_subtitle_ready'),
    ctaLabel: tr('tour_detail.view_timeline'),
    icon: Icons.check_circle_rounded,
    tone: UgamStatusTone.good,
  );
}
