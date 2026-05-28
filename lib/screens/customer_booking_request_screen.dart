import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/phone_normalize.dart';

/// Customer-side seat request form — image-5 fidelity.
///
/// Two modes:
///   • Create  — [existing] is null. Inserts into booking_requests + upserts
///     into passengers, then opens WhatsApp with the standard request message.
///   • Edit    — [existing] is non-null. Calls booking_request_customer_update
///     RPC (which atomically updates both tables and stamps customer_edited_at),
///     then opens WhatsApp with an "updated request" variant message so the
///     organiser sees this isn't a fresh ping.
///
/// Visual treatment matches admin's create_tour_screen.dart: tour preview
/// card on top + single-column UgamInput fields + sticky bottom UgamCTA
/// with passenger-count chip.
///
/// Seat choices are intentionally limited to Double Sofa and Single Sofa.
/// The agent decides upper/lower berth assignment later, so the customer
/// doesn't have to think about it.
class CustomerBookingRequestScreen extends StatefulWidget {
  final Tour tour;
  final CustomerRequestEntry? existing;

  const CustomerBookingRequestScreen({
    super.key,
    required this.tour,
    this.existing,
  });

  bool get isEditing => existing != null;

  @override
  State<CustomerBookingRequestScreen> createState() =>
      _CustomerBookingRequestScreenState();
}

