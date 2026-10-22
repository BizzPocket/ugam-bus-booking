part of '../requests_screen.dart';

/// Shared request-action logic used by BOTH the swipe wrapper (`UgamSwipeAction`
/// in the list) and the expanded `_CardActions` button row, so the two paths
/// never duplicate the confirm / decline / notify flows.
class _RequestActions {
  final Passenger passenger;
  final Tour tour;
  const _RequestActions({required this.passenger, required this.tour});

  TourController get _tc => Get.find<TourController>();

  void openAssignment() {
    Get.toNamed(
      AppRoutes.seatAssignment,
      arguments: {'tourId': tour.id, 'passengerId': passenger.id},
    );
  }

  /// One-tap "Confirm & seat": flip to Confirmed (clears any waitlist flag) and
  /// fire the confirmation WhatsApp in the background. Per user request it no
  /// longer auto-navigates — it confirms + messages and stays on the list.
  Future<void> confirmAndSeat() async {
    HapticFeedback.lightImpact();
    await _tc.setConfirmed(tour.id, passenger.id, true);
    unawaited(sendConfirmationMessage());
  }

  /// Fires the Cloud `seat_allocation` confirmation template and toasts the
  /// outcome (surfacing Meta's rejection reason when the send fails).
  Future<void> sendConfirmationMessage() async {
    try {
      final result = await WhatsAppOutbound().sendConfirmed(
        tour: tour,
        passenger: passenger,
      );
      if (result.anySent) {
        AppSnackBar.success(
          tr(
            'requests.snack.confirm_sent_body',
            namedArgs: {'name': passenger.displayName},
          ),
          title: tr('requests.snack.confirm_sent_title'),
        );
      } else {
        final reason = result.results.isNotEmpty
            ? result.results.first.error
            : null;
        debugPrint('Confirm send failed for ${passenger.phone}: '
            '${result.results.map((r) => r.error).toList()}');
        // The confirm itself already succeeded — setConfirmed ran and moved the
        // row to Confirmed before this send. Only the WhatsApp notification
        // failed, so surface a WARNING ("confirmed, but couldn't notify"), never
        // a red error that wrongly reads as "couldn't confirm".
        AppSnackBar.warning(
          reason == null || reason.isEmpty
              ? tr('requests.snack.confirm_wa_failed')
              : '${tr('requests.snack.confirm_wa_failed')}\n$reason',
        );
      }
    } catch (e) {
      AppSnackBar.warning('${tr('requests.snack.confirm_wa_failed')}\n$e');
    }
  }

