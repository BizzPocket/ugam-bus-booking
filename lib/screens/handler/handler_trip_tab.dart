import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../components/content_block_view.dart';
import '../../controllers/handler_controller.dart';
import '../../design/ugam.dart';
import '../../models/attendance.dart';
import '../../models/bus_details.dart';
import '../../models/handler_phase.dart';
import '../../models/handler_report.dart';
import '../../services/location_tracker_service.dart';
import '../../services/whatsapp_cloud_service.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/time_format.dart';
import '../../utils/wa_error_text.dart';
import '../../widgets/handler/handler_boarded_summary.dart';
import '../../widgets/handler/handler_bus_info.dart';
import '../../widgets/handler/handler_message_sheet.dart';
import '../../widgets/handler/handler_report_sheet.dart';
import '../../widgets/tracking_status_card.dart';

/// Everything about the bus and the trip that isn't a passenger, a seat or a
/// rupee: who's driving, where it leaves from, live sharing, the broadcast, the
/// outbound seat release, and the back-channel to the agent.
///
/// These were the genuinely homeless features. The driver card and departure
/// line sat above both old tabs; the broadcast lived in an app-bar icon; the
/// leg-completion card floated between the settlement card and the boarding
/// list with no relationship to either; and reporting a problem did not exist
/// at all.
class HandlerTripTab extends StatefulWidget {
  final HandlerController controller;
  final Bus bus;

  /// The tracking-permission flow lives in the shell (it owns lifecycle), so
  /// the card's recovery action is passed down.
  final VoidCallback onTrackingFix;
  final VoidCallback onTrackingStop;

  const HandlerTripTab({
    super.key,
    required this.controller,
    required this.bus,
    required this.onTrackingFix,
    required this.onTrackingStop,
  });

  @override
  State<HandlerTripTab> createState() => _HandlerTripTabState();
}

class _HandlerTripTabState extends State<HandlerTripTab> {
  HandlerController get c => widget.controller;

  bool _releasing = false;

  // ── Broadcast ─────────────────────────────────────────────

  Future<void> _openComposer() async {
    await UgamSheet.show<void>(
      context,
      title: tr('bus_message.composer_title'),
      builder: (_) => HandlerBusMessageSheet(
        busLabel: widget.bus.name,
        onSend: (text) async {
          final result = await WhatsAppCloudService().sendBusMessageAsHandler(
            requestId: c.requestId,
            busId: widget.bus.id,
            message: text,
          );
          if (!mounted) return;
          if (result.allSent) {
            AppSnackBar.success(
              tr(
                'bus_message.sent_body',
                namedArgs: {'count': '${result.sent}'},
              ),
              title: tr('bus_message.sent_title'),
            );
          } else if (result.anySent) {
            AppSnackBar.warning(
              '${tr('bus_message.partial_body', namedArgs: {'sent': '${result.sent}', 'failed': '${result.failed}'})}${waFailureAppendix(result)}',
              title: tr('bus_message.partial_title'),
            );
          } else if (result.results.isEmpty) {
            AppSnackBar.warning(tr('bus_message.no_recipients'));
          } else {
            AppSnackBar.error(
              '${tr('bus_message.failed_body')}${waFailureAppendix(result)}',
              title: tr('bus_message.failed_title'),
            );
          }
        },
      ),
    );
  }

  // ── Report a problem ──────────────────────────────────────

  Future<void> _openReport() async {
    final draftId = c.newDraftId();
    await UgamSheet.show<void>(
      context,
      title: tr('handler_report.title'),
      builder: (_) => HandlerReportSheet(
        onSend: (kind, message) => c.sendReport(
          bus: widget.bus,
          draftId: draftId,
          kind: kind,
          message: message,
        ),
      ),
    );
  }

  // ── Outbound seat release ─────────────────────────────────

