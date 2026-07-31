import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/pickup_controller.dart';
import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/app_user.dart';
import '../models/pickup_location.dart';
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

  /// Optional snapshotted pickup point (id + name) chosen from the GLOBAL list.
  /// Both null when the booker skipped it. The name is snapshotted so a later
  /// rename/retire never rewrites a historical request.
  final String? pickupLocationId;
  final String? pickupLocationName;

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
    this.pickupLocationId,
    this.pickupLocationName,
  });

  /// Total seat *berths* this booking occupies — a Double Sofa counts as its
  /// two berths (upper+lower), every other unit as one. Matches
  /// [Passenger.seatBerths] so the "Total seats" label, the submit-button chip,
  /// the stored `party_size`, and the admin "N seats" push all agree. The raw
  /// per-type UNIT counts stay on [doubleSofa]/[singleSofa]/[seater].
  int get totalSeats =>
      lines.fold(0, (sum, l) => sum + l.qty * l.seatType.berthsPerUnit);
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

  /// Snapshotted pickup point to pre-select on edit (both null when none was
  /// saved). The name is what's shown; the id re-selects the matching option.
  final String? pickupLocationId;
  final String? pickupLocationName;

  const BookingCaptureInitial({
    this.name = '',
    this.phone = '',
    this.tripType = TripType.roundTrip,
    this.doubleSofa = 0,
    this.singleSofa = 0,
    this.seater = 0,
    this.note,
    this.lines = const [],
    this.pickupLocationId,
    this.pickupLocationName,
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
    String? pickupLocationId,
    String? pickupLocationName,
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
      pickupLocationId: pickupLocationId,
      pickupLocationName: pickupLocationName,
    );
  }
}

/// Mutable per-(leg, type) bucket: a quantity plus any berth position carried
/// over from an edited line. The form has NO UI to set position, but must not
/// silently drop it on a round-trip line — so hydration parks it here and
/// [BookingCaptureFormState.collect] re-emits it.
class _Cell {
  int qty = 0;
  SeatPosition? position;
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

  /// When set, every row is FORCED to this leg and the per-row leg chip is
  /// hidden — used by the return-ticket surface where the GO leg has already
  /// departed, so only [TripType.returnOnly] makes sense.
  final TripType? forcedLeg;

  /// Require a pickup point before submit. ON by default: every request —
  /// customer-submitted OR added/edited by hand by the organiser — must carry a
  /// pickup point, so the roster and the driver's chart are never missing one.
  /// Only enforced when a non-empty pickup list actually exists — a tour with
  /// no configured pickups never blocks booking (the field is hidden too).
  final bool requirePickup;

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
    this.forcedLeg,
    this.requirePickup = true,
  });

  @override
  State<BookingCaptureForm> createState() => BookingCaptureFormState();
}