  /// Re-notify a passenger over WhatsApp: the full seat-allotment once seats are
  /// final, the lighter greeting before that, or the request-received deep-link
  /// when no seats exist yet.
  Future<void> sendAck() async {
    if (passenger.assignedSeats.isNotEmpty) {
      try {
        final result =
            WhatsAppOutbound.shouldSendFullAllotment(tour, passenger)
                ? await WhatsAppOutbound().sendSeatAllocations(
                    tour: tour,
                    onlyPassengerIds: {passenger.id},
                  )
                : await WhatsAppOutbound().sendSeatConfirmed(
                    tour: tour,
                    passenger: passenger,
                  );
        if (result.anySent) {
          AppSnackBar.success(
            tr(
              'requests.snack.confirm_sent_body',
              namedArgs: {'name': passenger.displayName},
            ),
            title: tr('requests.snack.confirm_sent_title'),
          );
        } else {
          // Carry Meta's own rejection text. Dropping it here is what made a
          // refused re-notify look like nothing had happened at all.
          AppSnackBar.error(
            '${tr('requests.snack.confirm_error')}${waFailureAppendix(result)}',
          );
        }
      } catch (e) {
        AppSnackBar.error('${tr('requests.snack.confirm_error')}\n$e');
      }
      return;
    }

    final sent = await WhatsAppService().sendAck(
      passenger: passenger,
      tour: tour,
    );
    if (sent) {
      AppSnackBar.success(
        tr(
          'requests.snack.ack_opened',
          namedArgs: {'name': passenger.displayName},
        ),
        title: tr('requests.snack.ack_title'),
      );
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
  }

  /// Decline (delete) the request after a destructive confirm. Returns true if
  /// the row was removed, false if the organiser cancelled the dialog.
  Future<bool> confirmDecline(BuildContext context) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.decline_dialog.title'),
      message: tr(
        'requests.decline_dialog.body',
        namedArgs: {'name': passenger.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.decline_dialog.confirm'),
      destructive: true,
      confirmIcon: Icons.close_rounded,
    );
    if (!confirmed) return false;
    await _removeAndNotify(
      bodyKey: 'requests.snack.declined_body',
      titleKey: 'requests.snack.declined_title',
      waFailedKey: 'requests.snack.declined_wa_failed',
    );
    return true;
  }

  /// Organiser APPROVES a customer's cancellation request (migration 035),
  /// reusing removePassenger to free any seat + drop the row. Returns true if
  /// approved, false if the dialog was cancelled.
  Future<bool> approveCancellation(BuildContext context) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.approve_cancel_dialog.title'),
      message: tr(
        'requests.approve_cancel_dialog.body',
        namedArgs: {'name': passenger.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.approve_cancel_dialog.confirm'),
      destructive: true,
      confirmIcon: Icons.check_rounded,
    );
    if (!confirmed) return false;
    await _removeAndNotify(
      bodyKey: 'requests.snack.cancel_approved_body',
      titleKey: 'requests.snack.cancel_approved_title',
      waFailedKey: 'requests.snack.cancel_approved_wa_failed',
    );
    return true;
  }

  /// The shared tail of decline + approve-cancellation: drop the row (frees any
  /// seat), send the WhatsApp cancellation, then toast — success first, plus a
  /// warning when the message did not go out.
  Future<void> _removeAndNotify({
    required String bodyKey,
    required String titleKey,
    required String waFailedKey,
  }) async {
    await _tc.removePassenger(tour.id, passenger.id);
    var waFailed = false;
    try {
      final wa = await WhatsAppOutbound().sendRequestCancelled(
        tour: tour,
        passenger: passenger,
      );
      waFailed = !wa.anySent;
    } catch (_) {
      waFailed = true;
    }
    AppSnackBar.success(
      tr(bodyKey, namedArgs: {'name': passenger.displayName}),
      title: tr(titleKey),
    );
    if (waFailed) {
      AppSnackBar.warning(tr(waFailedKey));
    }
  }
}

class _CardActions extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final bool isAssigned;
  final bool isWaitlisted;
  final bool isConfirmed;

  // No UgamColorSet field: every surface in this row (primary, secondary
  // circle, overflow circle, sheet rows) now resolves its own tokens through a
  // shared component, so the row has no colour of its own to carry.
  const _CardActions({
    required this.passenger,
    required this.tour,
    required this.isAssigned,
    required this.isWaitlisted,
    required this.isConfirmed,
  });

  TourController get _ctrl => Get.find<TourController>();

  _RequestActions get _act =>
      _RequestActions(passenger: passenger, tour: tour);

  Future<void> _sendAck() => _act.sendAck();

