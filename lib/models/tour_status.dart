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
        return 'Planning';
      case TourStatus.collecting:
        return 'Collecting';
      case TourStatus.busBooked:
        return 'Bus Booked';
      case TourStatus.assigning:
        return 'Assigning';
      case TourStatus.locked:
        return 'Locked';
      case TourStatus.completed:
        return 'Completed';
    }
  }

  String get description {
    switch (this) {
      case TourStatus.planning:
        return 'Set up tour details and get ready to broadcast';
      case TourStatus.collecting:
        return 'Collecting seat requests from passengers';
      case TourStatus.busBooked:
        return 'Bus booked — add bus details from the owner';
      case TourStatus.assigning:
        return 'Assign seats to each passenger';
      case TourStatus.locked:
        return 'Seats locked — passengers have been notified';
      case TourStatus.completed:
        return 'Trip completed';
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

  /// Whether bus layout editing is allowed in this status.
  bool get allowsLayoutEdit =>
      this == TourStatus.planning ||
      this == TourStatus.collecting ||
      this == TourStatus.busBooked ||
      this == TourStatus.assigning;
}
