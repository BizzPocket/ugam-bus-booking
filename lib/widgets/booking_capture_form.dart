import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/app_user.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import '../services/contact_sync_service.dart';
import '../utils/phone_normalize.dart';

/// Result of a successful [BookingCaptureForm] collection.
///
/// This is the ONE shape every booking-capture surface (customer create/edit,
/// admin add, admin edit) produces. Each consumer owns its own submit button
/// and persistence — they just read these fields off the returned data.
///
/// [lines] is already assembled (Double Sofa / Single Sofa / Seater lines with
/// `qty > 0`), so a consumer can hand it straight to a [Passenger] /
/// `submit_booking_request` RPC. [doubleSofa] / [singleSofa] / [seater] are the
/// raw per-type counts (handy for the `raw_form` payload and snackbar copy).
class BookingCaptureData {
  final String name;

  /// Raw 10-digit national number (no country code), e.g. `9876543210`.
  /// Already validated as a plausible Indian mobile.
  final String phone;

  /// `+91XXXXXXXXXX` — the normalised storage form most callers persist.
  final String normalisedPhone;

  final TripType tripType;
  final List<RequestLine> lines;
  final String? note;

  final int doubleSofa;
  final int singleSofa;
  final int seater;

  const BookingCaptureData({
    required this.name,
    required this.phone,
    required this.normalisedPhone,
    required this.tripType,
    required this.lines,
    required this.note,
    required this.doubleSofa,
    required this.singleSofa,
    required this.seater,
  });

  int get totalSeats => doubleSofa + singleSofa + seater;
}

/// Pre-fill payload for edit mode. Build one from an existing
/// `CustomerRequestEntry` or `Passenger` and pass as [BookingCaptureForm.initial].
class BookingCaptureInitial {
  final String name;

  /// Any format — normalised internally to the 10-digit field value.
  final String phone;
  final TripType tripType;
  final int doubleSofa;
  final int singleSofa;
  final int seater;
  final String? note;

  const BookingCaptureInitial({
    this.name = '',
    this.phone = '',
    this.tripType = TripType.roundTrip,
    this.doubleSofa = 0,
    this.singleSofa = 0,
    this.seater = 0,
    this.note,
  });

  /// Convenience: split a list of [RequestLine] into per-type counts.
  factory BookingCaptureInitial.fromLines({
    String name = '',
    String phone = '',
    TripType tripType = TripType.roundTrip,
    required Iterable<RequestLine> lines,
    String? note,
  }) {
    var d = 0, s = 0, st = 0;
    for (final l in lines) {
      switch (l.seatType) {
        case SeatType.doubleSofa:
          d += l.qty;
        case SeatType.singleSofa:
          s += l.qty;
        case SeatType.seater:
          st += l.qty;
      }
    }
    return BookingCaptureInitial(
      name: name,
      phone: phone,
      tripType: tripType,
      doubleSofa: d,
      singleSofa: s,
      seater: st,
      note: note,
    );
  }
}

/// ONE shared booking-capture form, used by all three surfaces:
/// customer request (create + edit), admin add request, admin edit request.
///
/// Collects: name (with optional contact autocomplete + "pick from contacts"
/// when [enableContacts]), phone (validated with the stricter
/// [isPlausibleIndianMobile]), trip type (round-trip default invisible —
/// collapsed to a single chip with a "One-way?" affordance), seat quantities
/// for Double Sofa + Single Sofa (+ Seater when [showSeater]) with a TAPPABLE
/// typed quantity AND +/- fine adjust, and an optional note.
///
/// ── CONTRACT (GlobalKey style) ─────────────────────────────────────────────
/// The consumer owns its own submit button + persistence. To read the result:
///
/// ```dart
/// final _formKey = GlobalKey<BookingCaptureFormState>();
/// ...
/// BookingCaptureForm(key: _formKey, fromCity: t.fromCity, toCity: t.toCity);
/// ...
/// final data = _formKey.currentState?.collect();
/// if (data == null) return; // invalid — inline errors already shown
/// // persist using data.name / data.normalisedPhone / data.lines / ...
/// ```
///
/// [collect] returns `null` and surfaces inline field errors when invalid;
/// otherwise it returns a fully-validated [BookingCaptureData]. The form keeps
/// no persistence concerns — it is a pure collector.
class BookingCaptureForm extends StatefulWidget {
  /// Departure / destination city — used only to label the trip-type options
  /// (e.g. "Surat → Mumbai"). Both consumer surfaces have a `Tour`.
  final String fromCity;
  final String toCity;

