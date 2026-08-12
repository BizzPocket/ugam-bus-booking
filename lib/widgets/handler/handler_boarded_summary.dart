// GO / RET boarded chips.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../design/group_color.dart';
import '../../design/ugam.dart';

// ─── Boarded summary chips ─────────────────────────────────────────────

/// Two compact chips under the money summary — GO and RET — each showing the
/// "Boarded {present}/{total}" tally for the current bus, tinted with the
/// chart's leg colours (GO cyan [kOneWayTint], RET violet [kReturnTint]) so the
/// boarding state is glanceable from every view mode.
class HandlerBoardedSummary extends StatelessWidget {
  final HandlerBoardedCounts go;
  final HandlerBoardedCounts ret;
  final UgamColorSet c;

  const HandlerBoardedSummary({
    super.key,
    required this.go,
    required this.ret,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BoardedChip(
            icon: Icons.north_east_rounded,
            tint: kOneWayTint,
            counts: go,
            c: c,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: _BoardedChip(
            icon: Icons.south_west_rounded,
            tint: kReturnTint,
            counts: ret,
            c: c,
          ),
        ),
      ],
    );
  }
}

class _BoardedChip extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final HandlerBoardedCounts counts;
  final UgamColorSet c;

  const _BoardedChip({
    required this.icon,
    required this.tint,
    required this.counts,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: tint.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr(
                'handler_chart.att_boarded',
                namedArgs: {
                  'present': '${counts.present}',
                  'total': '${counts.total}',
                },
              ),
              style: UgamText.micro.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Summary header ────────────────────────────────────────────────────

/// Boarding tally for one bus + leg: how many of the [total] expected
/// passengers are marked [present], and by subtraction how many were left
/// behind.
class HandlerBoardedCounts {
  final int present;
  final int total;

  const HandlerBoardedCounts({required this.present, required this.total});

  int get left => total - present;
}
