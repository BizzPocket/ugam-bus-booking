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
/// [lines] is already assembled — one [RequestLine] per visible seat row, each
/// carrying its own `leg` (a request can now mix legs: e.g. 1 Double Sofa
/// round-trip + 1 Double Sofa outbound-only). A consumer can hand it straight to
/// a [Passenger] / `submit_booking_request` RPC. [doubleSofa] / [singleSofa] /
/// [seater] are aggregate per-type counts (handy for the `raw_form` payload and
/// snackbar copy). [tripType] is a DERIVED summary of the per-line legs (kept for
/// backward-compat — the per-line `leg` is the source of truth).
class BookingCaptureData {
  final String name;

  /// Raw 10-digit national number (no country code), e.g. `9876543210`.
  /// Already validated as a plausible Indian mobile.
  final String phone;

  /// `+91XXXXXXXXXX` — the normalised storage form most callers persist.
  final String normalisedPhone;

  /// Derived summary of the per-line legs: round-trip if any line is round-trip
  /// or the lines mix legs, otherwise the single shared one-leg value. No longer
  /// the source of truth — each [RequestLine] carries its own `leg`.
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
///
/// The form hydrates ONE row per [line], each carrying its stored leg. A legacy
/// initial that has no lines (only the scalar per-type counts + a single
/// [tripType]) is supported via the default constructor: it fabricates one row
/// per non-zero type, all sharing that [tripType].
class BookingCaptureInitial {
  final String name;

  /// Any format — normalised internally to the 10-digit field value.
  final String phone;

  /// Legacy single trip type. Applied to every hydrated row when [lines] is
  /// empty, OR to any hydrated line that lacks its own (already round-trip)
  /// stored leg — see [BookingCaptureInitial.fromLines].
  final TripType tripType;
  final int doubleSofa;
  final int singleSofa;
  final int seater;
  final String? note;

  /// Per-line seat rows to hydrate (each with its own stored leg). When
  /// non-empty this is the source of truth and the scalar counts are ignored.
  final List<RequestLine> lines;

  const BookingCaptureInitial({
    this.name = '',
    this.phone = '',
    this.tripType = TripType.roundTrip,
    this.doubleSofa = 0,
    this.singleSofa = 0,
    this.seater = 0,
    this.note,
    this.lines = const [],
  });

  /// Hydrate from an existing list of [RequestLine]s, preserving each line's
  /// stored leg. When a line lacks an explicit non-round-trip leg AND the
  /// request was saved under the legacy single [tripType] (i.e. the line is
  /// round-trip but the request is one-way), the legacy [tripType] is applied so
  /// old one-way requests keep their leg on edit.
  factory BookingCaptureInitial.fromLines({
    String name = '',
    String phone = '',
    TripType tripType = TripType.roundTrip,
    required Iterable<RequestLine> lines,
    String? note,
  }) {
    var d = 0, s = 0, st = 0;
    final hydrated = <RequestLine>[];
    for (final l in lines) {
      switch (l.seatType) {
        case SeatType.doubleSofa:
          d += l.qty;
        case SeatType.singleSofa:
          s += l.qty;
        case SeatType.seater:
          st += l.qty;
      }
      // Legacy fallback: a stored round-trip leg on a one-way request means the
      // line predates per-line legs — apply the request-wide tripType.
      final leg = (l.leg == TripType.roundTrip && tripType.isOneWay)
          ? tripType
          : l.leg;
      hydrated.add(l.copyWith(leg: leg));
    }
    return BookingCaptureInitial(
      name: name,
      phone: phone,
      tripType: tripType,
      doubleSofa: d,
      singleSofa: s,
      seater: st,
      note: note,
      lines: hydrated,
    );
  }
}

/// Internal editable draft for ONE seat row in the form: a seat type + optional
/// berth position + quantity + its own leg. Multiple rows of the same type with
/// different legs are allowed.
class _LineDraft {
  SeatType type;
  SeatPosition? position;
  int qty;
  TripType leg;

  _LineDraft({
    required this.type,
    this.position,
    required this.qty,
    this.leg = TripType.roundTrip,
  });
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

  /// One draft per visible seat row. Each row = type + optional position + qty +
  /// its own leg. Two rows of the same type on different legs are allowed.
  final List<_LineDraft> _drafts = [];

  bool _showNote = false;

  String? _nameError;
  String? _phoneError;
  String? _seatsError;

  // Contact autocomplete (admin only).
  UserController? _userCtrl;
  List<AppUser> _contactMatches = const [];

