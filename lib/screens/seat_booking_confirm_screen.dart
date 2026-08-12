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

  /// The form, composed to FILL the viewport.
  ///
  /// It used to be a plain `ListView`, which left whatever height the fields
  /// did not use as dead air between the note field and the pay bar — the
  /// screen read as half-built. The body is now given a minimum height of the
  /// viewport and split into two blocks: the fields at the top and the
  /// "what happens when you tap confirm" line pinned to the bottom, directly
  /// above the CTA it is describing. Slack goes BETWEEN them, so on a tall
  /// phone the gap is a deliberate seam and on a short one (or with the
  /// keyboard up) the whole thing simply scrolls.
  Widget _form(UgamColorSet c) {
    // Must match the scroll padding below, so a form that exactly fits the
    // viewport does not gain a phantom scrollbar.
    const vPad = UgamSpacing.sm + UgamSpacing.lg;

    return AutofillGroup(
      child: LayoutBuilder(
        builder: (context, box) {
          final minH = box.maxHeight - vPad;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              UgamSpacing.sm,
              UgamSpacing.gutter,
              UgamSpacing.lg,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minH > 0 ? minH : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _fields(c),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: UgamSpacing.lg),
                    child: _nextStep(c),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _fields(UgamColorSet c) => [
        _summary(c),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('seat_confirm.name_label'),
          // Every field carries a hint. A filled, hint-less rounded rectangle
          // is pixel-for-pixel the app's own skeleton loader, so a form
          // without them reads as still loading rather than ready to type in.
          hint: tr('seat_confirm.name_hint'),
          controller: _name,
          keyboardType: TextInputType.name,
          autofillHints: const [AutofillHints.name],
          errorText: _nameError,
        ),
        const SizedBox(height: UgamSpacing.sm),
        UgamInput(
          label: tr('seat_confirm.phone_label'),
          hint: tr('seat_confirm.phone_hint'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          // The formatter `UgamPhoneInput` already ships: strip formatting as
          // it is typed and keep the LAST 10 digits, so a pasted
          // `+91 98765 43210` lands as a valid number rather than as 12 digits
          // the customer has to go back and edit.
          inputFormatters: const [IndianMobileFormatter()],
          maxLength: 10,
          autofillHints: const [AutofillHints.telephoneNumber],
          errorText: _phoneError,
        ),
        const SizedBox(height: UgamSpacing.sm),
        // The gender pills used to be the one unlabelled control in the form —
        // three grey lozenges with no caption. Labelled in the same
        // micro-caps as the inputs so the whole form reads as one system.
        UgamSectionLabel(tr('seat_confirm.gender_label'), color: c.ink2),
        const SizedBox(height: UgamSpacing.sm),
        _genderRow(c),
        const SizedBox(height: UgamSpacing.sm),
        // `UgamPickerField`'s own label is sentence-case `caption`, which does
        // not match the inputs above it, and it cannot turn red on error. The
        // label is therefore rendered here instead.
        UgamSectionLabel(
          tr('seat_confirm.pickup_label'),
          color: _pickupError != null ? c.danger : c.ink2,
        ),
        const SizedBox(height: UgamSpacing.sm),
        UgamPickerField(
          value: _pickup?.name ?? '',
          placeholder: tr('seat_confirm.pickup_hint'),
          icon: Icons.place_outlined,
          onTap: _pickPickup,
        ),
        if (_pickupError != null) _fieldError(c, _pickupError!),
        const SizedBox(height: UgamSpacing.sm),
        UgamInput(
          label: tr('seat_confirm.note_label'),
          hint: tr('seat_confirm.note_hint'),
          controller: _note,
          keyboardType: TextInputType.multiline,
          maxLines: 2,
        ),
      ];

  /// Mirrors the error line `UgamInput` paints under itself (glyph + words in
  /// danger ink), because the pickup field is not an input and cannot use it.
  /// The old version was bare micro text on a hand-typed 4px inset.
  Widget _fieldError(UgamColorSet c, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.error_outline_rounded,
              size: UgamScale.px(context, 14),
              color: c.danger,
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: UgamText.caption.copyWith(color: c.danger),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The one line that makes the bottom of this screen deliberate: what the
  /// CTA immediately below is actually about to do. A checkout that says "we
  /// hold the seats for 5 minutes" before you commit is the difference between
  /// a confident tap and a back button.
  Widget _nextStep(UgamColorSet c) {
    final holds = widget.tour.collectsAdvance;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            // The glyph's optical centre sits above its box; a flush top edge
            // reads as floating above the first line of text.
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              holds ? Icons.timer_outlined : Icons.verified_outlined,
              size: UgamScale.px(context, 14),
              color: c.ink3,
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.xs + 2),
        Expanded(
          child: Text(
            tr(holds ? 'seat_confirm.next_hold' : 'seat_confirm.next_confirm'),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
        ),
      ],
    );
  }

  /// The trip summary — the only settled fact on a screen full of empty
  /// fields, so it sits ON the page at [UgamElevationSet.rest] rather than
  /// being another flat grey rectangle level with the inputs. That depth is
  /// what `UgamCard` now applies for the whole app; this was hand-painting
  /// the same fill and hairline with no shadow at all.
  Widget _summary(UgamColorSet c) {
    // A split party (migration 068) has more than one bus, and naming only
    // the first one told a customer their whole party was on it.
    final multi = widget.selections.length > 1;
    final seatStyle = UgamText.tabular(
      UgamText.bodyStrong.copyWith(color: c.accent),
    );

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.tour.fromCity} → ${widget.tour.toCity}',
            style: UgamText.titleS.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            multi ? _legLabel() : '${_soleBus.name} · ${_legLabel()}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          for (var i = 0; i < widget.selections.length; i++) ...[
            if (i > 0) const SizedBox(height: UgamSpacing.xs),
            if (multi)
              Text(
                widget.selections[i].bus.name,
                style: UgamText.caption.copyWith(color: c.ink3),
              ),
            Text(_seatsOf(widget.selections[i]), style: seatStyle),
          ],
        ],
      ),
    );
  }

  String _seatsOf(ChartBusSelection selection) => selection.picks
      .map((p) => p.berths > 1 ? '${p.seatId} ×${p.berths}' : p.seatId)
      .join(' · ');

  /// A mixed booking must SAY it is mixed. Collapsing it to the coarse
  /// round-trip summary would tell a family that everyone is coming back.
  String _legLabel() {
    final picks = [for (final s in widget.selections) ...s.picks];
    final legs = picks.map((p) => p.leg).toSet();
    if (legs.length > 1) return tr('seat_confirm.leg_mixed');
    switch (legs.isEmpty ? TripType.roundTrip : legs.first) {
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
        // Was a bare GestureDetector: it fired, but the finger got nothing
        // back — no scale, no haptic — which is what made the row read as a
        // mockup next to the CTA.
        child: UgamTappable(
          onTap: () => setState(() => _gender = value),
          pressedScale: 0.95,
          child: Container(
            // Floored at the 44pt tap minimum. The padding alone resolved to
            // ~32pt, so all three pills were under-target.
            height: UgamScale.tap(context, 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xs),
            decoration: BoxDecoration(
              color: on ? c.cardElev : Colors.transparent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(color: on ? c.ink3 : c.border),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              // Gujarati runs ~30% longer than the English source and
              // "Prefer not to say" is the longest option in every locale —
              // it wraps to a second line inside the pill rather than
              // overflowing the row.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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
        // A gap BETWEEN the pills, not a trailing margin on each — the old
        // right margin left the last pill 4px short of the fields above it.
        const SizedBox(width: UgamSpacing.xs),
        opt('male', tr('seat_confirm.gender_male')),
        const SizedBox(width: UgamSpacing.xs),
        opt(null, tr('seat_confirm.gender_skip')),
      ],
    );
  }
}
