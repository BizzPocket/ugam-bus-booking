import 'package:easy_localization/easy_localization.dart';

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

  String get displayName => switch (this) {
        PriorityStatus.none => tr('enums.priority.none'),
        PriorityStatus.requested => tr('enums.priority.requested'),
        PriorityStatus.approved => tr('enums.priority.approved'),
        PriorityStatus.declined => tr('enums.priority.declined'),
      };

  static PriorityStatus fromString(String? value) {
    if (value == null) return PriorityStatus.none;
    return PriorityStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PriorityStatus.none,
    );
  }
}
