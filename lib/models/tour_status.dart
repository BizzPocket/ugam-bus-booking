enum TourStatus {
  planning,    // Tour created, not yet broadcast
  collecting,  // Broadcast sent, collecting seat requests
  booked,      // Bus booked with owner
  assigning,   // Assigning seats to passengers
  locked,      // All seats assigned, notifications sent
  completed;   // Trip done

  String get displayName {
    switch (this) {
      case TourStatus.planning:
        return 'Planning';
      case TourStatus.collecting:
        return 'Collecting';
      case TourStatus.booked:
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
      case TourStatus.booked:
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
      case TourStatus.booked:
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
}
