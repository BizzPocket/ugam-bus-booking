import 'package:easy_localization/easy_localization.dart';

/// Tour lifecycle status — gates which screens/actions are available.
///
/// ```
/// planning → collecting → busBooked → assigning → locked → completed
/// ```
///
/// Auto transitions:
///   planning → collecting   (first passenger request arrives)
///   collecting → busBooked  (first bus added to tour)
///
/// Manual transitions:
///   busBooked → assigning   (agent taps "Continue assigning seats")
///   assigning → locked      (agent taps "Lock tour" — all assigned + handler set)
///   locked → completed      (agent taps "Mark completed" after trip)
enum TourStatus {
  planning, // Tour created, not yet broadcast
  collecting, // Broadcast sent, collecting seat requests
  busBooked, // Bus(es) booked with owner — details entered
  assigning, // Assigning seats to passengers
  locked, // All seats assigned, notifications sent
  completed; // Trip done

  String get displayName {
    switch (this) {
      case TourStatus.planning:
        return tr('enums.tour_status.planning');
      case TourStatus.collecting:
        return tr('enums.tour_status.collecting');
      case TourStatus.busBooked:
        return tr('enums.tour_status.bus_booked');
      case TourStatus.assigning:
        return tr('enums.tour_status.assigning');
      case TourStatus.locked:
        return tr('enums.tour_status.locked');
      case TourStatus.completed:
        return tr('enums.tour_status.completed');
    }
  }

  String get description {
    switch (this) {
      case TourStatus.planning:
        return tr('enums.tour_status.planning_desc');
      case TourStatus.collecting:
        return tr('enums.tour_status.collecting_desc');
      case TourStatus.busBooked:
        return tr('enums.tour_status.bus_booked_desc');
      case TourStatus.assigning:
        return tr('enums.tour_status.assigning_desc');
      case TourStatus.locked:
        return tr('enums.tour_status.locked_desc');
      case TourStatus.completed:
        return tr('enums.tour_status.completed_desc');
    }
  }

  int get stepIndex {
    switch (this) {
      case TourStatus.planning:
        return 0;
      case TourStatus.collecting:
        return 1;
      case TourStatus.busBooked:
        return 2;
      case TourStatus.assigning:
        return 3;
      case TourStatus.locked:
        return 4;
      case TourStatus.completed:
        return 5;
    }
  }

  static const int totalSteps = 6;

  /// Whether the tour is in an active (non-completed) state.
  bool get isActive => this != TourStatus.completed;

  /// Whether the tour still accepts NEW booking requests / passengers.
  ///
  /// Single source of truth for every book/add-request entry point (customer
  /// list, customer detail, customer booking form, admin/handler "Add
  /// request"). Bookings close the moment the organiser LOCKS the tour — at
  /// that point seats are assigned and notifications sent, so the allocation is
  /// final — and stay closed through the terminal [completed] state.
  bool get acceptsBookings =>
      this != TourStatus.locked && this != TourStatus.completed;

  /// Whether bus layout editing is allowed in this status.
  ///
  /// Seat reassignment stays allowed after [locked] (and even [completed] via
  /// the live chart until history takes over). Bus add/edit/duplicate/delete
  /// and layout rebuild stop once the tour is locked — bookings are closed and
  /// the chart that was notified must not silently change shape.
  bool get allowsLayoutEdit =>
      this == TourStatus.planning ||
      this == TourStatus.collecting ||
      this == TourStatus.busBooked ||
      this == TourStatus.assigning;
}