  /// Pre-fill values for edit mode. Null = blank create form.
  final BookingCaptureInitial? initial;

  /// Admin-only: enable name autocomplete from saved contacts + a
  /// "pick from contacts" (device phonebook) entry point. Off for customers.
  final bool enableContacts;

  /// Lock the phone field (admin edit edits an existing passenger whose phone
  /// is the identity key and must not change).
  final bool lockPhone;

  /// Whether to show the Seater counter. The two sofa-only surfaces leave this
  /// false; a future surface that books seaters can opt in.
  final bool showSeater;

  /// Hard cap per seat type (stepper + typed entry both clamp to this).
  final int maxPerType;

  /// Called whenever any field changes (so a consumer can live-update a
  /// passenger-count chip on its own submit button). Optional.
  final VoidCallback? onChanged;

  const BookingCaptureForm({
    super.key,
    required this.fromCity,
    required this.toCity,
    this.initial,
    this.enableContacts = false,
    this.lockPhone = false,
    this.showSeater = false,
    this.maxPerType = 10,
    this.onChanged,
  });

  @override
  State<BookingCaptureForm> createState() => BookingCaptureFormState();
}

class BookingCaptureFormState extends State<BookingCaptureForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();

  int _doubleSofa = 0;
  int _singleSofa = 0;
  int _seater = 0;
  TripType _tripType = TripType.roundTrip;

  bool _showNote = false;
  bool _showOneWay =
      false; // GO/RET options expanded (round-trip-default-invisible)

  String? _nameError;
  String? _phoneError;
  String? _seatsError;

  // Contact autocomplete (admin only).
  UserController? _userCtrl;
  List<AppUser> _contactMatches = const [];

  int get _totalSeats => _doubleSofa + _singleSofa + _seater;

  /// Live count of how many distinct seats this booking is for — a consumer
  /// can read it to label its own submit button / count chip.
  int get totalSeats => _totalSeats;

  @override
  void initState() {
    super.initState();
    if (widget.enableContacts && Get.isRegistered<UserController>()) {
      _userCtrl = Get.find<UserController>();
    }
    final e = widget.initial;
    if (e != null) {
      _name.text = e.name;
      _phone.text = normalisePhone(e.phone);
      _doubleSofa = e.doubleSofa.clamp(0, widget.maxPerType);
      _singleSofa = e.singleSofa.clamp(0, widget.maxPerType);
      _seater = e.seater.clamp(0, widget.maxPerType);
      _tripType = e.tripType;
      // If the booking is one-way, the GO/RET picker must start expanded so the
      // chosen leg is visible (and changeable) without hunting for "One-way?".
      _showOneWay = e.tripType.isOneWay;
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

  void _notify() => widget.onChanged?.call();

  // ─── PUBLIC CONTRACT ────────────────────────────────────────────────────

  /// Validate and collect. Returns `null` (and surfaces inline errors) when
  /// invalid; otherwise a fully-validated [BookingCaptureData].
  BookingCaptureData? collect() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();

    String? nameError;
    String? phoneError;
    String? seatsError;

    if (name.isEmpty) {
      nameError = tr('booking_form.err_name_required');
    }
    // Stricter rule (the one the customer screen used): 10 digits AND a
    // plausible Indian mobile (right leading digit, not junk/typo runs).
    if (phone.length != 10) {
      phoneError = tr('booking_form.err_phone_invalid');
    } else if (!isPlausibleIndianMobile(phone)) {
      phoneError = tr('booking_form.err_phone_fake');
    }
    if (_totalSeats == 0) {
      seatsError = tr('booking_form.err_no_seats');
    }

    if (nameError != null || phoneError != null || seatsError != null) {
      setState(() {
        _nameError = nameError;
        _phoneError = phoneError;
        _seatsError = seatsError;
      });
      return null;
    }

    final note = _note.text.trim();
    final lines = <RequestLine>[
      if (_doubleSofa > 0)
        RequestLine(seatType: SeatType.doubleSofa, qty: _doubleSofa),
      if (_singleSofa > 0)
        RequestLine(seatType: SeatType.singleSofa, qty: _singleSofa),
      if (_seater > 0) RequestLine(seatType: SeatType.seater, qty: _seater),
    ];

    return BookingCaptureData(
      name: name,
      phone: phone,
      normalisedPhone: '+91${normalisePhone(phone)}',
      tripType: _tripType,
      lines: lines,
      note: note.isEmpty ? null : note,
      doubleSofa: _doubleSofa,
      singleSofa: _singleSofa,
      seater: _seater,
    );
  }

  // ─── CONTACTS ───────────────────────────────────────────────────────────

  void _onNameChanged(String value) {
    if (_nameError != null) _nameError = null;
    if (_userCtrl == null) {
      _notify();
      return;
    }
    final q = value.trim().toLowerCase();
    final matches = q.isEmpty
        ? const <AppUser>[]
        : _userCtrl!.users
              .where(
                (u) => u.name.toLowerCase().contains(q) || u.phone.contains(q),
              )
              .where((u) => u.name.toLowerCase() != q)
              .take(6)
              .toList(growable: false);
    setState(() => _contactMatches = matches);
    _notify();
  }

  void _pickContact(AppUser user) {
    HapticFeedback.selectionClick();
    _name.text = user.name;
    _phone.text = normalisePhone(user.phone);
    setState(() {
      _nameError = null;
      _phoneError = null;
      _contactMatches = const [];
    });
    FocusScope.of(context).unfocus();
    _notify();
  }

  Future<void> _openContactPicker() async {
    FocusScope.of(context).unfocus();
    final picked = await UgamSheet.show<DeviceContactEntry>(
      context,
      title: tr('booking_form.pick_contact_title'),
      builder: (_) => const _ContactPickerSheet(),
    );
    if (picked == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _name.text = picked.name;
      _phone.text = normalisePhone(picked.phone);
      _nameError = null;
      _phoneError = null;
      _contactMatches = const [];
    });
    _notify();
  }

  String _contactInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  // ─── SEAT QTY ───────────────────────────────────────────────────────────

  void _setDouble(int v) => setState(() {
    _doubleSofa = v.clamp(0, widget.maxPerType);
    if (_totalSeats > 0) _seatsError = null;
    _notify();
  });

  void _setSingle(int v) => setState(() {
    _singleSofa = v.clamp(0, widget.maxPerType);
    if (_totalSeats > 0) _seatsError = null;
    _notify();
  });

  void _setSeater(int v) => setState(() {
    _seater = v.clamp(0, widget.maxPerType);
    if (_totalSeats > 0) _seatsError = null;
    _notify();
  });

  /// Tap-to-type a quantity on a numeric keypad. 6 seats = one type action.
  Future<void> _promptQuantity({
    required String title,
    required int current,
    required ValueChanged<int> onSet,
  }) async {
    final controller = TextEditingController(
      text: current > 0 ? '$current' : '',
    );
    final entered = await UgamDialog.show<int>(
      context,
      title: title,
      message: tr(
        'booking_form.qty_dialog_hint',
        namedArgs: {'max': '${widget.maxPerType}'},
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(2),
        ],
        style: UgamText.titleXl.copyWith(
          color: UgamColors.of(context).ink,
          fontSize: 28,
        ),
        decoration: const InputDecoration(counterText: '', hintText: '0'),
        onSubmitted: (v) =>
            Navigator.of(context).pop(int.tryParse(v.trim()) ?? current),
      ),
      actions: (ctx) => [
        UgamButton(
          label: tr('booking_form.qty_dialog_cancel'),
          kind: UgamButtonKind.ghost,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
        UgamButton(
          label: tr('booking_form.qty_dialog_set'),
          icon: Icons.check_rounded,
          onPressed: () => Navigator.of(
            ctx,
          ).pop(int.tryParse(controller.text.trim()) ?? current),
        ),
      ],
    );
    controller.dispose();
    if (entered != null) {
      HapticFeedback.selectionClick();
      onSet(entered.clamp(0, widget.maxPerType));
    }
  }

  // ─── BUILD ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.enableContacts) ...[
          _PickContactButton(c: c, onTap: _openContactPicker),
          const SizedBox(height: UgamSpacing.lg),
        ],
        UgamInput(
          label: tr('booking_form.label_name'),
          hint: tr('booking_form.hint_name'),
          controller: _name,
          errorText: _nameError,
          prefix: widget.enableContacts
              ? Icon(Icons.search_rounded, size: 18, color: c.ink3)
              : null,
          onChanged: _onNameChanged,
        ),
        if (_contactMatches.isNotEmpty) _buildContactMatches(c),
        const SizedBox(height: UgamSpacing.lg),
        UgamPhoneInput(
          controller: _phone,
          label: tr('booking_form.label_phone'),
          errorText: _phoneError,
          onChanged: widget.lockPhone
              ? null
              : (_) {
                  if (_phoneError != null) setState(() => _phoneError = null);
                  _notify();
                },
        ),
        const SizedBox(height: UgamSpacing.xl),
        _SectionEyebrow(label: tr('booking_form.label_trip_type'), c: c),
        const SizedBox(height: UgamSpacing.md),
        _TripTypePicker(
          value: _tripType,
          expanded: _showOneWay,
          fromCity: widget.fromCity,
          toCity: widget.toCity,
          onChanged: (v) => setState(() {
            _tripType = v;
            _notify();
          }),
          onToggleOneWay: () => setState(() {
            _showOneWay = !_showOneWay;
            // Collapsing the picker means the user backed out of one-way: snap
            // the value back to round trip so the chip and value never disagree.
            if (!_showOneWay) _tripType = TripType.roundTrip;
            _notify();
          }),
        ),
        const SizedBox(height: UgamSpacing.xl),
        _SectionEyebrow(label: tr('booking_form.label_seat_count'), c: c),
        const SizedBox(height: UgamSpacing.md),
        _SeatTile(
          icon: Icons.king_bed_rounded,
          label: tr('booking_form.seat_double_sofa_label'),
          sublabel: tr('booking_form.seat_double_sofa_sub'),
          value: _doubleSofa,
          maxPerType: widget.maxPerType,
          onChanged: _setDouble,
          onTapValue: () => _promptQuantity(
            title: tr('booking_form.seat_double_sofa_label'),
            current: _doubleSofa,
            onSet: _setDouble,
          ),
        ),
        const SizedBox(height: UgamSpacing.sm),
        _SeatTile(
          icon: Icons.single_bed_rounded,
          label: tr('booking_form.seat_single_sofa_label'),
          sublabel: tr('booking_form.seat_single_sofa_sub'),
          value: _singleSofa,
          maxPerType: widget.maxPerType,
          onChanged: _setSingle,
          onTapValue: () => _promptQuantity(
            title: tr('booking_form.seat_single_sofa_label'),
            current: _singleSofa,
            onSet: _setSingle,
          ),
        ),
        if (widget.showSeater) ...[
          const SizedBox(height: UgamSpacing.sm),
          _SeatTile(
            icon: Icons.event_seat_rounded,
            label: tr('booking_form.seat_seater_label'),
            sublabel: tr('booking_form.seat_seater_sub'),
            value: _seater,
            maxPerType: widget.maxPerType,
            onChanged: _setSeater,
            onTapValue: () => _promptQuantity(
              title: tr('booking_form.seat_seater_label'),
              current: _seater,
              onSet: _setSeater,
            ),
          ),
        ],
        if (_seatsError != null) ...[
          const SizedBox(height: UgamSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              _seatsError!,
              style: UgamText.caption.copyWith(color: c.danger),
            ),
          ),
        ],
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
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 14, color: c.ink2),
                    const SizedBox(width: 4),
                    Text(
                      tr('booking_form.add_note_button'),
                      style: UgamText.bodyStrong.copyWith(
                        color: c.ink2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          UgamInput(
            label: tr('booking_form.label_note'),
            hint: tr('booking_form.hint_note'),
            controller: _note,
            maxLength: 200,
            autofocus: widget.initial?.note?.isNotEmpty != true,
          ),
      ],
    );
  }

  Widget _buildContactMatches(UgamColorSet c) {
    return Container(
      margin: const EdgeInsets.only(top: UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              UgamSpacing.sm,
              UgamSpacing.gutter,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('booking_form.from_contacts'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
            ),
          ),
          for (final u in _contactMatches)
            InkWell(
              onTap: () => _pickContact(u),
              borderRadius: BorderRadius.circular(UgamRadius.input),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.gutter,
                  vertical: UgamSpacing.sm,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.accent.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _contactInitials(u.name),
                        style: UgamText.titleS.copyWith(
                          color: c.accent,
                          fontSize: 13,
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
                            u.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: UgamText.body.copyWith(
                              color: c.ink,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            u.phone,
                            style: UgamText.tabular(
                              UgamText.caption.copyWith(
                                color: c.ink2,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.north_west_rounded, size: 16, color: c.ink3),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── PICK CONTACT BUTTON ────────────────────────────────────────────────────

class _PickContactButton extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;
  const _PickContactButton({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.accentFill,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          border: Border.all(color: c.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts_rounded, size: 18, color: c.accent),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              tr('booking_form.pick_contact'),
              style: UgamText.bodyStrong.copyWith(
                color: c.accent,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── SECTION EYEBROW ────────────────────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink3),
      ),
    );
  }
}

// ─── TRIP TYPE PICKER (round-trip-default-invisible) ────────────────────────

/// A single "Round trip" chip with a "One-way?" affordance. The GO/RET options
/// only appear when the user opts into one-way — round trip stays a one-tap
/// default that needs no thought.
class _TripTypePicker extends StatelessWidget {
  final TripType value;
  final bool expanded;
  final String fromCity;
  final String toCity;
  final ValueChanged<TripType> onChanged;
  final VoidCallback onToggleOneWay;

  const _TripTypePicker({
    required this.value,
    required this.expanded,
    required this.fromCity,
    required this.toCity,
    required this.onChanged,
    required this.onToggleOneWay,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final roundSelected = value == TripType.roundTrip;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _TripChip(
                icon: Icons.sync_alt_rounded,
                title: tr('booking_form.trip_round_title'),
                subtitle: tr(
                  'booking_form.trip_round_sub',
                  namedArgs: {'from': fromCity, 'to': toCity},
                ),
                selected: roundSelected && !expanded,
                onTap: () {
                  if (expanded) onToggleOneWay();
                  onChanged(TripType.roundTrip);
                },
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onToggleOneWay();
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: UgamMotion.tab,
                curve: UgamMotion.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: expanded ? c.accentFill : c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                  border: Border.all(
                    color: expanded ? c.accent : c.border,
                    width: expanded ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('booking_form.trip_oneway_toggle'),
                      style: UgamText.bodyStrong.copyWith(
                        color: expanded ? c.accent : c.ink2,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: expanded ? c.accent : c.ink3,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (expanded) ...[
          const SizedBox(height: UgamSpacing.sm),
          _TripTypeOption(
            icon: Icons.arrow_forward_rounded,
            title: tr(
              'booking_form.trip_outbound_title',
              namedArgs: {'from': fromCity, 'to': toCity},
            ),
            subtitle: tr('booking_form.trip_outbound_sub'),
            selected: value == TripType.outboundOnly,
            onTap: () => onChanged(TripType.outboundOnly),
          ),
          const SizedBox(height: UgamSpacing.sm),
          _TripTypeOption(
            icon: Icons.arrow_back_rounded,
            title: tr(
              'booking_form.trip_return_title',
              namedArgs: {'from': toCity, 'to': fromCity},
            ),
            subtitle: tr('booking_form.trip_return_sub'),
            selected: value == TripType.returnOnly,
            onTap: () => onChanged(TripType.returnOnly),
          ),
        ],
      ],
    );
  }
}

class _TripChip extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _TripChip({
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
          border: Border.all(
            color: selected ? c.accent : c.border,
            width: selected ? 1.5 : 1,
          ),
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
              child: Icon(icon, size: 20, color: selected ? c.accent : c.ink2),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
              child: Icon(icon, size: 20, color: selected ? c.accent : c.ink2),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontSize: 11,
                    ),
                  ),
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

// ─── SEAT TILE (tappable typed qty + fine-adjust +/-) ───────────────────────

class _SeatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final int value;
  final int maxPerType;
  final ValueChanged<int> onChanged;
  final VoidCallback onTapValue;

  const _SeatTile({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.value,
    required this.maxPerType,
    required this.onChanged,
    required this.onTapValue,
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
            child: Icon(icon, size: 22, color: selected ? c.accent : c.ink2),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11),
                ),
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
          // Tappable value — opens the numeric keypad so a large quantity is
          // one type action instead of N taps. The number doubles as the
          // affordance (underlined-feel via the bordered tap target).
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTapValue();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              constraints: const BoxConstraints(minWidth: 36),
              height: 32,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? c.accent.withValues(alpha: 0.4) : c.border,
                ),
              ),
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
          ),
          _StepperButton(
            icon: Icons.add_rounded,
            enabled: value < maxPerType,
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
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: enabled ? c.accent : c.card,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: enabled ? c.onAccent : c.ink3),
      ),
    );
  }
}