  Future<void> _toWaitlist() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, true);
    AppSnackBar.success(
      tr(
        'requests.snack.moved_to_waitlist',
        namedArgs: {'name': passenger.displayName},
      ),
    );
  }

  /// Pair, price, QR and confirm a waitlisted one-leg rider — the whole
  /// collection in one sheet, because confirming without a price quoted is the
  /// mistake it exists to prevent.
  Future<void> _openCollect(BuildContext context) async {
    await showWaitlistCollectSheet(context, tour: tour, rider: passenger);
  }

  Future<void> _promote() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, false);
    AppSnackBar.success(
      tr(
        'requests.snack.promoted_to_new',
        namedArgs: {'name': passenger.displayName},
      ),
    );
  }

  /// Move the request into the Confirmed state (clears any waitlist flag in the
  /// controller) and auto-send the Cloud `seat_allocation` confirmation. This is
  /// the dedicated confirm template — NOT the assign-stage `seat_allotment`
  /// "seat confirmed" message that _sendAck sends once seats exist.
  Future<void> _confirm() async {
    await _ctrl.setConfirmed(tour.id, passenger.id, true);
    await _sendConfirmationMessage();
  }

  Future<void> _sendConfirmationMessage() => _act.sendConfirmationMessage();

  /// "Back to New" on a confirmed card — drop the confirmed flag.
  Future<void> _unconfirm() async {
    await _ctrl.setConfirmed(tour.id, passenger.id, false);
  }

  Future<void> _unassignAll() async {
    await _ctrl.unassignSeats(tour.id, passenger.id);
    AppSnackBar.success(
      tr(
        'requests.snack.seats_cleared',
        namedArgs: {'name': passenger.displayName},
      ),
    );
  }

  Future<void> _confirmDecline(BuildContext context) =>
      _act.confirmDecline(context);

  /// Organiser APPROVES a customer's cancellation request (migration 035). This
  /// reuses the exact decline/free-seat mechanism: `removePassenger` deletes the
  /// passengers row, which inherently frees any assigned seat (seats live as the
  /// `assigned_seats` jsonb column ON that row) and drops the rider from the
  /// roster — the seating engine recomputes capacity automatically. Notifies the
  /// customer via the same WhatsApp cancellation sender the decline path uses.
  Future<void> _approveCancellation(BuildContext context) =>
      _act.approveCancellation(context);

  /// Organiser DISMISSES the customer's cancellation request — the counterpart
  /// to approving. Keeps the passenger on the tour and clears the marker on both
  /// rows (migration 036), so this card reverts to its normal state and the
  /// customer's app drops the "cancellation requested" banner. A quiet keep — no
  /// WhatsApp is sent (the organiser typically tells the customer directly).
  Future<void> _dismissCancellation(BuildContext context) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.dismiss_cancel_dialog.title'),
      message: tr(
        'requests.dismiss_cancel_dialog.body',
        namedArgs: {'name': passenger.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.dismiss_cancel_dialog.confirm'),
      confirmIcon: Icons.undo_rounded,
    );
    if (!confirmed) return;
    await _ctrl.dismissCancellationRequest(tour.id, passenger.id);
    AppSnackBar.success(
      tr(
        'requests.snack.cancel_dismissed_body',
        namedArgs: {'name': passenger.displayName},
      ),
      title: tr('requests.snack.cancel_dismissed_title'),
    );
  }

  void _openAssignment() => _act.openAssignment();

  Future<void> _confirmAndSeat() => _act.confirmAndSeat();

  void _openEdit(BuildContext context) {
    EditRequestSheet.show(context: context, tour: tour, passenger: passenger);
  }

  /// Quick priority toggle — flips this booking between approved-priority and
  /// none right from the card, without opening the Groups & Priority manager.
  /// Turning priority ON confirms first (it promises to reserve a lower berth
  /// where possible); turning it OFF is a direct toggle.
  Future<void> _togglePriority(BuildContext context) async {
    if (!passenger.isPriorityApproved) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('priority.alert_title'),
        message: tr('priority.alert_msg'),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('priority.alert_confirm'),
        confirmIcon: Icons.star_rounded,
      );
      if (!ok) return;
    }
    await _ctrl.setPassengerPriority(
      tour.id,
      passenger.id,
      !passenger.isPriorityApproved,
    );
  }

  /// The overflow "⋮" menu, as a sheet.
  ///
  /// This used to be a raw Material [PopupMenuButton]: square corners, Material
  /// elevation and 48px rows, popped from the SAME card whose Edit-request and
  /// Add-to-group actions slide up a 22-radius [UgamSheet] with a drag handle —
  /// two menu languages one tap apart. Items are the same [_MenuItem] list; the
  /// sheet is dismissed before the action runs so a dialog-opening item (edit,
  /// decline, priority) doesn't fight the sheet for the screen.
  void _showMoreActions(BuildContext context, List<_MenuItem> menu) {
    UgamSheet.show(
      context,
      title: tr('requests.action.more_actions'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in menu) ...[
            UgamButton(
              label: item.label,
              icon: item.icon,
              kind: item.isDanger
                  ? UgamButtonKind.dangerTonal
                  : UgamButtonKind.ghost,
              expand: true,
              onPressed: () {
                Navigator.of(sheetCtx).pop();
                item.onTap();
              },
            ),
            const SizedBox(height: UgamSpacing.sm),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String primaryLabel;
    final IconData primaryIcon;
    final VoidCallback primaryAction;
    // Assigned uses the muted "good" fill; every other state uses the accent.
    final bool primaryIsGood = isAssigned;
    final Widget secondary;
    List<_MenuItem> menu;

    final editItem = _MenuItem(
      tr('requests.action.edit_request'),
      Icons.edit_rounded,
      () => _openEdit(context),
    );
    final declineItem = _MenuItem(
      tr('requests.action.decline_request'),
      Icons.close_rounded,
      () => _confirmDecline(context),
      isDanger: true,
    );
    // Priority toggle — moved out of the crowded card row into the overflow
    // menu (label flips on the current priority state).
    final priorityItem = _MenuItem(
      passenger.isPriorityApproved
          ? tr('requests.action.remove_priority')
          : tr('requests.action.mark_priority'),
      passenger.isPriorityApproved
          ? Icons.star_rounded
          : Icons.star_outline_rounded,
      () => _togglePriority(context),
    );
    // Assign this passenger to an EXISTING cross-booking group (or change/remove
    // it) without leaving Requests. Group CREATION still lives in the single
    // Groups & Priority manager (reached from the sheet) — no duplicated logic.
    final groupItem = _MenuItem(
      passenger.groupId == null
          ? tr('requests.action.add_to_group')
          : tr('requests.action.change_group'),
      Icons.group_add_rounded,
      () => AssignGroupSheet.show(context, tour: tour, passenger: passenger),
    );

    if (isAssigned) {
      // ASSIGNED — view the seat map; keep the one-tap WhatsApp confirmation.
      primaryLabel = tr('requests.action.view_assignment');
      primaryIcon = Icons.visibility_rounded;
      primaryAction = _openAssignment;
      secondary = UgamIconButton(
        icon: Icons.chat_rounded,
        tone: UgamIconButtonTone.accent,
        onTap: _sendAck,
        semanticLabel: tr('requests.action.send_wa_ack'),
      );
      menu = [
        editItem,
        _MenuItem(
          tr('requests.action.unassign_all'),
          Icons.replay_rounded,
          _unassignAll,
        ),
      ];
    } else if (isConfirmed) {
      // CONFIRMED (no seats yet) — push straight to seat assignment; the circle
      // re-runs _confirm (an idempotent setConfirmed(true)) and resends the
      // `seat_allocation` confirmation WhatsApp — not `seat_allotment`, which
      // needs seats.
      primaryLabel = tr('requests.action.assign_seats');
      primaryIcon = Icons.grid_view_rounded;
      primaryAction = _openAssignment;
      secondary = UgamIconButton(
        icon: Icons.chat_rounded,
        tone: UgamIconButtonTone.accent,
        onTap: _confirm,
        semanticLabel: tr('requests.action.send_wa_ack'),
      );
      menu = [
        editItem,
        groupItem,
        _MenuItem(
          tr('requests.action.back_to_new'),
          Icons.arrow_back_rounded,
          _unconfirm,
        ),
        _MenuItem(
          tr('requests.action.move_to_waitlist'),
          Icons.hourglass_top_rounded,
          _toWaitlist,
        ),
        // A confirmed-but-unseated passenger (e.g. one whose seat was just
        // vacated and dropped back here) must still be removable — the agent
        // needs to delete a request that is no longer coming. The action is
        // guarded by a destructive confirm dialog + WhatsApp cancellation.
        declineItem,
      ];
    } else if (isWaitlisted) {
      // WAITLIST — primary Accept clears waitlist + fires confirmation WhatsApp,
      // then STAYS on the list. Seating happens later on Confirmed. Circle drops
      // back to New.
      primaryLabel = tr('requests.action.accept');
      primaryIcon = Icons.verified_rounded;
      primaryAction = _confirmAndSeat;
      // Collect is the SECOND labelled action, not a buried menu row: a
      // one-leg rider on this list exists to be paired and charged, and
      // burying that behind the overflow would leave Accept — which confirms
      // them for FREE — as the only visible thing to do with them.
      secondary = Expanded(
        child: UgamButton(
          label: tr('requests.action.collect_payment'),
          icon: Icons.qr_code_2_rounded,
          kind: UgamButtonKind.tonal,
          expand: true,
          onPressed: () => _openCollect(context),
        ),
      );
      menu = [
        editItem,
        groupItem,
        _MenuItem(
          tr('requests.action.back_to_new'),
          Icons.arrow_back_rounded,
          _promote,
        ),
        // No separate Accept here — the primary already accepts + notifies.
        declineItem,
      ];
    } else {
      // NEW — primary Accept moves to Confirmed + WhatsApp greeting, stays on
      // the list. Assign seats is a second labeled tonal button (not icon-only)
      // so seating is not buried. Waitlist lives in the overflow.
      primaryLabel = tr('requests.action.accept');
      primaryIcon = Icons.verified_rounded;
      primaryAction = _confirmAndSeat;
      secondary = Expanded(
        child: UgamButton(
          label: tr('requests.action.assign_seats'),
          icon: Icons.grid_view_rounded,
          kind: UgamButtonKind.tonal,
          expand: true,
          onPressed: _openAssignment,
        ),
      );
      menu = [
        editItem,
        groupItem,
        _MenuItem(
          tr('requests.action.move_to_waitlist'),
          Icons.hourglass_top_rounded,
          _toWaitlist,
        ),
        declineItem,
      ];
    }

    // A pending customer cancellation request (migration 035) overrides the
    // primary CTA into a warm "Approve cancellation" — the organiser's decision
    // is the salient action. Approving reuses removePassenger (frees the seat +
    // drops the row), matching today's decline. Every other affordance (the
    // priority toggle, the secondary circle, the overflow menu) is untouched, so
    // the normal state actions are still reachable while the request is pending.
    final bool cancelRequested = passenger.isCancelRequested;
    final String effPrimaryLabel = cancelRequested
        ? tr('requests.action.approve_cancel')
        : primaryLabel;
    final IconData effPrimaryIcon =
        cancelRequested ? Icons.event_busy_rounded : primaryIcon;
    final VoidCallback effPrimaryAction =
        cancelRequested ? () => _approveCancellation(context) : primaryAction;

    // While a cancellation is pending, the primary CTA approves it; the overflow
    // menu gains a "Keep booking" entry so the organiser can dismiss the request
    // and keep the passenger without cluttering the card row.
    if (cancelRequested) {
      menu = [
        _MenuItem(
          tr('requests.action.dismiss_cancel'),
          Icons.undo_rounded,
          () => _dismissCancellation(context),
        ),
        ...menu,
      ];
    }

    // Priority toggle rides in the overflow menu for every state (it used to be
    // an always-present third circle in the card row).
    menu = [...menu, priorityItem];

    // Card primary is TONAL (fill + coloured ink), never solid gold — solid
    // champagne is reserved for the screen's single bottom "Seats" CTA, so the
    // eye has one focal point. Assigned keeps the emerald "good" tone; a pending
    // cancellation uses warm; every other state uses the champagne accent.
    //
    // This was a hand-rolled 40pt lozenge (radius 999, 13pt label) whose
    // fill/ink/border triple was character-for-character UgamButtonKind.tonal,
    // so the Requests list read as a different app from the sheets and dialogs
    // it opens. It now IS a UgamButton; the warm/good states ride the
    // warmTonal/goodTonal arms rather than a private copy of the same maths.
    final UgamButtonKind primaryKind = cancelRequested
        ? UgamButtonKind.warmTonal
        : (primaryIsGood ? UgamButtonKind.goodTonal : UgamButtonKind.tonal);

    return Row(
      children: [
        Expanded(
          child: UgamButton(
            label: effPrimaryLabel,
            icon: effPrimaryIcon,
            kind: primaryKind,
            expand: true,
            onPressed: effPrimaryAction,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        // Per-state secondary action (Waitlist / Back to New / WhatsApp). The
        // priority toggle used to sit here as a third circle; it now lives in
        // the overflow menu so the row stays primary + one secondary + menu.
        secondary,
        const SizedBox(width: UgamSpacing.sm),
        UgamIconButton(
          icon: Icons.more_vert_rounded,
          onTap: () => _showMoreActions(context, menu),
          semanticLabel: tr('requests.action.more_actions'),
        ),
      ],
    );
  }
}

class _MenuItem {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDanger;

  const _MenuItem(this.label, this.icon, this.onTap, {this.isDanger = false});
}
