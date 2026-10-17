import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/pickup_controller.dart';
import '../controllers/user_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/app_user.dart';
import '../models/bus_details.dart';
import '../models/pickup_location.dart';
import '../models/request_band.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import '../services/contact_sync_service.dart';
import '../utils/band_options.dart';
import '../utils/chart_seat_availability.dart';
import '../utils/formatters.dart';
import '../utils/phone_normalize.dart';
import '../utils/request_pricing.dart';
import 'band_picker_dialog.dart';

part 'booking_capture_form/models.dart';
part 'booking_capture_form/form_handlers.dart';
part 'booking_capture_form/seat_widgets.dart';
part 'booking_capture_form/picker_sheets.dart';

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

  /// The tour's buses, used ONLY to price the FULL-TRIP tab by price band.
  ///
  /// Empty (the default) keeps this form exactly as it has always behaved:
  /// plain quantity steppers on every tab and unpriced request lines. That is
  /// what the admin add/edit surfaces pass, and what a customer sees on a tour
  /// whose buses are not priced yet — a band cannot be quoted from nothing, and
  /// quoting Rs 0 would let a rider be treated as paid without paying.
  ///
  /// When bands ARE available, the full-trip tab asks which band each seat is
  /// for. The one-leg tabs never do: a Go-only or Return-only seat is free and
  /// joins the waiting list.
  final List<Bus> buses;

  /// Live per-seat occupancy keyed `busId|seatId`, arriving with [buses] from
  /// the same RPC round-trip. Drives the "N left" figure and the sold-out state
  /// in the band picker.
  ///
  /// ADVISORY. It is a snapshot the device fetched seconds ago, so it stops a
  /// customer committing to a band that is visibly gone — it does NOT guarantee
  /// the seat. Only a server-side hold can do that.
  final Map<String, SeatAvailability> availability;

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
    this.buses = const [],
    this.availability = const {},
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

  /// FULL-TRIP seats that carry a price band, keyed by seat type. A type
  /// appears here INSTEAD of its [_cells] round-trip counter whenever
  /// [_bandOptions] can offer it a band — the two never both hold quantity for
  /// the same (round-trip, type) pair, which is what keeps [_totalSeats] from
  /// double-counting.
  final Map<SeatType, List<_BandEntry>> _banded = {};

  /// Bands sellable per seat type, derived once from [BookingCaptureForm.buses].
  /// An empty list means this type cannot be banded, and it keeps the plain
  /// stepper on every tab.
  Map<SeatType, List<BandOption>> _bandOptions = const {};

  /// Whether [type] is sold by band on the full-trip tab.
  bool _isBanded(SeatType type) => (_bandOptions[type] ?? const []).isNotEmpty;

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
    n += _bandedBerths;
    return n;
  }

  /// Berths held by banded full-trip lines (a Double Sofa is two).
  int get _bandedBerths {
    var n = 0;
    for (final e in _banded.entries) {
      for (final entry in e.value) {
        n += entry.qty * e.key.berthsPerUnit;
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
    // Banded lines are round-trip by construction, so they weigh 1.0.
    return n + _bandedBerths;
  }

  /// Legs offered as tabs. A forced-leg surface collapses to just that one leg
  /// (and the tab bar is hidden). Order: Full trip, Go only, Return only.
  List<TripType> get _legs => widget.forcedLeg != null
      ? [widget.forcedLeg!]
      : const [TripType.roundTrip, TripType.outboundOnly, TripType.returnOnly];

  /// Seat *berths* booked on [leg] across all types (Double Sofa = 2) — drives
  /// the per-tab badge, kept in the same berth unit as the "Total seats" line.
  int _legSeatCount(TripType leg) {
    final plain = _cells[leg]?.entries.fold<int>(
          0,
          (s, e) => s + e.value.qty * e.key.berthsPerUnit,
        ) ??
        0;
    // Banded lines live only on the full-trip tab, so only its badge gains them.
    return leg == TripType.roundTrip ? plain + _bandedBerths : plain;
  }

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
    _recomputeBandOptions();
    // Start with an empty grid so every (leg, type) counter exists at 0.
    for (final leg in _legs) {
      _cells[leg] = {for (final t in _selectableTypes) t: _Cell()};
    }
    for (final t in _selectableTypes) {
      _banded[t] = <_BandEntry>[];
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

    void add(
      TripType leg,
      SeatType type,
      int qty,
      SeatPosition? pos, {
      RequestBand? band,
    }) {
      if (qty <= 0 || !selectable.contains(type)) return;
      // A forced-leg surface has a single tab — funnel everything into it. An
      // unknown leg (shouldn't happen) also falls back to the first tab.
      final l =
          widget.forcedLeg ?? (_cells.containsKey(leg) ? leg : _legs.first);
      // A banded seat type keeps ALL its full-trip quantity in [_banded] — a
      // legacy line with no band included, so re-opening an old request on a
      // now-banded tour still shows (and can remove) what was requested,
      // instead of stranding the quantity behind a stepper that isn't rendered.
      if (l == TripType.roundTrip && _isBanded(type)) {
        _banded[type]!.add(
          _BandEntry(
            band: band,
            qty: qty.clamp(0, widget.maxPerType),
            position: pos,
          ),
        );
        return;
      }
      final cell = _cells[l]?[type];
      if (cell == null) return;
      cell.qty = (cell.qty + qty).clamp(0, widget.maxPerType);
      // Keep the first non-null berth we see (the form can't set it, only carry
      // it through). A type change never happens here, so it stays valid.
      cell.position ??= pos;
    }

    if (e.lines.isNotEmpty) {
      for (final l in e.lines) {
        add(l.leg, l.seatType, l.qty, l.position, band: l.band);
      }
    } else {
      add(e.tripType, SeatType.doubleSofa, e.doubleSofa, null);
      add(e.tripType, SeatType.singleSofa, e.singleSofa, null);
      if (widget.showSeater) add(e.tripType, SeatType.seater, e.seater, null);
    }
  }

  /// The customer screen CANNOT read `Tour.buses` — `buses` has no anon SELECT
  /// policy — so it fetches them over `public_tour_buses` and hands them down
  /// on a LATER frame. Deriving the bands only in [initState] therefore derived
  /// them from an empty list and never again: on a real device the picker never
  /// appeared at all, while tests that passed buses up front all passed.
  ///
  /// Recomputed only when the bus list actually changes, not per build — the
  /// derivation scans every seat cell of every bus.
  @override
  void didUpdateWidget(covariant BookingCaptureForm old) {
    super.didUpdateWidget(old);
    final busesChanged = !identical(old.buses, widget.buses) &&
        !listEquals(old.buses, widget.buses);
    // Occupancy moves on its own as other customers book, and a stale "4 left"
    // is exactly the number that talks someone into paying for a gone seat.
    final occupancyChanged =
        !availabilityEquals(old.availability, widget.availability);
    if (busesChanged || occupancyChanged) {
      setState(_recomputeBandOptions);
    }
  }

  /// Derive the sellable bands per seat type, then move any quantity that has
  /// landed on the wrong side of the banded/unbanded split.
  ///
  /// Both directions matter, and both strand seats if skipped: a berth typed
  /// into the plain stepper BEFORE the buses arrived would sit behind a control
  /// that is no longer rendered, and a banded line on a tour that lost its
  /// pricing would do the same in reverse. Migrated quantity keeps its berths
  /// and simply carries no band, so it counts toward the request but not toward
  /// the price until the customer picks one.
  void _recomputeBandOptions() {
    _bandOptions = {
      for (final t in _selectableTypes)
        t: bandOptionsFor(
          buses: widget.buses,
          type: t,
          availability: widget.availability,
        ),
    };

    for (final type in _selectableTypes) {
      final roundTrip = _cells[TripType.roundTrip]?[type];
      final entries = _banded[type];
      if (entries == null) continue;

      if (_isBanded(type)) {
        // Newly banded: fold any plain full-trip quantity into a bandless line.
        if (roundTrip != null && roundTrip.qty > 0) {
          entries.add(_BandEntry(qty: roundTrip.qty, position: roundTrip.position));
          roundTrip.qty = 0;
        }
      } else if (entries.isNotEmpty) {
        // No longer banded: hand the berths back to the plain counter.
        if (roundTrip != null) {
          final total = entries.fold<int>(0, (s, e) => s + e.qty);
          roundTrip.qty = (roundTrip.qty + total).clamp(0, widget.maxPerType);
          roundTrip.position ??= entries.first.position;
        }
        entries.clear();
      }
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

  /// setState bridge for the `part`-file extension (setState is protected).
  void _update(VoidCallback fn) => setState(fn);

  // ─── PUBLIC CONTRACT ────────────────────────────────────────────────────

  /// The request lines as they stand RIGHT NOW, without validating anything.
  ///
  /// Pure (no setState, no error surfacing), so a host can read it from a
  /// widget build to price its own Pay button — the same reason
  /// [legWeightedSeats] exists. [collect] runs the identical assembly after it
  /// has validated, so the number on the button and the number submitted can
  /// never drift.
  List<RequestLine> get currentLines => _assembleLines();

  /// Paise the customer must pay before this request can be submitted. Zero
  /// when every line is free — a one-leg seat, or a tour with no bands.
  int get chargePaise => requestChargePaise(_assembleLines());

  /// One RequestLine per non-empty (leg, type) cell, plus one per chosen band
  /// on the full-trip tab. Empty cells are dropped.
  List<RequestLine> _assembleLines() => [
        for (final leg in _legs)
          for (final type in _selectableTypes)
            if ((_cells[leg]?[type]?.qty ?? 0) > 0)
              RequestLine(
                seatType: type,
                position: _cells[leg]![type]!.position,
                qty: _cells[leg]![type]!.qty,
                leg: widget.forcedLeg ?? leg,
              ),
        // The same seat type taken in two bands is TWO lines: each carries its
        // own price and its own row binding.
        for (final type in _selectableTypes)
          for (final entry in _banded[type] ?? const <_BandEntry>[])
            if (entry.qty > 0)
              RequestLine(
                seatType: type,
                position: entry.position,
                qty: entry.qty,
                leg: TripType.roundTrip,
                band: entry.band,
              ),
      ];

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

    final lines = _assembleLines();

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

  /// Switch the active leg tab.
  void _selectLeg(TripType leg) {
    if (_activeLeg == leg) return;
    HapticFeedback.selectionClick();
    setState(() => _activeLeg = leg);
  }

  /// Concise leg label for the per-row chip. Reuses the leg semantics of the old
  /// trip-type picker (Full trip / Go only / Return only).
  String _legLabel(TripType leg) => switch (leg) {
        TripType.roundTrip => tr('booking_form.leg_full'),
        TripType.outboundOnly => tr('booking_form.leg_go'),
        TripType.returnOnly => tr('booking_form.leg_ret'),
      };

  IconData _legIcon(TripType leg) => switch (leg) {
        TripType.roundTrip => Icons.sync_alt_rounded,
        TripType.outboundOnly => Icons.arrow_forward_rounded,
        TripType.returnOnly => Icons.arrow_back_rounded,
      };

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
        // The active leg's seat-type counters. On the FULL-TRIP tab a banded
        // type swaps its stepper for the band list — the customer has to say
        // which band they are buying into before they can be charged. Every
        // one-leg tab keeps the plain stepper: those seats are free.
        for (final (i, type) in _selectableTypes.indexed) ...[
          if (i > 0) const SizedBox(height: UgamSpacing.sm),
          if (_activeLeg == TripType.roundTrip && _isBanded(type))
            _BandedSeatTile(
              key: ValueKey('seatband-${type.name}'),
              type: type,
              icon: _seatIcon(type),
              label: _seatLabel(type),
              sublabel: _seatSublabel(type),
              entries: _banded[type] ?? const [],
              onAdd: () => _openBandPicker(type),
              onRemove: (index) => _removeBandEntry(type, index),
            )
          else
            _SeatCounterTile(
              key: ValueKey('seatcell-${_activeLeg.name}-${type.name}'),
              addKey: Key('seat-add-${type.name}'),
              minusKey: Key('seat-minus-${type.name}'),
              icon: _seatIcon(type),
              label: _seatLabel(type),
              sublabel: _seatSublabel(type),
              value: _cells[_activeLeg]?[type]?.qty ?? 0,
              maxPerType: widget.maxPerType,
              onChanged: (v) => _setQty(_activeLeg, type, v),
              onTapValue: () => _promptQuantity(
                title: _seatLabel(type),
                current: _cells[_activeLeg]?[type]?.qty ?? 0,
                onSet: (v) => _setQty(_activeLeg, type, v),
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

}
