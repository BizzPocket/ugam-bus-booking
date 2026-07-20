import 'tour_status.dart';

/// A single tour the queried phone number is the designated handler for,
/// resolved by the `handler_requests_by_phone` RPC. Each ref carries a
/// [requestId] — a booking_request id for that tour — so the UI can hand it
/// straight to the existing requestId-scoped HandlerBusChartScreen flow without
/// the handler ever entering a request id by hand. Only tours whose handler has
/// a booking_request appear here (the rest can't be managed via that flow).
class HandlerTourRef {
  final String requestId;
  final String tourId;
  final String tourTitle;
  final String fromCity;
  final String toCity;

  /// The tour's departure date as the raw server string; may be null.
  final String? departureDate;
  final String status;

  const HandlerTourRef({
    required this.requestId,
    required this.tourId,
    required this.tourTitle,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    required this.status,
  });

  /// Whether this handler tour is still live (worth showing in "Find my
  /// seat"). Keyed on lifecycle STATUS, never the departure date: a handler
  /// manages a tour across its whole lifecycle, so any non-completed status is
  /// live even long after departure. Only [TourStatus.completed] is history.
  bool get isLive => status.toLowerCase() != TourStatus.completed.name;

  factory HandlerTourRef.fromJson(Map<String, dynamic> m) {
    return HandlerTourRef(
      requestId: (m['request_id'] ?? '').toString(),
      tourId: (m['tour_id'] ?? '').toString(),
      tourTitle: (m['tour_title'] ?? '').toString(),
      fromCity: (m['from_city'] ?? '').toString(),
      toCity: (m['to_city'] ?? '').toString(),
      departureDate: m['departure_date']?.toString(),
      status: (m['status'] ?? '').toString(),
    );
  }
}
