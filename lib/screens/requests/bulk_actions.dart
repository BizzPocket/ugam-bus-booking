part of '../requests_screen.dart';

// ─── Bulk selection actions ───────────────────────────────────────────

extension _RequestsBulkActions on _RequestsScreenState {
  Future<void> _bulkWaitlist(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      await tourCtrl.setWaitlisted(tour.id, id, true);
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.snack.bulk_waitlisted', namedArgs: {'n': '${ids.length}'}),
    );
    _exitSelection();
  }

  /// Confirm every selected New/waitlisted request in one tap — mirrors the
  /// per-card Confirm exactly: clears any waitlist flag AND auto-sends each
  /// passenger the Cloud `seat_allocation` confirmation template (no manual
  /// WhatsApp tap). Already-assigned passengers are ignored (they're past the
  /// confirm stage).
  Future<void> _bulkConfirm(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    var confirmed = 0;
    var sent = 0;
    var failed = 0;
    String? waError;
    for (final id in ids) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null || p.isFullyAssigned) continue;
      await tourCtrl.setConfirmed(tour.id, id, true);
      confirmed++;
      // Same send as the per-card _confirm(): the dedicated confirm template,
      // fired automatically so confirming IS messaging.
      try {
        final result = await WhatsAppOutbound().sendConfirmed(
          tour: tour,
          passenger: p,
        );
        if (result.anySent) {
          sent++;
        } else {
          failed++;
          // Keep the FIRST real reason from the run. A bulk confirm that
          // reported only "3 failed" gave the agent nothing to act on — if
          // every send is failing for one reason (a template rejection, a
          // number off the allowed list), that reason is the whole story.
          waError ??= waFailureAppendix(result);
        }
      } catch (e) {
        failed++;
        waError ??= '\n$e';
      }
    }
    if (!mounted) return;
    if (failed == 0) {
      AppSnackBar.success(
        tr(
          'requests.bulk.confirmed_sent',
          namedArgs: {'n': '$confirmed', 'sent': '$sent'},
        ),
      );
    } else {
      AppSnackBar.warning(
        '${tr(
          'requests.bulk.confirmed_sent_partial',
          namedArgs: {'n': '$confirmed', 'sent': '$sent', 'failed': '$failed'},
        )}${waError ?? ''}',
      );
    }
    _exitSelection();
  }

  Future<void> _bulkSendWA(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    int opened = 0;
    for (final id in ids) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null) continue;
      final ok = await WhatsAppService().sendAck(passenger: p, tour: tour);
      if (ok) opened++;
    }
    if (!mounted) return;
    if (opened > 0) {
      AppSnackBar.success(
        tr('requests.snack.bulk_wa_opened', namedArgs: {'n': '$opened'}),
      );
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
    _exitSelection();
  }

  /// Promote every selected passenger off the waitlist back into New. Only
  /// offered while the Waitlist filter is active (see [_BulkActionBar]).
  Future<void> _bulkPromote(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      await tourCtrl.setWaitlisted(tour.id, id, false);
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.bulk.promoted', namedArgs: {'n': '${ids.length}'}),
    );
    _exitSelection();
  }

  /// Decline (delete) every selected request after one confirm. Destructive,
  /// so it goes through [UgamDialog.confirm] like the per-card decline.
  Future<void> _bulkDecline(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    if (ids.isEmpty) return;
    final selectedPassengers = [
      for (final id in ids)
        tour.passengers.firstWhereOrNull((p) => p.id == id),
    ].whereType<Passenger>().toList();
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.bulk.decline_title'),
      message: tr(
        'requests.bulk.decline_body',
        namedArgs: {'n': '${ids.length}'},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.bulk.decline_confirm'),
      destructive: true,
      confirmIcon: Icons.close_rounded,
    );
    if (!confirmed) return;
    for (final id in ids) {
      await tourCtrl.removePassenger(tour.id, id);
    }
    var waSent = 0;
    var waFailed = 0;
    var waError = '';
    if (selectedPassengers.isNotEmpty) {
      try {
        final wa = await WhatsAppOutbound().sendRequestCancelledBatch(
          tour: tour,
          passengers: selectedPassengers,
        );
        waSent = wa.sent;
        waFailed = wa.failed;
        waError = waFailureAppendix(wa);
      } catch (e) {
        waFailed = selectedPassengers.length;
        waError = '\n$e';
      }
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.bulk.declined', namedArgs: {'n': '${ids.length}'}),
    );
    if (waFailed > 0) {
      AppSnackBar.warning(
        '${tr('requests.bulk.declined_wa_partial', namedArgs: {
              'n': '${ids.length}',
              'sent': '$waSent',
              'failed': '$waFailed',
            })}$waError',
      );
    }
    _exitSelection();
  }
}
