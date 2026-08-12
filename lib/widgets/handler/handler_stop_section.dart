import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

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
    required this.c,
  });

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
              for (final p in stop.riders)
                HandlerAttendanceRow(
                  passenger: p,
                  present: isPresent(p),
                  onChanged: (v) => onSetPresent(p, v),
                  c: c,
                  // The header already names the stop.
                  showPickup: false,
                ),
              // The bulk action the flat list never had. At a stop where
              // everyone got on, six taps and six round-trips over 2G is the
              // difference between using the app and giving up on it.
              if (stop.pending > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.md,
                    0,
                    UgamSpacing.md,
                    UgamSpacing.md,
                  ),
                  child: UgamCTA(
                    label: tr(
                      'handler_chart.stop_board_all',
                      namedArgs: {'count': '${stop.pending}'},
                    ),
                    leadingIcon: Icons.done_all_rounded,
                    onPressed: onBoardAll,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
