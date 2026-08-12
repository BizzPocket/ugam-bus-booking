import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/handler_report.dart';
import '../services/handler_reports_repository.dart';
import '../utils/app_snackbar.dart';

/// The agent's end of the handler back-channel: problems raised from the bus,
/// shown on the tour they belong to.
///
/// Renders NOTHING when there is nothing open, which is the normal case — it
/// must not become permanent furniture on a screen that is already dense. An
/// urgent report (breakdown, seat dispute) takes the warm tone and also fires a
/// push; the rest wait here quietly.
class HandlerAlertsStrip extends StatefulWidget {
  final String tourId;

  /// Injected in tests; production builds its own.
  @visibleForTesting
  final HandlerReportsRepository? repository;

  const HandlerAlertsStrip({super.key, required this.tourId, this.repository});

  @override
  State<HandlerAlertsStrip> createState() => _HandlerAlertsStripState();
}

class _HandlerAlertsStripState extends State<HandlerAlertsStrip> {
  late final HandlerReportsRepository _repo =
      widget.repository ?? HandlerReportsRepository();

  List<HandlerReport> _reports = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _repo.fetchForTour(widget.tourId);
      if (!mounted) return;
      setState(() => _reports = rows);
    } catch (_) {
      // Silent: this is a secondary strip on a screen full of primary
      // information. A failed read shows nothing rather than an error card
      // over the tour the agent actually came here for.
    }
  }

  Future<void> _ack(HandlerReport r) async {
    setState(() => _busy = true);
    try {
      await _repo.acknowledge(r.id);
      await _load();
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('handler_report.alerts_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ackAll() async {
    setState(() => _busy = true);
    try {
      await _repo.acknowledgeAll(widget.tourId);
      await _load();
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('handler_report.alerts_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _reports.where((r) => !r.isAcknowledged).toList();
    // Nothing open = nothing shown. Acknowledged history lives in the report
    // rows themselves, not on the agent's busiest screen.
    if (open.isEmpty) return const SizedBox.shrink();

    final c = UgamColors.of(context);
    final urgent = open.any((r) => r.kind.isUrgent);
    final tone = urgent ? c.danger : c.warm;

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.support_agent_rounded, size: 18, color: tone),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('handler_report.alerts_title'),
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: urgent ? c.dangerFill : c.warmFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    tr(
                      'handler_report.alerts_open',
                      namedArgs: {'count': '${open.length}'},
                    ),
                    style: UgamText.micro.copyWith(color: tone),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            for (final r in open)
              Padding(
                padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(
                        color: r.kind.isUrgent ? c.danger : c.warm,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.kind.displayName,
                            style: UgamText.caption.copyWith(color: c.ink2),
                          ),
                          Text(
                            r.message,
                            style: UgamText.body.copyWith(color: c.ink),
                          ),
                          if (r.reportedBy != null &&
                              r.reportedBy!.trim().isNotEmpty)
                            Text(
                              r.reportedBy!,
                              style: UgamText.micro.copyWith(color: c.ink3),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _ack(r),
                      child: Text(tr('handler_report.alerts_ack')),
                    ),
                  ],
                ),
              ),
            if (open.length > 1)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: _busy ? null : _ackAll,
                  child: Text(tr('handler_report.alerts_ack_all')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