  int get _totalSeats =>
      _drafts.fold<int>(0, (sum, d) => sum + d.qty);

  /// Live count of how many distinct seats this booking is for — a consumer
  /// can read it to label its own submit button / count chip.
  int get totalSeats => _totalSeats;

  /// Seat types selectable in this surface — Seater only when [showSeater].
  List<SeatType> get _selectableTypes => [
    SeatType.doubleSofa,
    SeatType.singleSofa,
    if (widget.showSeater) SeatType.seater,
  ];

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
      _hydrateDrafts(e);
      if (e.note != null && e.note!.isNotEmpty) {
        _note.text = e.note!;
        _showNote = true;
      }
    }
  }

  /// Build the row drafts from the initial. Prefer the per-line list (each row
  /// keeps its stored leg); fall back to the legacy scalar counts (one row per
  /// non-zero type, all on the legacy [BookingCaptureInitial.tripType]).
  void _hydrateDrafts(BookingCaptureInitial e) {
    final selectable = _selectableTypes.toSet();
    if (e.lines.isNotEmpty) {
      for (final l in e.lines) {
        if (l.qty <= 0) continue;
        // Only hydrate types this surface can edit. Non-selectable lines (e.g. a
        // Seater on a sofa-only surface) are preserved by the consumer, not here
        // — surfacing one would double-count it on collect().
        if (!selectable.contains(l.seatType)) continue;
        _drafts.add(
          _LineDraft(
            type: l.seatType,
            position: l.position,
            qty: l.qty.clamp(1, widget.maxPerType),
            leg: l.leg,
          ),
        );
      }
    } else {
      void addType(SeatType t, int qty) {
        if (qty <= 0) return;
        _drafts.add(
          _LineDraft(
            type: t,
            qty: qty.clamp(1, widget.maxPerType),
            leg: e.tripType,
          ),
        );
      }

      addType(SeatType.doubleSofa, e.doubleSofa);
      addType(SeatType.singleSofa, e.singleSofa);
      if (widget.showSeater) addType(SeatType.seater, e.seater);
    }
    // Always start with at least one editable row so the section isn't empty.
    if (_drafts.isEmpty) {
      _drafts.add(
        _LineDraft(type: SeatType.doubleSofa, qty: 1, leg: TripType.roundTrip),
      );
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

    // One RequestLine per non-empty draft, each carrying its own leg. Rows with
    // qty 0 are dropped.
    final lines = <RequestLine>[
      for (final d in _drafts)
        if (d.qty > 0)
          RequestLine(
            seatType: d.type,
            position: d.position,
            qty: d.qty,
            leg: d.leg,
          ),
    ];

    // Aggregate per-type counts (sum across rows of the same type / leg).
    var doubleSofa = 0, singleSofa = 0, seater = 0;
    for (final l in lines) {
      switch (l.seatType) {
        case SeatType.doubleSofa:
          doubleSofa += l.qty;
        case SeatType.singleSofa:
          singleSofa += l.qty;
        case SeatType.seater:
          seater += l.qty;
      }
    }

    return BookingCaptureData(
      name: name,
      phone: phone,
      normalisedPhone: '+91${normalisePhone(phone)}',
      tripType: _summaryTripType(lines),
      lines: lines,
      note: note.isEmpty ? null : note,
      doubleSofa: doubleSofa,
      singleSofa: singleSofa,
      seater: seater,
    );
  }

  /// Derive the backward-compat single trip-type summary from per-line legs:
  /// round-trip if any line is round-trip OR the legs are mixed; otherwise the
  /// common one-leg value shared by every line.
  TripType _summaryTripType(List<RequestLine> lines) {
    if (lines.isEmpty) return TripType.roundTrip;
    final first = lines.first.leg;
    for (final l in lines) {
      if (l.leg != first || l.leg == TripType.roundTrip) {
        return TripType.roundTrip;
      }
    }
    return first;
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

  // ─── SEAT ROWS ──────────────────────────────────────────────────────────

  void _setRowQty(int index, int v) => setState(() {
    if (index < 0 || index >= _drafts.length) return;
    _drafts[index].qty = v.clamp(0, widget.maxPerType);
    if (_totalSeats > 0) _seatsError = null;
    _notify();
  });

  void _setRowType(int index, SeatType type) => setState(() {
    if (index < 0 || index >= _drafts.length) return;
    final d = _drafts[index];
    d.type = type;
    // Position is sofa-only metadata the form doesn't surface; clear it so a
    // type change never leaves a stale Upper/Lower on (e.g.) a Seater.
    d.position = null;
    _notify();
  });

  /// Cycle a row's leg: Full trip → Go only → Return only → Full trip.
  void _cycleRowLeg(int index) => setState(() {
    if (index < 0 || index >= _drafts.length) return;
    final d = _drafts[index];
    switch (d.leg) {
      case TripType.roundTrip:
        d.leg = TripType.outboundOnly;
      case TripType.outboundOnly:
        d.leg = TripType.returnOnly;
      case TripType.returnOnly:
        d.leg = TripType.roundTrip;
    }
    HapticFeedback.selectionClick();
    _notify();
  });

  /// Append a new row. Default doubleSofa qty 1 round-trip, or the first seat
  /// type not yet used (so two taps don't stack the same type by accident).
  void _addRow() => setState(() {
    final used = _drafts.map((d) => d.type).toSet();
    final type = _selectableTypes.firstWhere(
      (t) => !used.contains(t),
      orElse: () => SeatType.doubleSofa,
    );
    _drafts.add(_LineDraft(type: type, qty: 1, leg: TripType.roundTrip));
    _seatsError = null;
    HapticFeedback.selectionClick();
    _notify();
  });

  void _removeRow(int index) => setState(() {
    if (index < 0 || index >= _drafts.length) return;
    _drafts.removeAt(index);
    HapticFeedback.lightImpact();
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

  /// Pick a seat type for a row via the shared Ugam sheet. Only offered when
  /// more than one type is selectable (i.e. [showSeater] surfaces).
  Future<void> _pickRowType(int index) async {
    if (index < 0 || index >= _drafts.length) return;
    FocusScope.of(context).unfocus();
    final picked = await UgamSheet.show<SeatType>(
      context,
      title: tr('booking_form.label_seat_count'),
      builder: (_) => _SeatTypePickerSheet(
        types: _selectableTypes,
        selected: _drafts[index].type,
        labelOf: _seatLabel,
        sublabelOf: _seatSublabel,
        iconOf: _seatIcon,
      ),
    );
    if (picked == null || !mounted) return;
    _setRowType(index, picked);
  }

  // ─── SEAT-TYPE / LEG PRESENTATION ─────────────────────────────────────────

  IconData _seatIcon(SeatType t) {
    switch (t) {
      case SeatType.doubleSofa:
        return Icons.king_bed_rounded;
      case SeatType.singleSofa:
        return Icons.single_bed_rounded;
      case SeatType.seater:
        return Icons.event_seat_rounded;
    }
  }

  String _seatLabel(SeatType t) {
    switch (t) {
      case SeatType.doubleSofa:
        return tr('booking_form.seat_double_sofa_label');
      case SeatType.singleSofa:
        return tr('booking_form.seat_single_sofa_label');
      case SeatType.seater:
        return tr('booking_form.seat_seater_label');
    }
  }

  String _seatSublabel(SeatType t) {
    switch (t) {
      case SeatType.doubleSofa:
        return tr('booking_form.seat_double_sofa_sub');
      case SeatType.singleSofa:
        return tr('booking_form.seat_single_sofa_sub');
      case SeatType.seater:
        return tr('booking_form.seat_seater_sub');
    }
  }

  /// Concise leg label for the per-row chip. Reuses the leg semantics of the old
  /// trip-type picker (Full trip / Go only / Return only).
  String _legLabel(TripType leg) {
    switch (leg) {
      case TripType.roundTrip:
        return tr('booking_form.leg_full');
      case TripType.outboundOnly:
        return tr('booking_form.leg_go');
      case TripType.returnOnly:
        return tr('booking_form.leg_ret');
    }
  }

  IconData _legIcon(TripType leg) {
    switch (leg) {
      case TripType.roundTrip:
        return Icons.sync_alt_rounded;
      case TripType.outboundOnly:
        return Icons.arrow_forward_rounded;
      case TripType.returnOnly:
        return Icons.arrow_back_rounded;
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
        _SectionEyebrow(label: tr('booking_form.label_seat_count'), c: c),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < _drafts.length; i++) ...[
          if (i > 0) const SizedBox(height: UgamSpacing.sm),
          _SeatRowTile(
            key: ObjectKey(_drafts[i]),
            icon: _seatIcon(_drafts[i].type),
            label: _seatLabel(_drafts[i].type),
            sublabel: _seatSublabel(_drafts[i].type),
            value: _drafts[i].qty,
            legLabel: _legLabel(_drafts[i].leg),
            legIcon: _legIcon(_drafts[i].leg),
            legActive: _drafts[i].leg.isOneWay,
            maxPerType: widget.maxPerType,
            canRemove: _drafts.length > 1,
            onChanged: (v) => _setRowQty(i, v),
            onTapValue: () => _promptQuantity(
              title: _seatLabel(_drafts[i].type),
              current: _drafts[i].qty,
              onSet: (v) => _setRowQty(i, v),
            ),
            onCycleLeg: () => _cycleRowLeg(i),
            onTapType: widget.showSeater ? () => _pickRowType(i) : null,
            onRemove: () => _removeRow(i),
          ),
        ],
        const SizedBox(height: UgamSpacing.sm),
        _AddSeatRowButton(c: c, onTap: _addRow),
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

// ─── SEAT ROW TILE (type + tappable typed qty + per-row leg chip) ───────────

/// One editable seat row: type label/icon, a tappable typed qty with +/- fine
/// adjust (same stepper style as before), a tap-cycle LEG chip (Full → Go →
/// Return), an optional type-swap affordance, and a remove button.
class _SeatRowTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final int value;
  final String legLabel;
  final IconData legIcon;
  final bool legActive;
  final int maxPerType;
  final bool canRemove;
  final ValueChanged<int> onChanged;
  final VoidCallback onTapValue;
  final VoidCallback onCycleLeg;
  final VoidCallback? onTapType;
  final VoidCallback onRemove;

  const _SeatRowTile({
    super.key,
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.value,
    required this.legLabel,
    required this.legIcon,
    required this.legActive,
    required this.maxPerType,
    required this.canRemove,
    required this.onChanged,
    required this.onTapValue,
    required this.onCycleLeg,
    required this.onTapType,
    required this.onRemove,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: onTapType == null
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        onTapType!();
                      },
                behavior: HitTestBehavior.opaque,
                child: Container(
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
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: GestureDetector(
                  onTap: onTapType == null
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          onTapType!();
                        },
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: UgamText.titleS.copyWith(
                                color: c.ink,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          if (onTapType != null) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.unfold_more_rounded,
                              size: 16,
                              color: c.ink3,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sublabel,
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
              // one type action instead of N taps.
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
                      color: selected
                          ? c.accent.withValues(alpha: 0.4)
                          : c.border,
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
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              // Per-row LEG chip — tap to cycle Full trip → Go only → Return.
              GestureDetector(
                onTap: onCycleLeg,
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: legActive ? c.accentFill : c.card,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(
                      color: legActive ? c.accent : c.border,
                      width: legActive ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        legIcon,
                        size: 14,
                        color: legActive ? c.accent : c.ink2,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        legLabel,
                        style: UgamText.bodyStrong.copyWith(
                          color: legActive ? c.accent : c.ink2,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (canRemove)
                GestureDetector(
                  onTap: onRemove,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.sm,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: c.ink3,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          tr('booking_form.remove_row'),
                          style: UgamText.caption.copyWith(
                            color: c.ink3,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── ADD SEAT ROW BUTTON ────────────────────────────────────────────────────

class _AddSeatRowButton extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;
  const _AddSeatRowButton({required this.c, required this.onTap});

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
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 18, color: c.accent),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              tr('booking_form.add_seat_row'),
              style: UgamText.bodyStrong.copyWith(color: c.accent, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── SEAT TYPE PICKER SHEET ─────────────────────────────────────────────────

/// Lets a row swap its seat type. Only shown on surfaces that offer more than
/// one selectable type (i.e. Seater-enabled surfaces).
class _SeatTypePickerSheet extends StatelessWidget {
  final List<SeatType> types;
  final SeatType selected;
  final String Function(SeatType) labelOf;
  final String Function(SeatType) sublabelOf;
  final IconData Function(SeatType) iconOf;

  const _SeatTypePickerSheet({
    required this.types,
    required this.selected,
    required this.labelOf,
    required this.sublabelOf,
    required this.iconOf,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in types) ...[
          GestureDetector(
            onTap: () => Navigator.of(context).pop(t),
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.gutter,
                vertical: UgamSpacing.md,
              ),
              decoration: BoxDecoration(
                color: t == selected ? c.accentFill : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.row),
                border: Border.all(
                  color: t == selected ? c.accent : c.border,
                  width: t == selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: t == selected
                          ? c.accent.withValues(alpha: 0.18)
                          : c.card,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      iconOf(t),
                      size: 20,
                      color: t == selected ? c.accent : c.ink2,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          labelOf(t),
                          style: UgamText.bodyStrong.copyWith(
                            color: c.ink,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sublabelOf(t),
                          style: UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (t == selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 20,
                      color: c.accent,
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
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
