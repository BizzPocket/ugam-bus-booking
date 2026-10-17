import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/group_color.dart';
import '../../design/ugam.dart';
import '../../models/passenger.dart';
import '../../utils/boarding_stops.dart';
import 'handler_attendance_row.dart';

/// One pickup point in the boarding list, with the handler's progress through
/// it.
///
/// Replaces the flat pickup-grouped roster. The old list rendered every section
/// expanded at equal weight, so a handler at the third of six points scrolled
/// past two finished stops to reach the rows they needed, and nothing told them
/// whether they were clear to leave. Here the CURRENT stop is open and everything
/// else is a one-line summary the handler can tap to reopen — the finished stops
/// stay reachable (someone always turns up late) without competing for the
/// screen.
class HandlerStopSection extends StatelessWidget {
  final BoardingStop stop;

  /// The stop the bus is at — the only one expanded by default.
  final bool isCurrent;

  /// Forced open by the handler tapping a collapsed header.
  final bool isExpanded;

  final VoidCallback onToggleExpanded;
  final void Function(Passenger, bool) onSetPresent;

  /// Boards everyone still unmarked here in one action. Null while a bulk
  /// write is in flight.
  final VoidCallback? onBoardAll;

  final bool Function(Passenger) isPresent;

  /// Seat codes for each rider on this bus.
  final List<String> Function(Passenger passenger)? seatLabelsFor;

  final String? Function(String? groupId)? groupLabelFor;

  final Color Function(String groupId)? groupColorFor;

  final UgamColorSet c;

  const HandlerStopSection({
    super.key,
    required this.stop,
    required this.isCurrent,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onSetPresent,
    required this.onBoardAll,
    required this.isPresent,
    this.seatLabelsFor,
    this.groupLabelFor,
    this.groupColorFor,
    required this.c,
  });

  List<Widget> _riderBlocks() {
    final labelsFor = seatLabelsFor ?? (_) => const <String>[];
    final blocks = <Widget>[];
    var i = 0;
    while (i < stop.riders.length) {
      final p = stop.riders[i];
      final gid = p.groupId;
      if (gid == null || gid.isEmpty) {
        blocks.add(
          HandlerAttendanceRow(
            passenger: p,
            present: isPresent(p),
            onChanged: (v) => onSetPresent(p, v),
            seatLabels: labelsFor(p),
            c: c,
            showPickup: false,
          ),
        );
        i++;
        continue;
      }
      final run = <Passenger>[];
      while (i < stop.riders.length && stop.riders[i].groupId == gid) {
        run.add(stop.riders[i]);
        i++;
      }
      final tint = groupColorFor?.call(gid) ?? groupColorForId(gid);
      final groupLabel = groupLabelFor?.call(gid);
      blocks.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.sm,
            0,
            UgamSpacing.sm,
            UgamSpacing.xs,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: tint, width: 3),
              ),
              color: tint.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(UgamRadius.row),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (groupLabel != null || run.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.md,
                      UgamSpacing.sm,
                      UgamSpacing.md,
                      0,
                    ),
                    child: Text(
                      groupLabel != null
                          ? (run.length > 1
                                ? tr(
                                    'handler_chart.att_group_named',
                                    namedArgs: {
                                      'label': groupLabel,
                                      'count': '${run.length}',
                                    },
                                  )
                                : tr(
                                    'seating_exceptions.group_label',
                                    namedArgs: {'label': groupLabel},
                                  ))
                          : tr(
                              'handler_chart.att_group_together',
                              namedArgs: {'count': '${run.length}'},
                            ),
                      style: UgamText.caption.copyWith(color: tint),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final member in run)
                  HandlerAttendanceRow(
                    passenger: member,
                    present: isPresent(member),
                    onChanged: (v) => onSetPresent(member, v),
                    seatLabels: labelsFor(member),
                    groupTint: tint,
                    c: c,
                    showPickup: false,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return blocks;
  }

  @override
  Widget build(BuildContext context) {
    final open = isCurrent || isExpanded;
    final done = stop.isComplete;
    // Current > done > waiting. The current stop is the only one that gets the
    // accent; a finished stop goes quiet green rather than staying loud.
    final tone = isCurrent ? c.accent : (done ? c.good : c.ink3);
    final label = stop.isUnassigned
        ? tr('handler_chart.pickup_none')
        : stop.locationName!;

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamCard.plain(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onToggleExpanded,
              borderRadius: BorderRadius.circular(UgamRadius.card),
              child: Padding(
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Row(
                  children: [
                    Icon(
                      done
                          ? Icons.check_circle_rounded
                          : (isCurrent
                                ? Icons.my_location_rounded
                                : Icons.place_outlined),
                      size: 18,
                      color: tone,
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: UgamText.bodyStrong.copyWith(
                              color: isCurrent ? c.ink : c.ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            done
                                ? tr(
                                    'handler_chart.stop_all_aboard',
                                    namedArgs: {'count': '${stop.total}'},
                                  )
                                : tr(
                                    'handler_chart.stop_progress',
                                    namedArgs: {
                                      'boarded': '${stop.boarded}',
                                      'total': '${stop.total}',
                                    },
                                  ),
                            style: UgamText.caption.copyWith(color: c.ink2),
                          ),
                        ],
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: c.accentFill,
                          borderRadius: BorderRadius.circular(UgamRadius.chip),
                        ),
                        child: Text(
                          tr('handler_chart.stop_here'),
                          style: UgamText.micro.copyWith(color: c.accent),
                        ),
                      ),
                    Icon(
                      open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: c.ink3,
                    ),
                  ],
                ),
              ),
            ),
            if (open) ...[
              // The bulk action the flat list never had. At a stop where
              // everyone got on, six taps and six round-trips over 2G is the
              // difference between using the app and giving up on it.
              //
              // ABOVE the riders, not after them: at a 17-rider stop it used
              // to sit below the whole list, which on a phone meant scrolling
              // the very roster it exists to skip.
              if (stop.pending > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.md,
                    0,
                    UgamSpacing.md,
                    UgamSpacing.sm,
                  ),
                  // Tonal, not the solid CTA: it repeats once per stop, and the
                  // screen's one solid focal is the phase banner's milestone.
                  child: UgamButton(
                    label: tr(
                      'handler_chart.stop_board_all',
                      namedArgs: {'count': '${stop.pending}'},
                    ),
                    icon: Icons.done_all_rounded,
                    kind: UgamButtonKind.tonal,
                    expand: true,
                    onPressed: onBoardAll,
                  ),
                ),
              ..._riderBlocks(),
              const SizedBox(height: UgamSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }
}
