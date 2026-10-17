/// THE date rule for finishing a trip nobody remembered to finish.
///
/// Live, handlers stamp "departed" and then nothing — no "arrived", no "trip
/// finished". So both ends of the trip are also closed by the CALENDAR, and
/// every surface (the admin sweep in `TourController`, the handler's phase in
/// `HandlerController`) asks this file, so the two can never disagree about
/// whether the outbound is over.
///
///   * GO leg over   — at the START of the return day (local midnight). A tour
///                     with no return day after its departure day (one-way, or
///                     a same-day trip) has no such moment, so its GO leg ends
///                     with the trip: the start of the day after departure.
///   * Trip over     — at the start of the day AFTER the return day (or after
///                     the departure day for a one-way tour).
///
/// Dates are compared as calendar days in the phone's local zone; the time of
/// day stored on the tour (departure/return time) is deliberately ignored.
///
/// A return date EARLIER than the departure date is a typo (live has one:
/// departs 12 Sep, "returns" 15 Jun). Taken literally it completes the tour
/// before the bus leaves — which also closes the live-location window, since
/// the server only accepts fixes for a `locked` tour. Such a date is ignored
/// and the tour is treated as one-way.
library;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// The return day, or null when the tour has no usable one (absent, or before
/// the departure day).
DateTime? _usableReturnDay(DateTime departure, DateTime? returnDate) {
  if (returnDate == null) return null;
  final ret = _day(returnDate);
  return ret.isBefore(_day(departure)) ? null : ret;
}

/// The last calendar day of the trip.
DateTime tripLastDay({required DateTime departure, DateTime? returnDate}) =>
    _usableReturnDay(departure, returnDate) ?? _day(departure);

/// The moment the outbound (GO) leg counts as over without a stamp.
DateTime goLegAutoCompleteAt({
  required DateTime departure,
  DateTime? returnDate,
}) {
  final dep = _day(departure);
  final ret = _usableReturnDay(departure, returnDate);
  if (ret != null && ret.isAfter(dep)) return ret;
  // One-way or same-day: the outbound ends with the trip itself.
  return tripAutoCompleteAt(departure: departure, returnDate: returnDate);
}

/// The moment the whole trip counts as over without a stamp.
DateTime tripAutoCompleteAt({required DateTime departure, DateTime? returnDate}) {
  final last = tripLastDay(departure: departure, returnDate: returnDate);
  return DateTime(last.year, last.month, last.day + 1);
}

/// Whether [now] is at or past [goLegAutoCompleteAt].
bool isGoLegAutoComplete({
  required DateTime now,
  required DateTime departure,
  DateTime? returnDate,
}) =>
    !now.isBefore(
      goLegAutoCompleteAt(departure: departure, returnDate: returnDate),
    );

/// Whether [now] is at or past [tripAutoCompleteAt].
bool isTripAutoComplete({
  required DateTime now,
  required DateTime departure,
  DateTime? returnDate,
}) =>
    !now.isBefore(
      tripAutoCompleteAt(departure: departure, returnDate: returnDate),
    );

/// A tour's calendar plus its lifecycle status — all the handler side needs to
/// apply the rules above. Read from `tours` (publicly readable), because the
/// handler manifest RPC does not carry dates.
class TourSchedule {
  final DateTime departure;
  final DateTime? returnDate;

  /// `tours.status` as the server wrote it (`locked`, `completed`, …).
  final String status;

  const TourSchedule({
    required this.departure,
    this.returnDate,
    this.status = '',
  });

  /// Null when the row has no parseable departure date.
  static TourSchedule? fromMap(Map<dynamic, dynamic> map) {
    final dep = DateTime.tryParse((map['departure_date'] ?? '').toString());
    if (dep == null) return null;
    return TourSchedule(
      departure: dep,
      returnDate: DateTime.tryParse((map['return_date'] ?? '').toString()),
      status: (map['status'] ?? '').toString().trim().toLowerCase(),
    );
  }

  bool get isCompleted => status == 'completed';

  bool goLegOver(DateTime now) => isGoLegAutoComplete(
    now: now,
    departure: departure,
    returnDate: returnDate,
  );

  /// Over by the agent's hand or by the calendar.
  bool tripOver(DateTime now) =>
      isCompleted ||
      isTripAutoComplete(now: now, departure: departure, returnDate: returnDate);
}