  /// Offered here only when the milestone stamp couldn't do it — normally
  /// arriving releases the outbound-only seats in the same action, and this
  /// card never appears.
  Future<void> _releaseOutbound() async {
    final state = c.legState[widget.bus.id];
    final pending =
        (state?.outboundOnlyTotal ?? 0) - (state?.outboundOnlyDone ?? 0);
    final ok = await UgamDialog.confirm(
      context,
      title: tr('handler_chart.leg_done_title'),
      message: tr(
        'handler_chart.leg_done_body',
        namedArgs: {'count': '$pending', 'bus': widget.bus.customerLabel},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('handler_chart.leg_done_confirm'),
      confirmIcon: Icons.flag_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _releasing = true);
    try {
      final cleared = await c.completeOutboundLeg(widget.bus);
      if (!mounted) return;
      AppSnackBar.success(
        tr('handler_chart.leg_done_ok', namedArgs: {'count': '$cleared'}),
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('handler_chart.leg_done_failed'));
    } finally {
      if (mounted) setState(() => _releasing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = UgamColors.of(context);
    return Obx(() {
      final legState = c.legState[widget.bus.id];
      final pendingRelease =
          (legState?.outboundOnlyTotal ?? 0) -
          (legState?.outboundOnlyDone ?? 0);
      final trip = c.tripFor(widget.bus.id);
      // Built once each: buildBoardingProgress regroups the whole roster, so
      // calling it per field would do that work four times a frame.
      final goBoarding = c.boardingFor(widget.bus, AttendanceLeg.go);
      final retBoarding = c.boardingFor(widget.bus, AttendanceLeg.ret);

      return ListView(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.md,
          UgamSpacing.gutter,
          UgamSpacing.huge3,
        ),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          // Server-driven slot: depot notices, a changed pickup point, "call
          // the office before departure". CONTENT ONLY — the chart geometry,
          // the collect sheet and the handover form stay native, because this
          // is where cash is counted and a surface that must be fetched cannot
          // render without signal.
          const ContentSlot(ContentSlots.handlerChartTop, role: 'handler'),
          HandlerBusDeparture(bus: widget.bus, c: colors),
          HandlerDriverContact(bus: widget.bus, c: colors),
          const SizedBox(height: UgamSpacing.md),

          _TripLog(trip: trip, c: colors),
          const SizedBox(height: UgamSpacing.md),

          // Both legs at a glance. The Board tab deliberately shows only the
          // leg being worked, so this is the one place the handler can see
          // whether the outbound tally is still complete after the return has
          // started.
          HandlerBoardedSummary(
            go: HandlerBoardedCounts(
              present: goBoarding.boarded,
              total: goBoarding.total,
            ),
            ret: HandlerBoardedCounts(
              present: retBoarding.boarded,
              total: retBoarding.total,
            ),
            c: colors,
          ),
          const SizedBox(height: UgamSpacing.md),

          // Live location: state + the one recovery action, then a small
          // confirmation map while actually sharing. Absent entirely under
          // `flutter test`, where the service is never registered.
          if (Get.isRegistered<LocationTrackerService>())
            Obx(() {
              final tracker = Get.find<LocationTrackerService>();
              final status = tracker.status.value;
              final sharing =
                  status == TrackingStatus.live ||
                  status == TrackingStatus.foregroundOnly;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TrackingStatusCard(
                    status: status,
                    lastUploadAt: tracker.lastUploadAt.value,
                    onStop: widget.onTrackingStop,
                    onFix: widget.onTrackingFix,
                  ),
                  if (sharing)
                    const Padding(
                      padding: EdgeInsets.only(bottom: UgamSpacing.sm),
                      child: HandlerOwnBusMap(),
                    ),
                ],
              );
            }),

          // Only when arriving failed to release them.
          if (pendingRelease > 0 && trip.goArrivedAt != null) ...[
            UgamCard.plain(
              padding: const EdgeInsets.all(UgamSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('handler_chart.leg_title'),
                    style: UgamText.bodyStrong.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                  Text(
                    tr(
                      'handler_chart.leg_pending',
                      namedArgs: {'count': '$pendingRelease'},
                    ),
                    style: UgamText.caption.copyWith(color: colors.ink2),
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  UgamCTA(
                    label: tr('handler_chart.leg_done_confirm'),
                    leadingIcon: Icons.flag_rounded,
                    onPressed: _releasing ? null : _releaseOutbound,
                  ),
                ],
              ),
            ),
            const SizedBox(height: UgamSpacing.md),
          ],

          UgamSectionLabel(tr('handler_trip.actions')),
          const SizedBox(height: UgamSpacing.sm),
          _ActionTile(
            icon: Icons.campaign_rounded,
            label: tr('bus_message.message_bus'),
            body: tr('handler_trip.broadcast_body'),
            onTap: _openComposer,
            c: colors,
          ),
          _ActionTile(
            icon: Icons.support_agent_rounded,
            label: tr('handler_report.title'),
            body: tr('handler_trip.report_body'),
            onTap: _openReport,
            c: colors,
            tone: colors.warm,
          ),

          if (c.reports.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.xl),
            UgamSectionLabel(tr('handler_report.sent_section')),
            const SizedBox(height: UgamSpacing.sm),
            for (final r in c.reports) _ReportRow(report: r, c: colors),
          ],
        ],
      );
    });
  }
}

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
