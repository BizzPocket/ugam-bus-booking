part of '../notify_screen.dart';

/// Lock + every WhatsApp send the Notify screen fires: the lock→send chain,
/// the bulk / changed / single-row seat-allotment sends, the withdrawn-seat
/// follow-up and the per-bus announcement composer.
extension _NotifySendFlow on _NotifyScreenState {
  Future<void> _lockTour(Tour tour) async {
    // "Lock & notify" is ONE mental action for the organiser, so the flow
    // auto-chains lock → send. It used to also cost TWO back-to-back confirms
    // ("Lock this tour?" then a fresh "Send seat allocations?" after a silent
    // gap). Collapse those into a SINGLE confirm that covers both actions;
    // count the riders who will actually receive an allocation so the message
    // is honest. (The independent post-lock "Re-send to all" path keeps its
    // own confirm — see [_sendSeatAllocations].)
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    final seatedCount =
        t.passengers.where((p) => p.assignedSeats.isNotEmpty).length;

    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('notify.lock_send_dialog_title'),
      message: tr(
        'notify.lock_send_dialog_body',
        namedArgs: {'count': seatedCount.toString()},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('notify.lock_send_dialog_confirm'),
      confirmIcon: Icons.lock_rounded,
    );
    if (!confirmed) return;
    await Get.find<TourController>().lockTour(tour.id);
    if (!mounted) return;
    // No green "locked" toast here — the locked status card + the sticky CTA
    // already make the new state obvious, so the toast was redundant noise.

    // Phase 8 — push each seated passenger their seat allocation via the Cloud
    // API (seat_allotment template). The combined confirm above already covered
    // this send, so skip the (now redundant) second "Send seat allocations?".
    await _sendSeatAllocations(tour, skipConfirm: true);
  }

  /// Confirm + send seat charts to every seated rider on [tour].
  ///
  /// [skipConfirm] is set only on the lock→send auto-chain (see [_lockTour]),
  /// where a single combined "Lock tour & send seat allocations?" confirm has
  /// already covered this send — so this path must NOT raise a second,
  /// redundant "Send seat allocations?" dialog. Every independent entry point
  /// (the post-lock "Re-send to all" CTA) leaves it false and keeps its confirm.
  Future<void> _sendSeatAllocations(Tour tour, {bool skipConfirm = false}) async {
    // Use the FRESHEST tour from the controller — the passed snapshot can be
    // stale (captured before the seat plan was applied/persisted), which would
    // make the send think nobody is seated and bail out silently.
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    final seated =
        t.passengers.where((p) => p.assignedSeats.isNotEmpty).toList();
    if (seated.isEmpty) {
      AppSnackBar.error(tr('notify.no_seated_passengers'));
      return;
    }

    if (!skipConfirm) {
      final ok = await _confirmAllocSend(seated.length);
      if (!ok) return;
    }

    await _dispatchSeatAllocations(t, seated.map((p) => p.id).toSet());
  }

  /// Confirm + re-dispatch seat charts to a SPECIFIC set of riders (those whose
  /// seats changed since their last notification). Mirrors [_sendSeatAllocations]
  /// but targets [ids] instead of every seated rider.
  Future<void> _sendChangedAllocations(Tour tour, Set<String> ids) async {
    if (ids.isEmpty) return;
    final ok = await _confirmAllocSend(ids.length);
    if (!ok) return;
    await _dispatchSeatAllocations(tour, ids);
  }

  /// The shared "Send seat allocations to [count] riders?" confirm.
  Future<bool> _confirmAllocSend(int count) => UgamDialog.confirm(
        context,
        title: tr('notify.alloc_dialog_title'),
        message: tr(
          'notify.alloc_dialog_body',
          namedArgs: {'count': count.toString()},
        ),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('notify.alloc_dialog_send'),
        confirmIcon: Icons.send_rounded,
      );

  /// The per-row action. A seated rider gets their seat chart re-sent; a rider
  /// whose seat was WITHDRAWN gets the follow-up path instead.
  Future<void> _rowAction(Tour tour, Passenger p) {
    if (p.seatsRemovedSinceNotified) return _seatRemovedFollowUp(tour, p);
    return _dispatchSeatAllocations(tour, {p.id});
  }

  /// Follow-up for a rider who was told about a seat that has since been taken
  /// away from them.
  ///
  /// *** WHY THIS DOES NOT SEND ANYTHING ***
  /// No approved template fits, and the near misses are all worse than silence:
  ///   * `seat_allotment` is built around an image header of the rider's OWN
  ///     highlighted seat. With no seat there is no chart to render, and
  ///     [WhatsAppOutbound.sendSeatAllocations] filters them out anyway — the
  ///     bulk path would report a phantom failure and loop on Retry.
  ///   * `seat_allocation` / the confirm greeting say the OPPOSITE of the truth
  ///     ("your seat is confirmed") to someone who has just lost their berth.
  ///   * `bus_msg` is free text, but it is a per-bus announcement template and
  ///     inventing wording for a withdrawn seat is not a decision this screen
  ///     should make on the organiser's behalf.
  /// So the screen names the person and their number and leaves the words to a
  /// human voice. Confirming records that they were told, which is the only
  /// thing that takes them off the list. This is the template gap — until a
  /// "seat withdrawn" template is approved, it stays a phone call.
  Future<void> _seatRemovedFollowUp(Tour tour, Passenger p) async {
    final told = await UgamDialog.confirm(
      context,
      title: tr('notify.seat_removed_dialog_title'),
      message: tr('notify.seat_removed_dialog_body', namedArgs: {
        'name': p.displayName,
        'phone': displayPhone(p.phone) ?? p.phone,
      }),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('notify.seat_removed_mark_told'),
      confirmIcon: Icons.check_rounded,
    );
    if (!told) return;
    // Stamps the rider's CURRENT (empty) seat signature, so they leave the
    // tracker and stay gone — unless they are seated again, which starts the
    // ordinary notify cycle over.
    await Get.find<TourController>().markSeatsNotified(tour.id, {p.id});
  }

