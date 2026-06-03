/// Whether a passenger has an approved need for a priority (front / sofa) seat.
///
/// Priority is REQUESTED by the customer (an optional note) and APPROVED by the
/// agent. Only [approved] passengers are seated in front/sofa seats first by the
/// seating engine. Age is never auto-derived into priority.
enum PriorityStatus {
  none,
  requested,
  approved,
  declined;

  bool get isApproved => this == PriorityStatus.approved;
  bool get isPending => this == PriorityStatus.requested;

  String get displayName {
    switch (this) {
      case PriorityStatus.none:
        return 'None';
      case PriorityStatus.requested:
        return 'Priority requested';
      case PriorityStatus.approved:
        return 'Priority approved';
      case PriorityStatus.declined:
        return 'Priority declined';
    }
  }

  static PriorityStatus fromString(String? value) {
    if (value == null) return PriorityStatus.none;
    return PriorityStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PriorityStatus.none,
    );
  }
}
