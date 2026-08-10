import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../controllers/pickup_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/pickup_location.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/chart_advance_payment.dart';
import '../services/customer_requests_store.dart';
import '../services/seat_chart_booking_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/chart_selection.dart';
import '../utils/formatters.dart';
import '../utils/phone_normalize.dart';

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
  final TripType leg;

  /// The buses this checkout covers. Usually one; more than one when a party
  /// chose to split across buses (migration 068).
  final List<ChartBusSelection> selections;

  final double totalRupees;

  const SeatBookingConfirmScreen({
    super.key,
    required this.tour,
    required this.leg,
    required this.selections,
    required this.totalRupees,
  });

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
    if (!_validate()) return;
    setState(() => _saving = true);

    final requestId = const Uuid().v4();
    final phone = normalisePhone(_phone.text.trim());
    final name = _name.text.trim();
    final useHold = widget.tour.collectsAdvance;

    try {
      if (widget.isMultiBus) {
        await _confirmMultiBus(phone: phone, name: name, useHold: useHold);
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.error(tr('seat_confirm.err_failed'));
      debugPrint('chart claim failed — $e');
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
  }) async {
    final partyId = const Uuid().v4();
    final buses = [
      for (final s in widget.selections)
        BusClaim(
          busId: s.bus.id,
          requestId: const Uuid().v4(),
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
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xl,
                ),
                children: [
                  _summary(c),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamInput(
                    label: tr('seat_confirm.name_label'),
                    controller: _name,
                    errorText: _nameError,
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  UgamInput(
                    label: tr('seat_confirm.phone_label'),
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    errorText: _phoneError,
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  _genderRow(c),
                  const SizedBox(height: UgamSpacing.sm),
                  UgamPickerField(
                    label: tr('seat_confirm.pickup_label'),
                    value: _pickup?.name ?? '',
                    placeholder: tr('seat_confirm.pickup_hint'),
                    icon: Icons.place_outlined,
                    onTap: _pickPickup,
                  ),
                  if (_pickupError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                        _pickupError!,
                        style: UgamText.micro.copyWith(color: c.danger),
                      ),
                    ),
                  const SizedBox(height: UgamSpacing.sm),
                  UgamInput(
                    label: tr('seat_confirm.note_label'),
                    controller: _note,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
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

  Widget _summary(UgamColorSet c) {
    final seats = _solePicks
        .map((p) => p.berths > 1 ? '${p.seatId} ×${p.berths}' : p.seatId)
        .join(' · ');
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.tour.fromCity} → ${widget.tour.toCity}',
            style: UgamText.titleS.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            '${_soleBus.name} · ${_legLabel()}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            seats,
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.accent),
            ),
          ),
        ],
      ),
    );
  }

  String _legLabel() {
    switch (widget.leg) {
      case TripType.roundTrip:
        return tr('seat_pick.leg_round');
      case TripType.outboundOnly:
        return tr('seat_pick.leg_go');
      case TripType.returnOnly:
        return tr('seat_pick.leg_return');
    }
  }

  /// Gender drives the ladies marker other customers see on the chart — a
  /// marker, never a name. Optional: a rider who declines simply shows as a
  /// neutral booked seat.
  Widget _genderRow(UgamColorSet c) {
    Widget opt(String? value, String label) {
      final on = _gender == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _gender = value),
          child: Container(
            margin: const EdgeInsets.only(right: UgamSpacing.xs),
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? c.cardElev : Colors.transparent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(color: on ? c.ink3 : c.border),
            ),
            child: Text(
              label,
              style: UgamText.caption.copyWith(
                color: on ? c.ink : c.ink2,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        opt('female', tr('seat_confirm.gender_female')),
        opt('male', tr('seat_confirm.gender_male')),
        opt(null, tr('seat_confirm.gender_skip')),
      ],
    );
  }
}
