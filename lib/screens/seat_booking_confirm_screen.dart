import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../controllers/pickup_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/pickup_location.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/chart_advance_payment.dart';
import '../services/customer_requests_store.dart';
import '../services/error_reporter.dart';
import '../services/seat_chart_booking_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/chart_selection.dart';
import '../utils/formatters.dart';
import '../utils/phone_normalize.dart';

part 'seat_booking_confirm/seat_booking_confirm_form.dart';

/// The ids one checkout ATTEMPT sends, kept stable across retries of the same
/// content.
///
/// On 2G a claim can land on the server and still time out on the phone. A
/// fresh id per tap made the retry a NEW claim for seats the first one had
/// just taken — so the rider was told "seats taken" for seats that were theirs,
/// and no ticket was saved on the phone. Re-sending the SAME ids lets the
/// server recognise its own landed claim (migration 100) and answer success.
@visibleForTesting
class ClaimAttemptIds {
  /// Everything the claim carries — see [claimSignature].
  final String signature;

  /// The single-bus request id (and the hold's request id).
  final String requestId;

  /// The multi-bus party id.
  final String partyId;

  /// One request id per bus id, for the multi-bus RPCs.
  final Map<String, String> busRequestIds;

  const ClaimAttemptIds({
    required this.signature,
    required this.requestId,
    required this.partyId,
    required this.busRequestIds,
  });
}

/// The ids for an attempt carrying [signature]: the [pending] attempt's ids
/// when it carried exactly the same content, else freshly minted ones (one
/// request id per bus in [busIds]). A changed form is a different booking.
@visibleForTesting
ClaimAttemptIds claimIdsFor(
  ClaimAttemptIds? pending,
  String signature,
  List<String> busIds, {
  String Function()? mint,
}) {
  if (pending != null && pending.signature == signature) return pending;
  final next = mint ?? () => const Uuid().v4();
  return ClaimAttemptIds(
    signature: signature,
    requestId: next(),
    partyId: next(),
    busRequestIds: {for (final id in busIds) id: next()},
  );
}

/// The content of a checkout, as one comparable string: who, which seats on
/// which bus (and leg), the boarding point, the note, and whether it holds.
@visibleForTesting
String claimSignature({
  required String tourId,
  required String phone,
  required String name,
  required List<ChartBusSelection> selections,
  required bool useHold,
  String? gender,
  String? note,
  String? pickupLocationId,
}) =>
    jsonEncode({
      'tour': tourId,
      'phone': phone,
      'name': name,
      'hold': useHold,
      'gender': gender,
      'note': note,
      'pickup': pickupLocationId,
      'buses': [
        for (final s in selections)
          {
            'bus': s.bus.id,
            'seats': claimPayload(s.picks),
          },
      ],
    });

/// Passenger details, then the atomic claim, then the advance QR.
///
/// *** THE RULE THIS SCREEN EXISTS TO ENFORCE ***
/// A lost seat NEVER clears what the customer typed. The loudest complaint
/// across operator-app reviews in this market is being made to re-enter
/// everything after a seat is taken mid-checkout — one reviewer re-entered
/// their details three times and gave up ("finally I was forced to book private
/// bus"). On a conflict we keep the form, name the lost seats, and send them
/// back to re-pick only those.
class SeatBookingConfirmScreen extends StatefulWidget {
  final Tour tour;

  /// The buses this checkout covers. Usually one; more than one when a party
  /// chose to split across buses (migration 068).
  final List<ChartBusSelection> selections;

  final double totalRupees;

  const SeatBookingConfirmScreen({
    super.key,
    required this.tour,
    required this.selections,
    required this.totalRupees,
  });

  /// The COARSE trip type this booking reports as, derived from the picks.
  ///
  /// It is no longer passed in: with per-seat legs there is no single customer
  /// answer to pass. `booking_requests.trip_type` has always been a summary in
  /// request mode, and this makes chart mode agree.
  TripType get leg => summaryLegOf([
        for (final s in selections) ...s.picks,
      ]);

  /// True when this checkout has to go through the multi-bus RPCs. A one-bus
  /// booking deliberately keeps using migration 048's existing, proven path.
  bool get isMultiBus => selections.length > 1;

