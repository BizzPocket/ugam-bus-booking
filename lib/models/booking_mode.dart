import 'package:easy_localization/easy_localization.dart';

/// How CUSTOMERS book seats on a tour.
///
/// Set per tour (migration 048, `tours.booking_mode`) so the two flows can run
/// side by side and a tour can be trialled on the new one without touching the
/// rest. Every existing tour defaults to [request].
///
/// - [request] — the legacy flow. The customer says "I need 2 double sofas",
///   the organiser tallies demand, books a bus, then assigns the seats by hand.
///   Seats stay hidden from the customer until the tour is LOCKED.
/// - [chart] — the customer taps their own seat on the live bus chart, the way
///   GSRTC and every Gujarat operator app works. Requires a bus WITH a layout
///   before the tour can sell, and the seat is theirs the moment they confirm.
enum BookingMode {
  request,
  chart;

  /// Storage key — must stay stable; `tours.booking_mode` holds these strings
  /// and a CHECK constraint rejects anything else.
  String get storageKey => name;

  String get displayName {
    switch (this) {
      case BookingMode.request:
        return tr('enums.booking_mode.request');
      case BookingMode.chart:
        return tr('enums.booking_mode.chart');
    }
  }

  String get description {
    switch (this) {
      case BookingMode.request:
        return tr('enums.booking_mode.request_desc');
      case BookingMode.chart:
        return tr('enums.booking_mode.chart_desc');
    }
  }

  /// True when customers pick their own seats off the chart.
  bool get isChart => this == BookingMode.chart;

  /// Whether a seat allocation may be shown to the customer BEFORE the tour is
  /// locked. In [request] mode assignments are provisional right up until the
  /// lock, so they stay hidden (migration 025's lock gate). In [chart] mode the
  /// customer CHOSE the seat — hiding it back from them would be absurd.
  bool get revealsSeatsBeforeLock => this == BookingMode.chart;

  /// Unknown / missing values fall back to [request] so a tour row written
  /// before migration 048 — or read from a server that hasn't deployed it —
  /// keeps exactly today's behaviour.
  static BookingMode fromString(String? value) {
    if (value == null) return BookingMode.request;
    return BookingMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => BookingMode.request,
    );
  }
}