class BookingCaptureFormState extends State<BookingCaptureForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();

  /// Name field focus — a listener dismisses the contact-autocomplete dropdown
  /// the moment focus leaves the name field (tap phone / seat area / anywhere
  /// the host unfocuses), so it no longer lingers until submit.
  final _nameFocus = FocusNode();

  /// Quantity (+ any preserved berth position) per leg per seat type. Leg is the
  /// PRIMARY axis (a tab); seat type is a counter within the active leg. This is
  /// the entire seat-section state — there are no per-row drafts to add/remove.
  final Map<TripType, Map<SeatType, _Cell>> _cells = {};

  /// The leg whose counters are currently shown (the active tab). Pinned to
  /// [BookingCaptureForm.forcedLeg] on a forced surface.
  late TripType _activeLeg;

  bool _showNote = false;

  /// Optional chosen pickup point (snapshotted id + name). Both null = none.
  String? _pickupId;
  String? _pickupName;

  /// The global pickup-point list (shared across tours). Null when the
  /// controller isn't registered — the selector then simply never appears.
  PickupController? _pickup;

  String? _nameError;
  String? _phoneError;
  String? _seatsError;
  String? _pickupError;

  // Contact autocomplete (admin only).
  UserController? _userCtrl;
  List<AppUser> _contactMatches = const [];

  int get _totalSeats {
    var n = 0;
    for (final byType in _cells.values) {
      for (final entry in byType.entries) {
        n += entry.value.qty * entry.key.berthsPerUnit;
      }
    }
    return n;
  }

  /// Live count of seat *berths* this booking occupies (a Double Sofa is two) —
  /// a consumer reads it to label its own submit button / count chip. Berths,
  /// not request units, so it agrees with the "Total seats" line and
  /// [BookingCaptureData.totalSeats].
  int get totalSeats => _totalSeats;

  /// Leg-weighted berth count for a live price ESTIMATE: a one-way (Go-only /
  /// Return-only) berth is worth 0.5 of a full round-trip berth, matching the
  /// 0.5-leg pricing the booking is actually charged at. A Double Sofa still
  /// counts its two berths. Fractional by design (e.g. two Go-only singles →
  /// 1.0); the caller multiplies by the per-seat price and rounds to whole
  /// rupees at display. Pure (no validation / no setState), so it is safe to
  /// read from a widget build. Distinct from [totalSeats], which counts physical
  /// berths regardless of leg.
  num get legWeightedSeats {
    num n = 0;
    for (final byLeg in _cells.entries) {
      final factor = byLeg.key.isOneWay ? 0.5 : 1.0;
      for (final entry in byLeg.value.entries) {
        n += entry.value.qty * entry.key.berthsPerUnit * factor;
      }
    }
    return n;
  }

  /// Legs offered as tabs. A forced-leg surface collapses to just that one leg
  /// (and the tab bar is hidden). Order: Full trip, Go only, Return only.
  List<TripType> get _legs => widget.forcedLeg != null
      ? [widget.forcedLeg!]
      : const [TripType.roundTrip, TripType.outboundOnly, TripType.returnOnly];

  /// Seat *berths* booked on [leg] across all types (Double Sofa = 2) — drives
  /// the per-tab badge, kept in the same berth unit as the "Total seats" line.
  int _legSeatCount(TripType leg) =>
      _cells[leg]?.entries.fold<int>(
        0,
        (s, e) => s + e.value.qty * e.key.berthsPerUnit,
      ) ??
      0;

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
      // Dismiss the contact-autocomplete dropdown as soon as the name field
      // loses focus (moving to the phone field / tapping elsewhere).
      _nameFocus.addListener(_onNameFocusChanged);
    }
    if (Get.isRegistered<PickupController>()) {
      _pickup = Get.find<PickupController>();
      // Fire-and-forget: an Obx in build reveals the selector once it lands.
      _pickup!.ensureLoaded();
    }
    // Start with an empty grid so every (leg, type) counter exists at 0.
    for (final leg in _legs) {
      _cells[leg] = {for (final t in _selectableTypes) t: _Cell()};
    }
    final e = widget.initial;
    if (e != null) {
      _name.text = e.name;
      _phone.text = normalisePhone(e.phone);
      _hydrateCells(e);
      if (e.note != null && e.note!.isNotEmpty) {
        _note.text = e.note!;
        _showNote = true;
      }
      _pickupId = e.pickupLocationId;
      _pickupName = e.pickupLocationName;
    }
    // Open on the first leg that already has seats (so an edit lands on a
    // populated tab), else the first tab (Full trip, or the forced leg).
    _activeLeg = _legs.firstWhere(
      (l) => _legSeatCount(l) > 0,
      orElse: () => _legs.first,
    );
  }

  /// Fill the counter grid from the initial. Prefer the per-line list (each line
  /// drops into its stored leg's tab); fall back to the legacy scalar counts
  /// (all on the legacy [BookingCaptureInitial.tripType]).
  void _hydrateCells(BookingCaptureInitial e) {
    final selectable = _selectableTypes.toSet();

    void add(TripType leg, SeatType type, int qty, SeatPosition? pos) {
      if (qty <= 0 || !selectable.contains(type)) return;
      // A forced-leg surface has a single tab — funnel everything into it. An
      // unknown leg (shouldn't happen) also falls back to the first tab.
      final l =
          widget.forcedLeg ?? (_cells.containsKey(leg) ? leg : _legs.first);
      final cell = _cells[l]?[type];
      if (cell == null) return;
      cell.qty = (cell.qty + qty).clamp(0, widget.maxPerType);
      // Keep the first non-null berth we see (the form can't set it, only carry
      // it through). A type change never happens here, so it stays valid.
      cell.position ??= pos;
    }

    if (e.lines.isNotEmpty) {
      for (final l in e.lines) {
        add(l.leg, l.seatType, l.qty, l.position);
      }
    } else {
      add(e.tripType, SeatType.doubleSofa, e.doubleSofa, null);
      add(e.tripType, SeatType.singleSofa, e.singleSofa, null);
      if (widget.showSeater) add(e.tripType, SeatType.seater, e.seater, null);
    }
  }

  @override
  void dispose() {
    _nameFocus.removeListener(_onNameFocusChanged);
    _nameFocus.dispose();
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

    // Pickup is required on every surface (admin add / edit / return-ticket and
    // the customer form alike), but only when a real pickup list exists — a
    // tour with no configured pickups (the field is hidden) must never be
    // blocked from booking.
    String? pickupError;
    final pickupRequired = widget.requirePickup &&
        _pickup != null &&
        _pickup!.active.isNotEmpty;
    if (pickupRequired && (_pickupId == null || _pickupId!.isEmpty)) {
      pickupError = tr('booking_form.err_pickup_required');
    }

    if (nameError != null ||
        phoneError != null ||
        seatsError != null ||
        pickupError != null) {
      setState(() {
        _nameError = nameError;
        _phoneError = phoneError;
        _seatsError = seatsError;
        _pickupError = pickupError;
      });
      return null;
    }

    final note = _note.text.trim();

    // One RequestLine per non-empty (leg, type) cell. Empty cells are dropped.
    final lines = <RequestLine>[
      for (final leg in _legs)
        for (final type in _selectableTypes)
          if ((_cells[leg]?[type]?.qty ?? 0) > 0)
            RequestLine(
              seatType: type,
              position: _cells[leg]![type]!.position,
              qty: _cells[leg]![type]!.qty,
              leg: widget.forcedLeg ?? leg,
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
      pickupLocationId: _pickupId,
      pickupLocationName: _pickupName,
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

  /// Collapse the autocomplete list once the name field is no longer focused.
  /// Only touches state when there's something to hide, so it's a cheap no-op
  /// on gaining focus.
  void _onNameFocusChanged() {
    if (_nameFocus.hasFocus || _contactMatches.isEmpty || !mounted) return;
    setState(() => _contactMatches = const []);
  }

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

  // ─── PICKUP POINT (required, global list) ─────────────────────────────────

  /// Open the single-select pickup sheet: every ACTIVE point, plus a top
  /// "clear" row only while [BookingCaptureForm.requirePickup] is off. Pops the
  /// chosen id, [_kPickupClear] for the clear row, or null on dismiss (leaving
  /// the current selection untouched).
  Future<void> _openPickupSheet() async {
    final pickup = _pickup;
    if (pickup == null) return;
    final options = pickup.active;
    FocusScope.of(context).unfocus();
    final result = await UgamSheet.show<String>(
      context,
      title: tr('pickup.sheet_title'),
      builder: (_) => _PickupPickerSheet(
        options: options,
        selectedId: _pickupId,
        // When pickup is mandatory, drop the "No pickup point" clear row so the
        // customer can't re-empty a required field.
        allowClear: !widget.requirePickup,
      ),
    );
    if (result == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (result == _kPickupClear) {
        _pickupId = null;
        _pickupName = null;
      } else {
        PickupLocation? loc;
        for (final p in options) {
          if (p.id == result) {
            loc = p;
            break;
          }
        }
        if (loc != null) {
          _pickupId = loc.id;
          _pickupName = loc.name;
          _pickupError = null;
        }
      }
    });
    _notify();
  }

  // ─── SEAT COUNTERS ────────────────────────────────────────────────────────

  /// Set the quantity for one seat type on a given leg's tab.
  void _setQty(TripType leg, SeatType type, int v) => setState(() {
    final cell = _cells[leg]?[type];
    if (cell == null) return;
    cell.qty = v.clamp(0, widget.maxPerType);
    if (_totalSeats > 0) _seatsError = null;
    _notify();
  });

  /// Switch the active leg tab.
  void _selectLeg(TripType leg) {
    if (_activeLeg == leg) return;
    HapticFeedback.selectionClick();
    setState(() => _activeLeg = leg);
  }

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
          focusNode: widget.enableContacts ? _nameFocus : null,
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
                  // Typing the number is an intent to move on — drop any stale
                  // name-autocomplete list that survived the focus change.
                  if (_phoneError != null || _contactMatches.isNotEmpty) {
                    setState(() {
                      _phoneError = null;
                      _contactMatches = const [];
                    });
                  }
                  _notify();
                },
        ),
        const SizedBox(height: UgamSpacing.xl),
        _SectionEyebrow(label: tr('booking_form.label_seat_count'), c: c),
        const SizedBox(height: UgamSpacing.md),
        // Leg picker (the PRIMARY axis). Hidden on a forced-leg surface, where
        // there's only one leg and tabs would be noise.
        if (widget.forcedLeg == null) ...[
          _LegTabs(
            c: c,
            legs: _legs,
            active: _activeLeg,
            labelOf: _legLabel,
            iconOf: _legIcon,
            countOf: _legSeatCount,
            onSelect: _selectLeg,
          ),
          const SizedBox(height: UgamSpacing.md),
        ],
        // The active leg's seat-type counters.
        for (var i = 0; i < _selectableTypes.length; i++) ...[
          if (i > 0) const SizedBox(height: UgamSpacing.sm),
          _SeatCounterTile(
            key: ValueKey(
              'seatcell-${_activeLeg.name}-${_selectableTypes[i].name}',
            ),
            addKey: Key('seat-add-${_selectableTypes[i].name}'),
            minusKey: Key('seat-minus-${_selectableTypes[i].name}'),
            icon: _seatIcon(_selectableTypes[i]),
            label: _seatLabel(_selectableTypes[i]),
            sublabel: _seatSublabel(_selectableTypes[i]),
            value: _cells[_activeLeg]?[_selectableTypes[i]]?.qty ?? 0,
            maxPerType: widget.maxPerType,
            onChanged: (v) => _setQty(_activeLeg, _selectableTypes[i], v),
            onTapValue: () => _promptQuantity(
              title: _seatLabel(_selectableTypes[i]),
              current: _cells[_activeLeg]?[_selectableTypes[i]]?.qty ?? 0,
              onSet: (v) => _setQty(_activeLeg, _selectableTypes[i], v),
            ),
          ),
        ],
        const SizedBox(height: UgamSpacing.md),
        _SeatTotalLine(c: c, total: _totalSeats),
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
        _buildPickupField(c),
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

  /// Pickup-point selector. Hidden entirely when the controller isn't
  /// registered or the active list is empty; wrapped in an [Obx] so it appears
  /// on its own once [PickupController.ensureLoaded] resolves. Tapping opens
  /// [_openPickupSheet]. Required only when [BookingCaptureForm.requirePickup]
  /// is set AND a non-empty list exists (see [collect]).
  Widget _buildPickupField(UgamColorSet c) {
    final pickup = _pickup;
    if (pickup == null) return const SizedBox.shrink();
    return Obx(() {
      // Touch an Rx so this rebuilds when the list finishes loading.
      pickup.loadedOnce.value;
      final options = pickup.active;
      if (options.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UgamPickerField(
            label: tr('pickup.form_label'),
            value: _pickupName ?? '',
            placeholder: widget.requirePickup
                ? tr('pickup.form_placeholder_required')
                : tr('pickup.form_placeholder'),
            icon: Icons.place_rounded,
            onTap: _openPickupSheet,
          ),
          if (_pickupError != null) ...[
            const SizedBox(height: UgamSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                _pickupError!,
                style: UgamText.caption.copyWith(color: c.danger),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
        ],
      );
    });
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

// ─── LEG TABS (the PRIMARY axis — pick which leg you're booking for) ─────────

/// Three pill tabs (Full trip / Go only / Return only), each badged with how
/// many seats sit on that leg so a split is visible without switching tabs.
class _LegTabs extends StatelessWidget {
  final UgamColorSet c;
  final List<TripType> legs;
  final TripType active;
  final String Function(TripType) labelOf;
  final IconData Function(TripType) iconOf;
  final int Function(TripType) countOf;
  final ValueChanged<TripType> onSelect;

  const _LegTabs({
    required this.c,
    required this.legs,
    required this.active,
    required this.labelOf,
    required this.iconOf,
    required this.countOf,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight + stretch so every tab matches the tallest: a label that
    // wraps to 2 lines in one leg won't leave its neighbours shorter.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0) const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _LegTab(
                key: Key('legtab-${legs[i].name}'),
                c: c,
                label: labelOf(legs[i]),
                icon: iconOf(legs[i]),
                count: countOf(legs[i]),
                active: legs[i] == active,
                onTap: () => onSelect(legs[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LegTab extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  final IconData icon;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _LegTab({
    super.key,
    required this.c,
    required this.label,
    required this.icon,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Vertical layout: the direction glyph (+ optional seat-count badge) sits on
    // top and the full leg word runs across the tab's whole width below it,
    // centred and free to wrap to 2 lines. This keeps the label readable in
    // every locale — the long gu/hi words ("આવક-જાવક", "ફક્ત આવવા") no longer
    // fight an inline icon for horizontal room and get ellipsised — WITHOUT
    // depending on fragile locale detection to decide whether to show the icon.
    final fg = active ? c.accent : c.ink2;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.sm,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(
            color: active ? c.accent : c.border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: fg),
                if (count > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color:
                          active ? c.accent : c.ink3.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: active ? c.onAccent : c.ink2,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: UgamText.bodyStrong.copyWith(
                color: fg,
                fontSize: 12,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── SEAT COUNTER TILE (one seat type within the active leg) ────────────────

/// One seat-type counter: type label/icon + a tappable typed qty with +/- fine
/// adjust. The type is fixed (it's a fixed row per tab), so there's no type
/// swap, leg chip, or remove button — the leg lives in the tab above.
class _SeatCounterTile extends StatelessWidget {
  final Key addKey;
  final Key minusKey;
  final IconData icon;
  final String label;
  final String sublabel;
  final int value;
  final int maxPerType;
  final ValueChanged<int> onChanged;
  final VoidCallback onTapValue;

  const _SeatCounterTile({
    super.key,
    required this.addKey,
    required this.minusKey,
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
        UgamSpacing.md,
        UgamSpacing.sm + 2,
        UgamSpacing.md,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11),
                ),
              ],
            ),
          ),
          _StepperButton(
            key: minusKey,
            icon: Icons.remove_rounded,
            enabled: value > 0,
            onTap: () {
              HapticFeedback.lightImpact();
              onChanged(value - 1);
            },
          ),
          // Tappable value — opens the numeric keypad so a large quantity is one
          // type action instead of N taps.
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTapValue();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              // >=44px min hit target on the most-used booking interaction while
              // the pill stays visually compact.
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
            key: addKey,
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

// ─── SEAT TOTAL LINE ─────────────────────────────────────────────────────────

/// Running "N seats total" under the tabs, so the booking size is always
/// visible even while standing on a single leg's tab.
class _SeatTotalLine extends StatelessWidget {
  final UgamColorSet c;
  final int total;
  const _SeatTotalLine({required this.c, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        tr('booking_form.seats_total', namedArgs: {'count': '$total'}),
        style: UgamText.caption.copyWith(color: total > 0 ? c.ink2 : c.ink3),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperButton({
    super.key,
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
      // 44×44 hit target (accessibility minimum) wrapping the compact 32×32
      // visual chip — the stepper is the single most-used tap here.
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: enabled ? c.accent : c.card,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: enabled ? c.onAccent : c.ink3),
          ),
        ),
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

// ─── PICKUP PICKER SHEET (self-contained, single-select) ────────────────────

/// Sentinel popped by the "clear" row so the caller can tell an explicit
/// "No pickup point" apart from a dismissed sheet (which pops null). No real
/// pickup id (a uuid) can ever equal it.
const String _kPickupClear = '__pickup_clear__';

/// Single-select list of ACTIVE pickup points, with a top "clear" row. Pops the
/// chosen point's id, [_kPickupClear] for clear, or null when dismissed. The
/// currently-selected row shows a check. Mirrors the contact picker's row idiom.
class _PickupPickerSheet extends StatelessWidget {
  final List<PickupLocation> options;
  final String? selectedId;

  /// Whether to show the top "No pickup point" clear row. Off when pickup is
  /// mandatory so the customer can't re-empty a required field.
  final bool allowClear;

  const _PickupPickerSheet({
    required this.options,
    required this.selectedId,
    this.allowClear = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: options.length + (allowClear ? 1 : 0),
        itemBuilder: (_, i) {
          if (allowClear && i == 0) {
            return _PickupOptionRow(
              c: c,
              icon: Icons.not_interested_rounded,
              label: tr('pickup.clear'),
              selected: selectedId == null,
              onTap: () => Navigator.of(context).pop(_kPickupClear),
            );
          }
          final p = options[allowClear ? i - 1 : i];
          return _PickupOptionRow(
            c: c,
            icon: Icons.place_rounded,
            label: p.name,
            selected: p.id == selectedId,
            onTap: () => Navigator.of(context).pop(p.id),
          );
        },
      ),
    );
  }
}

class _PickupOptionRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PickupOptionRow({
    required this.c,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(UgamRadius.input),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm + 2),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? c.accentFill : c.cardElev,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: selected ? c.accent : c.ink2),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.body.copyWith(color: c.ink),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 20, color: c.accent),
          ],
        ),
      ),
    );
  }
}