  @override
  State<SeatBookingConfirmScreen> createState() =>
      _SeatBookingConfirmScreenState();
}

class _SeatBookingConfirmScreenState extends State<SeatBookingConfirmScreen> {
  final _service = SeatChartBookingService();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();

  String? _gender; // 'male' | 'female' | null

  /// The ids of the last attempt that did NOT get a definitive answer (it
  /// threw — a timeout, a dropped socket). A retry of the same content re-uses
  /// them; see [ClaimAttemptIds]. Cleared on any definitive server answer.
  ClaimAttemptIds? _pendingClaim;
  PickupLocation? _pickup;
  bool _saving = false;
  String? _nameError;
  String? _phoneError;
  String? _pickupError;

  /// Berths across every bus in this checkout.
  int get _berths =>
      widget.selections.fold<int>(0, (sum, s) => sum + s.berths);

  /// The single-bus shortcuts, valid only when [SeatBookingConfirmScreen
  /// .isMultiBus] is false.
  Bus get _soleBus => widget.selections.first.bus;
  List<ChartPick> get _solePicks => widget.selections.first.picks;

  /// [setState] for the form extension in `seat_booking_confirm/` — an
  /// extension is not a [State] subclass, so it may not call the protected
  /// member directly. Plain pass-through.
  void _update(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  bool _validate() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    setState(() {
      _nameError = name.isEmpty ? tr('seat_confirm.err_name') : null;
      _phoneError = normalisePhone(phone).length < 10
          ? tr('seat_confirm.err_phone')
          : null;
      _pickupError = _pickup == null ? tr('seat_confirm.err_pickup') : null;
    });
    return _nameError == null && _phoneError == null && _pickupError == null;
  }