  /// Send the seat-allotment messages to [passengerIds] on [t], showing a live
  /// "preparing X of N" dialog while the charts build + upload (the slow part),
  /// then a result summary. On partial/total failure the summary offers a
  /// one-tap RETRY that re-sends only the recipients that failed.
  Future<void> _dispatchSeatAllocations(Tour t, Set<String> passengerIds) async {
    if (passengerIds.isEmpty) return;
    final progress = ValueNotifier<int>(0);
    final total = passengerIds.length;
    var dialogOpen = true;
    // Live progress dialog (non-dismissible) — updates as each chart finishes.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SendProgressDialog(progress: progress, total: total),
    ).then((_) => dialogOpen = false));

    WaSendResult result;
    try {
      result = await WhatsAppOutbound().sendSeatAllocations(
        tour: t,
        onlyPassengerIds: passengerIds,
        onProgress: (done, _) => progress.value = done,
      );
    } catch (e) {
      if (mounted && dialogOpen) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      if (mounted) AppSnackBar.error(tr('notify.alloc_failed_body'));
      return;
    }
    if (mounted && dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (!mounted) return;

    // Mark the successfully-notified passengers so the tracker + pending count
    // update and the "Send to all pending" CTA hides once everyone's done.
    //
    // Correlated on PASSENGER IDENTITY, never on the phone number — see
    // [notifiedPassengerIds] for why a family sharing one handset made the old
    // phone match silence riders whose message never went out.
    final batch =
        t.passengers.where((p) => passengerIds.contains(p.id)).toList();
    final justSent =
        notifiedPassengerIds(result: result, requested: passengerIds);
    if (justSent.isNotEmpty) {
      // Persist the notified seat signature so a later post-lock edit re-flags
      // ONLY the changed riders for re-notify (survives reload / restart).
      //
      // This is also what updates the tracker. `markSeatsNotified` writes the
      // signature OPTIMISTICALLY, so the rows flip to "Sent" on this frame —
      // no separate session set to keep in step, and nothing to go stale.
      unawaited(
        Get.find<TourController>().markSeatsNotified(t.id, justSent),
      );
    }

    if (result.allSent) {
      AppSnackBar.success(
        tr('notify.alloc_sent_body', namedArgs: {'count': '${result.sent}'}),
        title: tr('notify.alloc_sent_title'),
      );
      return;
    }

    // Nothing was even attempted: the send returned no per-recipient outcome at
    // all (every requested rider turned out to hold no seat, so no chart could
    // be built). Offering "Retry 1 failed" here loops forever on an empty send,
    // so name the real state instead.
    if (result.results.isEmpty && result.sent == 0) {
      AppSnackBar.error(tr('notify.no_seated_passengers'));
      return;
    }

    // Partial or total failure → summary dialog with a retry of only the
    // recipients that didn't go through.
    final failedIds =
        batch.where((p) => !justSent.contains(p.id)).map((p) => p.id).toSet();
    final retry = await UgamDialog.confirm(
      context,
      title: result.anySent
          ? tr('notify.alloc_partial_title')
          : tr('notify.alloc_failed_title'),
      message: result.anySent
          ? '${tr('notify.alloc_partial_body', namedArgs: {
              'sent': '${result.sent}',
              'failed': '${failedIds.length}',
            })}${waFailureAppendix(result)}'
          : '${tr('notify.alloc_failed_body')}${waFailureAppendix(result)}',
      cancelLabel: tr('app.action.cancel'),
      confirmLabel:
          tr('notify.alloc_retry', namedArgs: {'count': '${failedIds.length}'}),
      confirmIcon: Icons.refresh_rounded,
    );
    if (retry && mounted && failedIds.isNotEmpty) {
      await _dispatchSeatAllocations(t, failedIds);
    }
  }

  /// ADMIN per-bus announcement (F4). Opens a composer where the agent picks a
  /// bus (auto-selected when there's only one) and types a free-text message,
  /// then sends it to every passenger seated on that bus via the Cloud API.
  Future<void> _openBusMessageComposer(Tour tour) async {
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    if (t.buses.isEmpty) return;
    await UgamSheet.show<void>(
      context,
      title: tr('bus_message.composer_title'),
      builder: (sheetCtx) => _BusMessageComposer(
        buses: t.buses,
        recipientCountFor: (busId) => t.passengers
            .where((p) => p.assignedSeats.any((a) => a.busId == busId))
            .length,
        onSend: (busId, text) async {
          final result = await WhatsAppOutbound().sendBusMessage(
            tour: t,
            busId: busId,
            messageText: text,
          );
          if (!mounted) return;
          if (result.allSent) {
            AppSnackBar.success(
              tr('bus_message.sent_body', namedArgs: {'count': '${result.sent}'}),
              title: tr('bus_message.sent_title'),
            );
          } else if (result.anySent) {
            AppSnackBar.warning(
              '${tr('bus_message.partial_body', namedArgs: {
                'sent': '${result.sent}',
                'failed': '${result.failed}',
              })}${waFailureAppendix(result)}',
              title: tr('bus_message.partial_title'),
            );
          } else if (result.results.isEmpty && result.sent == 0) {
            AppSnackBar.warning(tr('bus_message.no_recipients'));
          } else {
            AppSnackBar.error(
              '${tr('bus_message.failed_body')}${waFailureAppendix(result)}',
              title: tr('bus_message.failed_title'),
            );
          }
        },
      ),
    );
  }
}