// ─── CONTACT PICKER SHEET (self-contained) ──────────────────────────────────

/// Searchable device-contacts picker. Reads the phone directory on open (via
/// [ContactSyncService], which handles the permission prompt) and pops the
/// chosen [DeviceContactEntry]. Inlined here so [BookingCaptureForm] depends on
/// no screen — only the public contact service. Mirrors the admin requests
/// screen's picker so behaviour stays identical across surfaces.
class _ContactPickerSheet extends StatefulWidget {
  const _ContactPickerSheet();

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  final _search = TextEditingController();
  List<DeviceContactEntry> _all = const [];
  bool _loading = true;
  bool _denied = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = ContactSyncService();
    final list = await svc.pullDeviceContacts();
    // pullDeviceContacts returns [] for BOTH "denied" and "no contacts" — only
    // call it denied when permission truly isn't granted.
    final granted = list.isNotEmpty || await svc.hasPermission();
    if (!mounted) return;
    setState(() {
      _all = [...list]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _loading = false;
      _denied = !granted;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    if (_loading) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              ),
              const SizedBox(height: UgamSpacing.md),
              Text(
                tr('booking_form.contacts_loading'),
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ],
          ),
        ),
      );
    }

    if (_denied) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts_outlined, size: 34, color: c.ink3),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('booking_form.contacts_denied'),
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _all
        : _all
              .where(
                (e) => e.name.toLowerCase().contains(q) || e.phone.contains(q),
              )
              .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UgamInput(
          hint: tr('booking_form.contacts_search_hint'),
          controller: _search,
          prefix: Icon(Icons.search_rounded, size: 18, color: c.ink3),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
            child: Center(
              child: Text(
                tr('booking_form.contacts_empty'),
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            ),
          )
        else
          // Flexible (not a bare ConstrainedBox) so the list YIELDS to the
          // space the sheet actually has: on shorter screens the fixed 360
          // height + search field + sheet chrome overflowed the bottom. It
          // still caps at 360 and scrolls internally when there's room.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final e = filtered[i];
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(e),
                    borderRadius: BorderRadius.circular(UgamRadius.input),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UgamSpacing.sm + 2,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              _initials(e.name),
                              style: UgamText.bodyStrong.copyWith(
                                color: c.accent,
                                fontSize: 12,
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
                                  e.name,
                                  style: UgamText.body.copyWith(color: c.ink),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  e.phone,
                                  style: UgamText.caption.copyWith(
                                    color: c.ink2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
