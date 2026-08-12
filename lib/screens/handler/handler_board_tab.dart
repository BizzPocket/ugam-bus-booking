import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/handler_controller.dart';
import '../../design/ugam.dart';
import '../../models/attendance.dart';
import '../../models/bus_details.dart';
import '../../models/passenger.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/boarding_stops.dart';
import '../../widgets/handler/handler_stop_section.dart';

/// Boarding, worked the way it happens: one pickup point at a time.
///
/// The old attendance view was a flat switch list under static pickup headers,
/// every section expanded, no notion of where the bus was. Here the leg follows
/// the trip phase (a handler boarding the return no longer marks people onto
/// the outbound by accident), the current stop is the one that's open, and each
/// stop can be cleared in a single write.
class HandlerBoardTab extends StatefulWidget {
  final HandlerController controller;
  final Bus bus;

  const HandlerBoardTab({
    super.key,
    required this.controller,
    required this.bus,
  });

  @override
  State<HandlerBoardTab> createState() => _HandlerBoardTabState();
}

class _HandlerBoardTabState extends State<HandlerBoardTab> {
  /// Stops the handler has re-opened by hand, keyed by the stop label. Finished
  /// stops collapse, but somebody always turns up late, so they stay reachable.
  final _expanded = <String>{};

  /// Guards the bulk board so a double tap can't fire two rounds of writes.
  bool _bulkRunning = false;

  HandlerController get c => widget.controller;

  Future<void> _setPresent(Passenger p, AttendanceLeg leg, bool present) async {
    try {
      await c.setPresent(widget.bus, p, leg, present);
    } catch (_) {
      if (mounted) {
        AppSnackBar.error(tr('handler_chart.error_save_attendance'));
      }
    }
  }

  Future<void> _boardAll(AttendanceLeg leg, BoardingStop stop) async {
    if (_bulkRunning) return;
    setState(() => _bulkRunning = true);
    final done = await c.boardAllAt(widget.bus, leg, stop);
    if (!mounted) return;
    setState(() => _bulkRunning = false);
    final missed = stop.pending - done;
    if (missed > 0) {
      // Partial success is reported honestly rather than as a flat failure —
      // the riders that did land are banked, and the rest are still on screen.
      AppSnackBar.warning(
        tr(
          'handler_chart.stop_board_all_partial',
          namedArgs: {'done': '$done', 'failed': '$missed'},
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = UgamColors.of(context);
    return Obx(() {
      final leg = c.legForBoarding;
      final progress = c.boardingFor(widget.bus, leg);

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
          UgamTabPills(
            items: [
              UgamTabItem(label: tr('handler_chart.att_leg_go')),
              UgamTabItem(label: tr('handler_chart.att_leg_ret')),
            ],
            currentIndex: leg == AttendanceLeg.go ? 0 : 1,
            onChanged: (i) =>
                c.setLeg(i == 0 ? AttendanceLeg.go : AttendanceLeg.ret),
          ),
          const SizedBox(height: UgamSpacing.md),
          _BoardingTally(progress: progress, c: colors),
          const SizedBox(height: UgamSpacing.md),
          if (progress.stops.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: UgamSpacing.huge),
              child: UgamEmpty(
                icon: Icons.how_to_reg_outlined,
                title: tr('handler_chart.att_none'),
                body: leg == AttendanceLeg.go
                    ? tr('handler_chart.att_none_go_body')
                    : tr('handler_chart.att_none_ret_body'),
              ),
            )
          else
            for (var i = 0; i < progress.stops.length; i++)
              HandlerStopSection(
                stop: progress.stops[i],
                isCurrent: progress.currentIndex == i,
                isExpanded: _expanded.contains(_key(progress.stops[i], i)),
                onToggleExpanded: () => setState(() {
                  final k = _key(progress.stops[i], i);
                  _expanded.contains(k)
                      ? _expanded.remove(k)
                      : _expanded.add(k);
                }),
                onSetPresent: (p, v) => _setPresent(p, leg, v),
                onBoardAll: _bulkRunning
                    ? null
                    : () => _boardAll(leg, progress.stops[i]),
                isPresent: (p) => c.isPresent(p.id, widget.bus.id, leg),
                c: colors,
              ),
        ],
      );
    });
  }

  /// Index-qualified so two stops that share a name (or two unassigned
  /// buckets) can't toggle each other.
  String _key(BoardingStop stop, int i) => '$i|${stop.locationName ?? ''}';
}

/// Present / left behind / total, plus how many stops are cleared.
class _BoardingTally extends StatelessWidget {
  final BoardingProgress progress;
  final UgamColorSet c;

  const _BoardingTally({required this.progress, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          _Stat(
            value: '${progress.boarded}',
            label: tr('handler_chart.att_present'),
            tone: c.good,
            c: c,
          ),
          _Stat(
            value: '${progress.pending}',
            label: tr('handler_chart.att_left_behind'),
            tone: progress.pending > 0 ? c.warm : c.ink2,
            c: c,
          ),
          _Stat(
            value: '${progress.stopsComplete}/${progress.stops.length}',
            label: tr('handler_chart.stops_done'),
            tone: c.ink2,
            c: c,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final Color tone;
  final UgamColorSet c;

  const _Stat({
    required this.value,
    required this.label,
    required this.tone,
    required this.c,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(value, style: UgamText.numLg.copyWith(color: tone)),
        Text(
          label,
          style: UgamText.caption.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}
