part of '../tour_controller.dart';

/// Implicit confirm-on-seat + the WhatsApp message it sends.
mixin _TourSeatNotify on _TourPassengers {
  /// Sends the customer-facing WhatsApp "booking confirmed" greeting for ONE
  /// passenger and reports whether Meta accepted it. Held as a field (rather
  /// than a direct `WhatsAppOutbound()` call) so tests can stub the network;
  /// production uses the real Cloud API sender. Invoked by
  /// [_confirmAndNotifyOnSeat] when a seat is placed on a rider who was never
  /// confirmed through the Requests screen.
  Future<bool> Function(Tour tour, Passenger passenger) confirmedSender =
      _sendConfirmedGreeting;

  static Future<bool> _sendConfirmedGreeting(Tour tour, Passenger p) async {
    final res = await WhatsAppOutbound().sendConfirmed(tour: tour, passenger: p);
    return res.anySent;
  }

  /// AFTER-LOCK counterpart of [confirmedSender]: the full `seat_allotment` —
  /// the rider's own highlighted seat chart as the image header, plus bus,
  /// boarding place, departure date/time and handler contact. Same stub seam so
  /// tests can assert WHICH message a seat placement produced without a network.
  ///
  /// Chosen by [_broadcastConfirmed] via
  /// [WhatsAppOutbound.shouldSendFullAllotment], which is the same decision the
  /// Requests screen's re-notify already makes.
  Future<bool> Function(Tour tour, Passenger passenger) allotmentSender =
      _sendSeatAllotment;

  static Future<bool> _sendSeatAllotment(Tour tour, Passenger p) async {
    final res = await WhatsAppOutbound()
        .sendSeatAllocations(tour: tour, onlyPassengerIds: {p.id});
    return res.anySent;
  }

  /// Implicit confirmation for seats placed from the CHART. The app's model is
  /// "Confirm → then seat": the Requests "Confirm" button both flips
  /// `isConfirmed` and fires the WhatsApp greeting. But a seat can also be placed
  /// straight from the chart (tap-to-place, auto-fill, group move) on a rider who
  /// was never confirmed — historically that seated them SILENTLY, with no
  /// message. This closes that gap: any of [passengerIds] who now holds a seat
  /// while still unconfirmed is confirmed (persisted) AND sent the same greeting,
  /// so a seat assigned from ANY surface always notifies the customer.
  ///
  /// Idempotent: an already-confirmed rider is skipped, so re-seating / moving /
  /// swapping never re-sends, and the front-door Confirm flow never double-sends.
  /// The WhatsApp send is fire-and-forget so seat placement is never blocked on
  /// the network.
  Future<void> _confirmAndNotifyOnSeat(
    String tourId,
    Iterable<String> passengerIds,
  ) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final newly = <Passenger>[];
    for (final id in passengerIds.toSet()) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null || p.isConfirmed || p.assignedSeats.isEmpty) continue;
      newly.add(p);
    }
    if (newly.isEmpty) return;

    for (final p in newly) {
      await setConfirmed(tourId, p.id, true);
    }
    // Re-read AFTER the confirms land: [_broadcastConfirmed] may render each
    // rider's seat chart off this tour, so it must see the roster as it now
    // stands, not the snapshot taken before the loop above.
    unawaited(_broadcastConfirmed(getTour(tourId) ?? tour, newly));
  }

  /// Fires the WhatsApp confirmation to each freshly-confirmed rider (bounded to
  /// what [_confirmAndNotifyOnSeat] just flipped) and surfaces a SINGLE summary
  /// toast — never one-per-rider, so a bulk auto-fill doesn't spam. A
  /// per-recipient failure is logged and skipped, never thrown.
  ///
  /// *** WHICH MESSAGE EACH RIDER GETS ***
  /// Per rider, via [WhatsAppOutbound.shouldSendFullAllotment] — the same
  /// decision the Requests screen's re-notify makes, so a seat placed from the
  /// CHART no longer says something different from the identical placement made
  /// from Requests:
  ///   * tour locked/completed + rider holds seats → the full `seat_allotment`
  ///     (their highlighted chart image + bus + boarding place + departure +
  ///     handler contact). Seat numbers are final, so this is what they need.
  ///   * anything earlier → the lighter greeting. Pre-lock seats are
  ///     provisional and the app deliberately does not publish them yet.
  ///
  /// This is the RETURN phase's whole story: `Tour.isReturnPhase` requires the
  /// tour to be locked, so every return ticket seated from the chart took the
  /// first branch's condition and yet was sent the greeting — a bare "booking
  /// confirmed" with no seat, no bus and no boarding point, while the chart it
  /// should have carried was rendered and dropped.
  Future<void> _broadcastConfirmed(Tour tour, List<Passenger> passengers) async {
    var sent = 0;
    // Riders whose message actually NAMED their seats. Only these may have
    // their notified-signature stamped below.
    final allotted = <String>[];
    for (final p in passengers) {
      try {
        final full = WhatsAppOutbound.shouldSendFullAllotment(tour, p);
        final ok = await (full ? allotmentSender : confirmedSender)(tour, p);
        if (!ok) continue;
        sent++;
        if (full) allotted.add(p.id);
      } catch (e) {
        dev.log('auto-confirm WhatsApp failed for ${p.id}: $e',
            name: 'TourController');
      }
    }
    // Record that these riders have been told about the seats they hold RIGHT
    // NOW, so the Notify screen's tracker and the tour's "re-notify" next
    // action don't immediately demand a second send of the message that just
    // went out. Deliberately skipped for the greeting (it names no seat) and
    // for a refused send (the rider has nothing in hand, so they stay pending).
    if (allotted.isNotEmpty) {
      try {
        await markSeatsNotified(tour.id, allotted);
      } catch (e) {
        dev.log('markSeatsNotified after auto-allotment failed: $e',
            name: 'TourController');
      }
    }
    if (sent <= 0) return;
    try {
      final chart = allotted.length == sent;
      AppSnackBar.success(
        passengers.length == 1
            ? tr(
                chart
                    ? 'seat.auto_allotment_sent_one'
                    : 'seat.auto_confirm_sent_one',
                namedArgs: {'name': passengers.first.name})
            : tr(
                chart
                    ? 'seat.auto_allotment_sent_many'
                    : 'seat.auto_confirm_sent_many',
                namedArgs: {'count': '$sent'}),
      );
    } catch (_) {
      // The toast is best-effort feedback — never let a missing localization or
      // navigator context turn this fire-and-forget send into a crash.
    }
  }

  /// Persist that [passengerIds] have been WhatsApp-notified of their CURRENT
  /// seats: stamps each rider's [Passenger.seatSignature] onto
  /// `seats_notified_sig`. A later post-lock seat edit changes the live
  /// signature, re-flagging them as "changed" for the Notify screen's targeted
  /// re-notify. Silently skips ids that don't resolve.
  Future<void> markSeatsNotified(
    String tourId,
    Iterable<String> passengerIds,
  ) async {
    final ids = passengerIds.toSet();
    if (ids.isEmpty) return;
    await _writePassengerEdits(
      tourId,
      [
        for (final id in ids)
          (
            id: id,
            update: (p) => p.copyWith(seatsNotifiedSig: p.seatSignature),
          ),
      ],
      failure: tr('errors.save_seat_assignment'),
    );
  }
}
