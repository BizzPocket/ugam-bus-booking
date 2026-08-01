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
import '../services/customer_requests_store.dart';
import '../services/seat_chart_booking_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/chart_selection.dart';
import '../utils/formatters.dart';
import '../utils/phone_normalize.dart';
import '../utils/upi_uri.dart';
import '../widgets/upi_payment_sheet.dart';

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
  final Bus bus;
  final TripType leg;
  final List<ChartPick> picks;
  final double totalRupees;

  const SeatBookingConfirmScreen({
    super.key,
    required this.tour,
    required this.bus,
    required this.leg,
    required this.picks,
    required this.totalRupees,
  });

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

  int get _berths => totalBerths(widget.picks);

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

    try {
      final result = await _service.claim(
        requestId: requestId,
        tourId: widget.tour.id,
        busId: widget.bus.id,
        phone: phone,
        name: name,
        leg: widget.leg,
        picks: widget.picks,
        gender: _gender,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        pickupLocationId: _pickup?.id,
        pickupLocationName: _pickup?.name,
      );

      if (!mounted) return;

      if (!result.ok) {
        setState(() => _saving = false);
        if (result.lostSeats) {
          // KEEP THE FORM. Name what was lost and send them back to re-pick.
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

      // Keep a device-local ticket so "My Tickets" can track it.
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

      // The seat is already theirs. If the tour asks for an advance, offer the
      // QR now — but the booking stands whether or not they pay here.
      if (widget.tour.collectsAdvance) {
        await _offerAdvance(requestId, name);
      }
      if (!mounted) return;
      AppSnackBar.success(tr('seat_confirm.success'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.error(tr('seat_confirm.err_failed'));
      debugPrint('chart claim failed — $e');
    }
  }

  Future<void> _offerAdvance(String requestId, String name) async {
    final tour = widget.tour;
    final perBerth = tour.advancePerBerthPaise ?? 0;
    // A policy of 0 means "the whole amount due"; otherwise it's per berth.
    final paise = perBerth > 0
        ? perBerth * _berths
        : (widget.totalRupees * 100).round();
    if (paise <= 0) return;

    await showUpiPaymentSheet(
      context,
      request: collectPayment(
        vpa: tour.collectVpa!,
        payeeName: (tour.collectPayeeName?.trim().isNotEmpty ?? false)
            ? tour.collectPayeeName!
            : tour.title,
        amountPaise: paise,
        note: '${tour.fromCity}-${tour.toCity} · $name',
        bookingRef: requestId,
      ),
      title: tr('seat_confirm.advance_title'),
      subtitle: perBerth > 0
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
    final seats = widget.picks
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
            '${widget.bus.name} · ${_legLabel()}',
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
