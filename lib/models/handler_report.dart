import 'package:easy_localization/easy_localization.dart';
import 'package:uuid/uuid.dart';

/// What the handler is flagging. Kept deliberately short: on a dark bus with
/// one hand free, a five-way chip row is the most that can be picked reliably,
/// and a free-text [HandlerReport.message] carries anything the chip can't.
enum HandlerReportKind {
  /// Bus won't run — the one that has to reach the agent fastest.
  breakdown,

  /// Running late, missed a connection, held up at a stop.
  delay,

  /// A rider problem: no-show, dispute, illness, wrong person.
  passenger,

  /// The chart is wrong on the ground — seat double-booked, rider in the
  /// wrong berth, a seat the handler cannot fix themselves (the handler's
  /// chart is read-only for seating by design).
  seat,

  other;

  String get displayName {
    switch (this) {
      case HandlerReportKind.breakdown:
        return tr('enums.handler_report_kind.breakdown');
      case HandlerReportKind.delay:
        return tr('enums.handler_report_kind.delay');
      case HandlerReportKind.passenger:
        return tr('enums.handler_report_kind.passenger');
      case HandlerReportKind.seat:
        return tr('enums.handler_report_kind.seat');
      case HandlerReportKind.other:
        return tr('enums.handler_report_kind.other');
    }
  }

  /// Breakdown and seat problems block the trip; the rest are informational.
  /// Drives the tone of the admin-side alert strip and whether the push is
  /// sent as urgent.
  bool get isUrgent =>
      this == HandlerReportKind.breakdown || this == HandlerReportKind.seat;

  static HandlerReportKind fromString(String? value) {
    return HandlerReportKind.values.firstWhere(
      (e) => e.name == value,
      orElse: () => HandlerReportKind.other,
    );
  }
}

/// A problem the handler raised with the agent from the bus.
///
/// This is the back-channel the handler flow never had. Until now a handler
/// could broadcast to their passengers and phone the driver, but had no way to
/// reach the agent except by leaving the app — so seat problems (which they
/// are deliberately not allowed to fix) had nowhere to go.
///
/// Acknowledgement is one-way and by the agent only: the handler sees "sent"
/// or "seen", never a reply thread. Two-way chat would need a whole
/// conversation surface, and the thing that actually matters on the bus is
/// knowing the message landed.
class HandlerReport {
  final String id;
  final String tourId;
  final String busId;
  final HandlerReportKind kind;
  final String message;

  /// Who raised it — the handler's own display name, denormalised at write
  /// time so the agent's strip needs no join back to passengers.
  final String? reportedBy;

  final DateTime createdAt;

  /// Stamped when the agent opens/acknowledges it. Null = still unread, which
  /// is what the dashboard badge counts.
  final DateTime? acknowledgedAt;

  HandlerReport({
    String? id,
    required this.tourId,
    required this.busId,
    this.kind = HandlerReportKind.other,
    required this.message,
    this.reportedBy,
    DateTime? createdAt,
    this.acknowledgedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  bool get isAcknowledged => acknowledgedAt != null;

  // ── Postgres serialization ────────────────────────────────

  Map<String, dynamic> toMap() => {
    'id': id,
    'tour_id': tourId,
    'bus_id': busId,
    'kind': kind.name,
    'message': message,
    'reported_by': reportedBy,
    'created_at': createdAt.toIso8601String(),
    // acknowledged_at is deliberately NOT written from the handler side — only
    // the agent can clear a report, and including it here would let a retry
    // from the bus silently un-acknowledge one the agent had already dealt
    // with.
  };

  factory HandlerReport.fromMap(Map<dynamic, dynamic> map) {
    DateTime? at(String key) {
      final raw = map[key];
      if (raw == null) return null;
      return DateTime.tryParse(raw.toString())?.toLocal();
    }

    return HandlerReport(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      busId: (map['bus_id'] ?? '').toString(),
      kind: HandlerReportKind.fromString(map['kind']?.toString()),
      message: (map['message'] ?? '').toString(),
      reportedBy: map['reported_by']?.toString(),
      createdAt: at('created_at') ?? DateTime.now(),
      acknowledgedAt: at('acknowledged_at'),
    );
  }

  HandlerReport copyWith({
    HandlerReportKind? kind,
    String? message,
    String? reportedBy,
    DateTime? acknowledgedAt,
  }) => HandlerReport(
    id: id,
    tourId: tourId,
    busId: busId,
    kind: kind ?? this.kind,
    message: message ?? this.message,
    reportedBy: reportedBy ?? this.reportedBy,
    createdAt: createdAt,
    acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
  );
}
