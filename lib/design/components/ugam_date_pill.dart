import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Horizontal date selector. Each date renders as a squircle pill.
///
/// The active pill is **tonal** (accentFill + accent ink + hairline accent
/// border), matching [UgamSelectorPills] — solid copper stays reserved for the
/// one focal CTA per screen (the accent-rationing law). The inactive pill
/// carries a transparent border of the same width so selection never reflows
/// the strip.
class UgamDatePillRow extends StatefulWidget {
  final List<DateTime> dates;
  final DateTime selected;
  final ValueChanged<DateTime> onChanged;

  const UgamDatePillRow({
    super.key,
    required this.dates,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<UgamDatePillRow> createState() => _UgamDatePillRowState();
}

class _UgamDatePillRowState extends State<UgamDatePillRow> {
  final _ctrl = ScrollController();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        controller: _ctrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xs),
        itemCount: widget.dates.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (_, i) {
          final d = widget.dates[i];
          final active = _sameDay(d, widget.selected);
          return _DatePill(
            date: d,
            active: active,
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onChanged(d);
            },
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DatePill extends StatelessWidget {
  final DateTime date;
  final bool active;
  final VoidCallback onTap;

  const _DatePill({
    required this.date,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final dayLabel = DateFormat('E').format(date).toUpperCase();
    final dayNum = date.day.toString();

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        constraints: const BoxConstraints(minWidth: 54),
        padding: const EdgeInsets.symmetric(
          vertical: UgamSpacing.md,
          horizontal: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: active ? c.accentFill : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active
                ? c.accent.withValues(alpha: 0.32)
                : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              dayNum,
              style: UgamText.tabular(
                UgamText.titleM.copyWith(
                  color: active ? c.accent : c.ink,
                  fontSize: 19,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              dayLabel,
              style: UgamText.micro.copyWith(
                color: active ? c.accent.withValues(alpha: 0.88) : c.ink3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