  Future<void> _confirm() async {
    // `_saving` disables the button, but only from the next frame.
    if (_saving) return;
    if (!_validate()) return;
    setState(() => _saving = true);

    final phone = normalisePhone(_phone.text.trim());
    final name = _name.text.trim();
    final useHold = widget.tour.collectsAdvance;
    final ids = claimIdsFor(
      _pendingClaim,
      claimSignature(
        tourId: widget.tour.id,
        phone: phone,
        name: name,
        selections: widget.selections,
        useHold: useHold,
        gender: _gender,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        pickupLocationId: _pickup?.id,
      ),
      [for (final s in widget.selections) s.bus.id],
    );
    // Held until the server answers — only a THROWN attempt (no answer at all)
    // leaves it in place for the retry to re-use.
    _pendingClaim = ids;
    final requestId = ids.requestId;

    try {
      if (widget.isMultiBus) {
        await _confirmMultiBus(
          phone: phone,
          name: name,
          useHold: useHold,
          ids: ids,
        );
        return;
      }

      if (useHold) {
        final hold = await _service.hold(
          requestId: requestId,
          tourId: widget.tour.id,
          busId: _soleBus.id,
          phone: phone,
          name: name,
          leg: widget.leg,
          picks: _solePicks,
          gender: _gender,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          pickupLocationId: _pickup?.id,
          pickupLocationName: _pickup?.name,
        );

        // The server answered: whatever it said, the next tap is a new attempt.
        _pendingClaim = null;
        if (!mounted) return;

        if (!hold.ok) {
          setState(() => _saving = false);
          if (hold.lostSeats) {
            AppSnackBar.error(
              tr('seat_confirm.err_seats_gone', namedArgs: {
                'seats': hold.conflicts.join(', '),
              }),
            );
            Navigator.of(context).pop(false);
          } else {
            AppSnackBar.error(
              hold.errorMessage ?? tr('seat_confirm.err_failed'),
            );
          }
          return;
        }

        await CustomerRequestsStore().upsert(
          CustomerRequestEntry(
            id: requestId,
            tourId: widget.tour.id,
            tourTitle: widget.tour.title,
            tourFromCity: widget.tour.fromCity,
            tourToCity: widget.tour.toCity,
            tourDepartureDate: widget.tour.departureDate,
            tourPricePerSeat: widget.tour.pricePerSeat,
            customerName: name,
            customerPhone: phone,
            partySize: _berths,
            doubleSofa: 0,
            singleSofa: 0,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            pickupLocationId: _pickup?.id,
            pickupLocationName: _pickup?.name,
            tripType: widget.leg,
            // 'held', not 'pending': this booking has NO booking_requests row
            // until the advance is confirmed, so anything that reconciles
            // against the server must know to ask the holds table instead of
            // concluding the request was deleted.
            status: 'held',
            isConfirmed: false,
            organiserPhone: widget.tour.createdBy,
            createdAt: DateTime.now(),
            // Everything the "Pay advance" retry in My Requests needs, captured
            // now so it works offline and cannot be re-quoted later.
            holdExpiresAt: hold.expiresAt,
            holdId: hold.holdId,
            advancePaise: _advancePaise,
            collectVpa: widget.tour.collectVpa,
            collectPayeeName: widget.tour.collectPayeeName,
          ),
        );

        if (!mounted) return;
        setState(() => _saving = false);

        await _offerAdvance(
          requestId: requestId,
          name: name,
          holdId: hold.holdId,
        );
        if (!mounted) return;
        AppSnackBar.success(tr('seat_confirm.success_held'));
        Navigator.of(context).pop(true);
        return;
      }

      final result = await _service.claim(
        requestId: requestId,
        tourId: widget.tour.id,
        busId: _soleBus.id,
        phone: phone,
        name: name,
        leg: widget.leg,
        picks: _solePicks,
        gender: _gender,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        pickupLocationId: _pickup?.id,
        pickupLocationName: _pickup?.name,
      );

      _pendingClaim = null;
      if (!mounted) return;

      if (!result.ok) {
        setState(() => _saving = false);
        if (result.lostSeats) {
          AppSnackBar.error(
            tr('seat_confirm.err_seats_gone', namedArgs: {
              'seats': result.conflicts.join(', '),
            }),
          );
          Navigator.of(context).pop(false);
        } else {
          AppSnackBar.error(
            result.errorMessage ?? tr('seat_confirm.err_failed'),
          );
        }
        return;
      }

      await CustomerRequestsStore().upsert(
        CustomerRequestEntry(
          id: requestId,
          tourId: widget.tour.id,
          tourTitle: widget.tour.title,
          tourFromCity: widget.tour.fromCity,
          tourToCity: widget.tour.toCity,
          tourDepartureDate: widget.tour.departureDate,
          tourPricePerSeat: widget.tour.pricePerSeat,
          customerName: name,
          customerPhone: phone,
          partySize: _berths,
          doubleSofa: 0,
          singleSofa: 0,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          pickupLocationId: _pickup?.id,
          pickupLocationName: _pickup?.name,
          tripType: widget.leg,
          status: 'pending',
          isConfirmed: true,
          organiserPhone: widget.tour.createdBy,
          createdAt: DateTime.now(),
        ),
      );

      if (!mounted) return;
      setState(() => _saving = false);

      AppSnackBar.success(tr('seat_confirm.success'));
      Navigator.of(context).pop(true);
    } catch (e, st) {
      // Reported, not printed: a debugPrint never left the device.
      ErrorReporter.report(kind: 'chart_claim', error: e, stack: st);
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.error(tr('seat_confirm.err_failed'));
    }
  }

