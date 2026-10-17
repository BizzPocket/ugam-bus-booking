part of 'handler_trip_tab.dart';

/// The trip's stamped milestones, so the handler can see what they've already
/// confirmed — an "are we marked as departed?" question that previously had no
/// answer anywhere in the app.
class _TripLog extends StatelessWidget {
  final HandlerTripState trip;
  final UgamColorSet c;

  const _TripLog({required this.trip, required this.c});

  @override
  Widget build(BuildContext context) {
    final rows = <(String, DateTime?)>[
      (tr('handler_phase.log_departed_go'), trip.goDepartedAt),
      (tr('handler_phase.log_arrived_go'), trip.goArrivedAt),
      (tr('handler_phase.log_departed_ret'), trip.retDepartedAt),
      (tr('handler_phase.log_completed'), trip.completedAt),
    ];
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('handler_phase.log_title'),
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.sm),
          for (final (label, at) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.xs),
              child: Row(
                children: [
                  Icon(
                    at == null
                        ? Icons.radio_button_unchecked_rounded
                        : Icons.check_circle_rounded,
                    size: 14,
                    color: at == null ? c.ink3 : c.good,
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      style: UgamText.caption.copyWith(
                        color: at == null ? c.ink3 : c.ink,
                      ),
                    ),
                  ),
                  if (at != null)
                    Text(
                      hhmmFromTimeOfDay(TimeOfDay.fromDateTime(at)),
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String body;
  final VoidCallback onTap;
  final UgamColorSet c;
  final Color? tone;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.body,
    required this.onTap,
    required this.c,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tone ?? c.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamCard.plain(
        padding: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          child: Padding(
            padding: const EdgeInsets.all(UgamSpacing.md),
            child: Row(
              children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                      ),
                      Text(
                        body,
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One report the handler already sent, and whether the agent has seen it.
class _ReportRow extends StatelessWidget {
  final HandlerReport report;
  final UgamColorSet c;

  const _ReportRow({required this.report, required this.c});

  @override
  Widget build(BuildContext context) {
    final seen = report.isAcknowledged;
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              seen ? Icons.mark_email_read_rounded : Icons.schedule_rounded,
              size: 16,
              color: seen ? c.good : c.ink3,
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    report.kind.displayName,
                    style: UgamText.caption.copyWith(
                      color: report.kind.isUrgent ? c.warm : c.ink2,
                    ),
                  ),
                  Text(
                    report.message,
                    style: UgamText.body.copyWith(color: c.ink),
                  ),
                  Text(
                    seen
                        ? tr('handler_report.status_seen')
                        : tr('handler_report.status_sent'),
                    style: UgamText.micro.copyWith(color: c.ink3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