class _CustomerBookingRequestScreenState
    extends State<CustomerBookingRequestScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();

  int _doubleSofa = 0;
  int _singleSofa = 0;
  TripType _tripType = TripType.roundTrip;

  bool _saving = false;
  bool _showNote = false;

  int get _totalSeats => _doubleSofa + _singleSofa;
  double get _estTotal => widget.tour.pricePerSeat * _totalSeats;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.customerName;
      _phone.text = normalisePhone(e.customerPhone);
      _doubleSofa = e.doubleSofa;
      _singleSofa = e.singleSofa;
      _tripType = e.tripType;
      if (e.note != null && e.note!.isNotEmpty) {
        _note.text = e.note!;
        _showNote = true;
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  // ─── BUSINESS LOGIC — PRESERVED VERBATIM ───────────────────────────

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty) {
      AppSnackBar.error(tr('customer_booking.err_name_required'));
      return;
    }
    if (phone.length != 10) {
      AppSnackBar.error(tr('customer_booking.err_phone_invalid'));
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error(tr('customer_booking.err_no_seats'));
      return;
    }
    final adminPhone = widget.tour.createdBy;
    final hasOrganiser = adminPhone != null && adminPhone.isNotEmpty;

    setState(() => _saving = true);
    try {
      final note = _note.text.trim();
      final normalisedPhone = '+91${normalisePhone(phone)}';
      if (widget.isEditing) {
        await _submitEdit(
          name: name,
          normalisedPhone: normalisedPhone,
          note: note,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
      } else {
        await _submitCreate(
          name: name,
          rawPhone: phone,
          normalisedPhone: normalisedPhone,
          note: note,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
      }
    } catch (_) {
      AppSnackBar.error(tr('customer_booking.err_save_failed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitCreate({
    required String name,
    required String rawPhone,
    required String normalisedPhone,
    required String note,
    required String? adminPhone,
    required bool hasOrganiser,
  }) async {
    final requestId = const Uuid().v4();

    await Supabase.instance.client.from('booking_requests').insert({
      'id': requestId,
      'tour_id': widget.tour.id,
      'customer_phone': normalisedPhone,
      'customer_name': name,
      'party_size': _totalSeats,
      'trip_type': _tripType.storageKey,
      'raw_form': {
        'double_sofa': _doubleSofa,
        'single_sofa': _singleSofa,
        'trip_type': _tripType.storageKey,
        if (note.isNotEmpty) 'note': note,
      },
    });

    final requestLines = _buildRequestLines();
    final passenger = Passenger(
      tourId: widget.tour.id,
      name: name,
      phone: normalisedPhone,
      requestLines: requestLines,
      note: note.isEmpty ? null : note,
      tripType: _tripType,
    );
    await Supabase.instance.client
        .from('passengers')
        .upsert(passenger.toMap(), onConflict: 'tour_id,phone');

    await CustomerRequestsStore().upsert(CustomerRequestEntry(
      id: requestId,
      tourId: widget.tour.id,
      tourTitle: widget.tour.title,
      tourFromCity: widget.tour.fromCity,
      tourToCity: widget.tour.toCity,
      tourDepartureDate: widget.tour.departureDate,
      tourPricePerSeat: widget.tour.pricePerSeat,
      customerName: name,
      customerPhone: normalisedPhone,
      partySize: _totalSeats,
      doubleSofa: _doubleSofa,
      singleSofa: _singleSofa,
      note: note.isEmpty ? null : note,
      tripType: _tripType,
      status: 'pending',
      createdAt: DateTime.now(),
    ));

    if (hasOrganiser && Get.isRegistered<UserController>()) {
      // ignore: unawaited_futures
      Get.find<UserController>().autoGrowFromBooking(
        tourCreatorPhone: adminPhone!,
        passengerPhone: rawPhone,
        passengerName: name,
      );
    }

    if (hasOrganiser) {
      await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone!,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: _singleSofa,
        doubleSofaCount: _doubleSofa,
        note: note.isEmpty ? null : note,
        tripType: _tripType,
      );
    }

    if (!mounted) return;
    Get.back();
    AppSnackBar.success(
      hasOrganiser
          ? tr('customer_booking.success_sent_wa')
          : tr('customer_booking.success_sent_no_wa'),
      title: tr('customer_booking.success_title_submitted'),
    );
  }

  Future<void> _submitEdit({
    required String name,
    required String normalisedPhone,
    required String note,
    required String? adminPhone,
    required bool hasOrganiser,
  }) async {
    final existing = widget.existing!;
    final requestLines = _buildRequestLines();
    final requestLinesJson =
        requestLines.map((rl) => rl.toMap()).toList();

    final ok = await Supabase.instance.client.rpc(
      'booking_request_customer_update',
      params: {
        'p_id': existing.id,
        'p_party_size': _totalSeats,
        'p_customer_name': name,
        'p_raw_form': {
          'double_sofa': _doubleSofa,
          'single_sofa': _singleSofa,
          'trip_type': _tripType.storageKey,
          if (note.isNotEmpty) 'note': note,
        },
        'p_request_lines': requestLinesJson,
        'p_trip_type': _tripType.storageKey,
      },
    );

    if (ok != true) {
      if (!mounted) return;
      AppSnackBar.warning(
        tr('customer_booking.warn_edit_blocked'),
        title: tr('customer_booking.warn_title_edit_blocked'),
      );
      // ignore: unawaited_futures
      CustomerRequestsStore().refresh(existing.id);
      return;
    }

    await CustomerRequestsStore().upsert(existing.copyWith(
      customerName: name,
      partySize: _totalSeats,
      doubleSofa: _doubleSofa,
      singleSofa: _singleSofa,
      note: note.isEmpty ? null : note,
      tripType: _tripType,
      customerEditedAt: DateTime.now(),
      lastRefreshedAt: DateTime.now(),
    ));

    if (hasOrganiser) {
      await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone!,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: _singleSofa,
        doubleSofaCount: _doubleSofa,
        note: note.isEmpty ? null : note,
        isUpdate: true,
      );
    }

    if (!mounted) return;
    Get.back();
    AppSnackBar.success(
      hasOrganiser
          ? tr('customer_booking.success_updated_wa')
          : tr('customer_booking.success_updated_no_wa'),
      title: tr('customer_booking.success_title_updated'),
    );
  }

  List<RequestLine> _buildRequestLines() => <RequestLine>[
        if (_doubleSofa > 0)
          RequestLine(seatType: SeatType.doubleSofa, qty: _doubleSofa),
        if (_singleSofa > 0)
          RequestLine(seatType: SeatType.singleSofa, qty: _singleSofa),
      ];

  // ─── UI ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              c: c,
              title: widget.isEditing
                  ? tr('customer_booking.title_edit')
                  : tr('customer_booking.title'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                children: [
                  _TourPreviewCard(tour: widget.tour, c: c),
                  const SizedBox(height: UgamSpacing.xl),
                  _SectionEyebrow(
                      label: tr('customer_booking.section_who_is_booking'),
                      c: c),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(
                    label: tr('customer_booking.label_your_name'),
                    hint: tr('customer_booking.hint_your_name'),
                    controller: _name,
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamPhoneInput(
                    controller: _phone,
                    label: tr('customer_booking.label_phone'),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  _SectionEyebrow(
                    label: tr('customer_booking.label_trip_type')
                        .toUpperCase(),
                    c: c,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  _TripTypeSelector(
                    value: _tripType,
                    fromCity: widget.tour.fromCity,
                    toCity: widget.tour.toCity,
                    onChanged: (v) => setState(() => _tripType = v),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  _SectionEyebrow(
                    label: tr('customer_booking.label_seat_count')
                        .toUpperCase(),
                    c: c,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  _SeatTile(
                    icon: Icons.king_bed_rounded,
                    label: tr('customer_booking.seat_double_sofa_label'),
                    sublabel: tr('customer_booking.seat_double_sofa_sub'),
                    value: _doubleSofa,
                    onChanged: (v) => setState(() => _doubleSofa = v),
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  _SeatTile(
                    icon: Icons.single_bed_rounded,
                    label: tr('customer_booking.seat_single_sofa_label'),
                    sublabel: tr('customer_booking.seat_single_sofa_sub'),
                    value: _singleSofa,
                    onChanged: (v) => setState(() => _singleSofa = v),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  if (!_showNote)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: () => setState(() => _showNote = true),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.md,
                            vertical: UgamSpacing.sm,
                          ),
                          decoration: BoxDecoration(
                            color: c.cardElev,
                            borderRadius:
                                BorderRadius.circular(UgamRadius.chip),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_rounded, size: 14, color: c.ink2),
                              const SizedBox(width: 4),
                              Text(
                                tr('customer_booking.add_note_button'),
                                style: UgamText.bodyStrong
                                    .copyWith(color: c.ink2, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    UgamInput(
                      label: tr('customer_booking.label_note'),
                      hint: tr('customer_booking.hint_note'),
                      controller: _note,
                      maxLength: 200,
                      autofocus: true,
                    ),
                  const SizedBox(height: UgamSpacing.md),
                  _Totals(
                      seatCount: _totalSeats, estTotal: _estTotal, c: c),
                ],
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: _saving
                    ? tr('customer_booking.button_saving')
                    : (widget.isEditing
                        ? tr('customer_booking.button_update')
                        : tr('customer_booking.button_submit')),
                leadingIcon: Icons.send_rounded,
                trailingValue:
                    _estTotal > 0 ? '₹${_estTotal.toStringAsFixed(0)}' : null,
                loading: _saving,
                onPressed: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TOP BAR ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  const _TopBar({required this.c, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              title,
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 22),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── TOUR PREVIEW CARD ────────────────────────────────────────────────

class _TourPreviewCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _TourPreviewCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 88,
              height: 88,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  UgamBusBackdrop(seed: tour.id),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _formatDate(tour.departureDate),
                        style: UgamText.tabular(
                          UgamText.micro
                              .copyWith(color: Colors.white, fontSize: 9.5),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tour.title,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  '${tour.fromCity} → ${tour.toCity}',
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: UgamSpacing.sm),
                Text(
                  '₹${tour.pricePerSeat.toStringAsFixed(0)} / seat',
                  style: UgamText.tabular(
                    UgamText.bodyStrong
                        .copyWith(color: c.accent, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const keys = [
      'app.month.short.jan','app.month.short.feb','app.month.short.mar',
      'app.month.short.apr','app.month.short.may','app.month.short.jun',
      'app.month.short.jul','app.month.short.aug','app.month.short.sep',
      'app.month.short.oct','app.month.short.nov','app.month.short.dec',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${tr(keys[d.month - 1]).toUpperCase()}';
  }
}

// ─── SECTION EYEBROW ──────────────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
    );
  }
}

// ─── SEAT TILE ────────────────────────────────────────────────────────

class _SeatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final int value;
  final ValueChanged<int> onChanged;

  const _SeatTile({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selected = value > 0;
    return AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.gutter,
        UgamSpacing.sm + 2,
        UgamSpacing.gutter,
      ),
      decoration: BoxDecoration(
        color: selected ? c.accentFill : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected ? c.accent.withValues(alpha: 0.18) : c.card,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 22,
              color: selected ? c.accent : c.ink2,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: UgamText.titleS
                        .copyWith(color: c.ink, fontSize: 15)),
                const SizedBox(height: 2),
                Text(sublabel,
                    style: UgamText.caption
                        .copyWith(color: c.ink2, fontSize: 11)),
              ],
            ),
          ),
          _StepperButton(
            icon: Icons.remove_rounded,
            enabled: value > 0,
            onTap: () {
              HapticFeedback.lightImpact();
              onChanged(value - 1);
            },
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: UgamText.tabular(
                UgamText.titleM.copyWith(
                  color: selected ? c.accent : c.ink,
                  fontSize: 18,
                ),
              ),
            ),
          ),
          _StepperButton(
            icon: Icons.add_rounded,
            enabled: value < 8,
            onTap: () {
              HapticFeedback.lightImpact();
              onChanged(value + 1);
            },
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: enabled ? c.accent : c.card,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 18,
          color: enabled ? c.onAccent : c.ink3,
        ),
      ),
    );
  }
}

// ─── TRIP TYPE SELECTOR ───────────────────────────────────────────────

class _TripTypeSelector extends StatelessWidget {
  final TripType value;
  final String fromCity;
  final String toCity;
  final ValueChanged<TripType> onChanged;

  const _TripTypeSelector({
    required this.value,
    required this.fromCity,
    required this.toCity,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TripTypeOption(
          icon: Icons.sync_alt_rounded,
          title: tr('customer_booking.trip_round_title'),
          subtitle: tr('customer_booking.trip_round_sub', namedArgs: {
            'from': fromCity,
            'to': toCity,
          }),
          selected: value == TripType.roundTrip,
          onTap: () => onChanged(TripType.roundTrip),
        ),
        const SizedBox(height: UgamSpacing.sm),
        _TripTypeOption(
          icon: Icons.arrow_forward_rounded,
          title: tr('customer_booking.trip_outbound_title',
              namedArgs: {'from': fromCity, 'to': toCity}),
          subtitle: tr('customer_booking.trip_outbound_sub'),
          selected: value == TripType.outboundOnly,
          onTap: () => onChanged(TripType.outboundOnly),
        ),
        const SizedBox(height: UgamSpacing.sm),
        _TripTypeOption(
          icon: Icons.arrow_back_rounded,
          title: tr('customer_booking.trip_return_title',
              namedArgs: {'from': toCity, 'to': fromCity}),
          subtitle: tr('customer_booking.trip_return_sub'),
          selected: value == TripType.returnOnly,
          onTap: () => onChanged(TripType.returnOnly),
        ),
      ],
    );
  }
}

class _TripTypeOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _TripTypeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.gutter,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: selected ? c.accent.withValues(alpha: 0.18) : c.card,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 20,
                color: selected ? c.accent : c.ink2,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: UgamText.caption
                          .copyWith(color: c.ink2, fontSize: 11)),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 20,
              color: selected ? c.accent : c.ink3,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TOTALS ───────────────────────────────────────────────────────────

class _Totals extends StatelessWidget {
  final int seatCount;
  final double estTotal;
  final UgamColorSet c;

  const _Totals({
    required this.seatCount,
    required this.estTotal,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.xs,
        vertical: UgamSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            plural('customer_booking.totals_seat', seatCount),
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink2, fontSize: 13),
            ),
          ),
          const Spacer(),
          if (estTotal > 0)
            Text(
              tr('customer_booking.totals_estimated',
                  namedArgs: {'amount': estTotal.toStringAsFixed(0)}),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