  /// Checkout for a party split across buses (migration 068).
  ///
  /// Each bus gets its OWN request id, because the server writes one
  /// booking_request + one passenger per bus — that is what keeps every
  /// passenger's seats inside a single bus and leaves billing, the handler
  /// manifest and the WhatsApp ticket working untouched.
  ///
  /// The claim is all-or-nothing ACROSS buses: a seat lost on the second bus
  /// rolls back the first, so a party is never left half-booked with money
  /// owing on seats they cannot use.
  Future<void> _confirmMultiBus({
    required String phone,
    required String name,
    required bool useHold,
    required ClaimAttemptIds ids,
  }) async {
    final partyId = ids.partyId;
    final buses = [
      for (final s in widget.selections)
        BusClaim(
          busId: s.bus.id,
          requestId: ids.busRequestIds[s.bus.id] ?? const Uuid().v4(),
          picks: s.picks,
        ),
    ];
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();

    if (useHold) {
      final held = await _service.holdMulti(
        partyId: partyId,
        tourId: widget.tour.id,
        phone: phone,
        name: name,
        leg: widget.leg,
        buses: buses,
        gender: _gender,
        note: note,
        pickupLocationId: _pickup?.id,
        pickupLocationName: _pickup?.name,
      );
      _pendingClaim = null;
      if (!mounted) return;
      if (!held.ok) {
        setState(() => _saving = false);
        _reportMultiFailure(held.conflicts, held.errorMessage);
        return;
      }

      // One local ticket PER BUS, mirroring the server. Each carries its own
      // hold id so "Pay advance" can be retried per bus if one claim fails.
      for (var i = 0; i < held.holds.length; i++) {
        final hold = held.holds[i];
        final selection = widget.selections.firstWhere(
          (s) => s.bus.id == hold.busId,
          orElse: () => widget.selections.first,
        );
        await CustomerRequestsStore().upsert(
          _entryFor(
            requestId: hold.requestId,
            name: name,
            phone: phone,
            berths: selection.berths,
            status: 'held',
            holdId: hold.holdId,
            holdExpiresAt: held.expiresAt,
            note: note,
            // ONE advance for the whole party, carried by the first ticket.
            // Putting the full amount on every per-bus ticket would show a
            // split party "Pay ₹3,000" twice and invite them to pay double.
            // The holds share a deadline and are finalized together server-side
            // by chart_finalize_party_holds.
            carriesAdvance: i == 0,
          ),
        );
      }

      if (!mounted) return;
      setState(() => _saving = false);
      // One sheet for the WHOLE party — the advance is quoted across buses,
      // and the holds share a single deadline.
      await _offerAdvance(
        requestId: held.holds.first.requestId,
        name: name,
        holdId: held.holds.first.holdId,
      );
      if (!mounted) return;
      AppSnackBar.success(tr('seat_confirm.success_held'));
      Navigator.of(context).pop(true);
      return;
    }

    final result = await _service.claimMulti(
      partyId: partyId,
      tourId: widget.tour.id,
      phone: phone,
      name: name,
      leg: widget.leg,
      buses: buses,
      gender: _gender,
      note: note,
      pickupLocationId: _pickup?.id,
      pickupLocationName: _pickup?.name,
    );
    _pendingClaim = null;
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _saving = false);
      _reportMultiFailure(result.conflicts, result.errorMessage);
      return;
    }

    for (final booking in result.bookings) {
      final selection = widget.selections.firstWhere(
        (s) => s.bus.id == booking.busId,
        orElse: () => widget.selections.first,
      );
      await CustomerRequestsStore().upsert(
        _entryFor(
          requestId: booking.requestId,
          name: name,
          phone: phone,
          berths: selection.berths,
          status: 'pending',
          isConfirmed: true,
          note: note,
        ),
      );
    }

    if (!mounted) return;
    setState(() => _saving = false);
    AppSnackBar.success(tr('seat_confirm.success'));
    Navigator.of(context).pop(true);
  }

  /// A lost seat names its BUS as well as its id — every sleeper on the tour
  /// has a "DU1", so a bare seat id would send the customer to the wrong chart.
  void _reportMultiFailure(
    List<PartyConflict> conflicts,
    String? errorMessage,
  ) {
    if (conflicts.isEmpty) {
      AppSnackBar.error(errorMessage ?? tr('seat_confirm.err_failed'));
      return;
    }
    final named = conflicts.map((c) {
      final bus = widget.selections
          .where((s) => s.bus.id == c.busId)
          .map((s) => s.bus.name)
          .firstOrNull;
      return bus == null ? c.seatId : '${c.seatId} ($bus)';
    }).join(', ');
    AppSnackBar.error(
      tr('seat_confirm.err_seats_gone', namedArgs: {'seats': named}),
    );
    Navigator.of(context).pop(false);
  }

  /// One device-local ticket. Shared by both multi-bus paths so a held and a
  /// claimed booking cannot drift apart in shape.
  CustomerRequestEntry _entryFor({
    required String requestId,
    required String name,
    required String phone,
    required int berths,
    required String status,
    String? note,
    String? holdId,
    DateTime? holdExpiresAt,
    bool isConfirmed = false,
    bool carriesAdvance = true,
  }) {
    return CustomerRequestEntry(
      id: requestId,
      tourId: widget.tour.id,
      tourTitle: widget.tour.title,
      tourFromCity: widget.tour.fromCity,
      tourToCity: widget.tour.toCity,
      tourDepartureDate: widget.tour.departureDate,
      tourPricePerSeat: widget.tour.pricePerSeat,
      customerName: name,
      customerPhone: phone,
      partySize: berths,
      doubleSofa: 0,
      singleSofa: 0,
      note: note,
      pickupLocationId: _pickup?.id,
      pickupLocationName: _pickup?.name,
      tripType: widget.leg,
      status: status,
      isConfirmed: isConfirmed,
      organiserPhone: widget.tour.createdBy,
      createdAt: DateTime.now(),
      holdExpiresAt: holdExpiresAt,
      holdId: holdId,
      advancePaise: (holdId == null || !carriesAdvance) ? 0 : _advancePaise,
      collectVpa: widget.tour.collectVpa,
      collectPayeeName: widget.tour.collectPayeeName,
    );
  }

  /// Advance due on this booking, in paise. Zero when the tour asks for none.
  int get _advancePaise {
    final perBerth = widget.tour.advancePerBerthPaise ?? 0;
    return perBerth > 0
        ? perBerth * _berths
        : (widget.totalRupees * 100).round();
  }

  /// Shows the advance sheet. Dismissing it is NOT a failure — the hold stands
  /// and My Requests carries a countdown plus a "Pay advance" retry, so the
  /// booking is recoverable. It used to be a dead end: this sheet was the only
  /// place a customer could ever pay.
  Future<void> _offerAdvance({
    required String requestId,
    required String name,
    String? holdId,
  }) async {
    final tour = widget.tour;
    if (_advancePaise <= 0) return;

    await ChartAdvancePayment.collect(
      context: context,
      requestId: requestId,
      holdId: holdId,
      payeeVpa: tour.collectVpa!,
      payeeName: (tour.collectPayeeName?.trim().isNotEmpty ?? false)
          ? tour.collectPayeeName!
          : tour.title,
      amountPaise: _advancePaise,
      note: '${tour.fromCity}-${tour.toCity} · $name',
      subtitle: (tour.advancePerBerthPaise ?? 0) > 0
          ? tr('seat_confirm.advance_note', namedArgs: {
              'total': Formatters.formatMoneyInr(widget.totalRupees),
            })
          : null,
    );
  }

  Future<void> _pickPickup() async {
    if (!Get.isRegistered<PickupController>()) return;
    final options = Get.find<PickupController>().active;
    if (options.isEmpty) return;
    final chosen = await UgamSheet.show<PickupLocation>(
      context,
      title: tr('seat_confirm.pickup_label'),
      builder: (_) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: UgamSpacing.xl),
        children: [
          for (final o in options)
            ListTile(
              title: Text(o.name),
              onTap: () => Navigator.of(context).pop(o),
            ),
        ],
      ),
    );
    if (chosen != null) {
      setState(() {
        _pickup = chosen;
        _pickupError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(showBack: true, title: tr('seat_confirm.title')),
            Expanded(child: _form(c)),
          ],
        ),
      ),
      bottomNavigationBar: UgamStickyCTA(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: Row(
                children: [
                  Text(
                    widget.tour.collectsAdvance
                        ? tr('seat_confirm.pay_on_bus')
                        : tr('seat_confirm.total'),
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                  const Spacer(),
                  Text(
                    Formatters.formatMoneyInr(widget.totalRupees),
                    style: UgamText.tabular(
                      UgamText.titleS.copyWith(color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
            UgamCTA(
              label: _berths == 1
                  ? tr('seat_confirm.cta_one')
                  : tr('seat_confirm.cta_many', namedArgs: {'n': '$_berths'}),
              leadingIcon: Icons.check_rounded,
              loading: _saving,
              onPressed: _saving ? null : _confirm,
            ),
          ],
        ),
      ),
    );
  }
}
