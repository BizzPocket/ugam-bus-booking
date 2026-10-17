part of '../booking_capture_form.dart';

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

/// One banded line inside a FULL-TRIP seat type: the band the customer chose
/// and how many units of that type they took in it.
///
/// [band] is nullable only to carry a LEGACY full-trip line — a request saved
/// before bands existed, reopened for editing on a tour that now has them. Such
/// a line keeps its quantity and stays removable; it simply has no price.
class _BandEntry {
  RequestBand? band;
  int qty;
  SeatPosition? position;
  _BandEntry({this.band, required this.qty, this.position});
}
