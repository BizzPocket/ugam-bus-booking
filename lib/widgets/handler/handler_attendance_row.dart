// One passenger row in the boarding list.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../design/group_color.dart';
import '../../design/ugam.dart';
import '../../models/passenger.dart';
import '../../utils/passenger_display.dart';
import 'handler_atoms.dart';

/// One attendance line: name over mobile on the left, the call button and the
/// present toggle side by side on the right.
///
/// It used to stack two full-width lines (name + toggle, then phone + call
/// button) with card padding around each, which came to ~120 px a rider —
/// THREE riders on a phone screen. Rendered against a real stop (17 riders at
/// વ્રજ ભૂમિ પાર્કિંગ, 2026-09-05) that was six screens of scrolling for one
/// pickup point, which is what made the roll call unusable. Pinning both
/// controls right and letting the name column take the rest keeps every rider
/// under 64 px while the name still wraps to two lines before it ellipses, so
/// nothing the handler calls out gets cut to "vi…".
///
class HandlerAttendanceRow extends StatelessWidget {
  final Passenger passenger;
  final bool present;
  final ValueChanged<bool> onChanged;
  final UgamColorSet c;

  /// Every seat code this rider holds on this bus (e.g. DL2 and DL9), in walk
  /// order. Shown as chips before the name on the boarding list.
  final List<String> seatLabels;

  /// When set, overrides [groupColorForId] for the group dot on this row.
  final Color? groupTint;

  /// Whether to show the rider's pickup point on the row. False inside a
  /// stop-grouped list, where the section header already says the stop and
  /// repeating it on every row is pure noise.
  final bool showPickup;

  const HandlerAttendanceRow({
    super.key,
    required this.passenger,
    required this.present,
    required this.onChanged,
    required this.c,
    this.seatLabels = const [],
    this.groupTint,
    this.showPickup = true,
  });

  Widget _seatChip(String label) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UgamSpacing.sm,
      vertical: 2,
    ),
    decoration: BoxDecoration(
      color: c.accentFill,
      borderRadius: BorderRadius.circular(UgamRadius.chip),
    ),
    child: Text(
      label,
      style: UgamText.micro.copyWith(color: c.accent),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup
        ? (groupTint ?? groupColorForId(p.groupId!))
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Name over mobile. The name wraps to two lines before it
          //    ellipses; the phone stays on one. ──────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (seatLabels.isNotEmpty) ...[
                      for (var i = 0; i < seatLabels.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        _seatChip(seatLabels[i]),
                      ],
                      const SizedBox(width: UgamSpacing.sm),
                    ],
                    Flexible(
                      child: Text(
                        p.displayName,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (groupColor != null) ...[
                      const SizedBox(width: UgamSpacing.sm),
                      // 6, matching UgamStatusDot's dot. The shared component
                      // can't be used directly — it resolves its colour from a
                      // 4-value tone enum, and a group colour is an arbitrary
                      // hue off the golden-angle generator.
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: groupColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        hasPhone ? p.phone : tr('handler_chart.no_mobile'),
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(
                            color: hasPhone ? c.ink2 : c.ink3,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showPickup) ...[
                      const SizedBox(width: UgamSpacing.sm),
                      HandlerPickupChip(passenger: p),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // ── Call · present toggle, pinned right. ─────────────────────────
          // Tap-to-call — reach a no-show straight from the roster.
          if (hasPhone) ...[
            const SizedBox(width: UgamSpacing.sm),
            HandlerCallButton(phone: p.phone),
          ],
          const SizedBox(width: UgamSpacing.sm),
          // `good` tone: green carries real meaning here ("marked present"),
          // not just "enabled". UgamSwitch also drops the old
          // `activeThumbColor: c.onAccent` — copper ink on a green track meant
          // the accent read as scattered down every row of a boarded bus. The
          // haptic and the Semantics(toggled:) wrapper live in it.
          UgamSwitch(
            value: present,
            onChanged: onChanged,
            tone: UgamSwitchTone.good,
            semanticLabel: tr('handler_chart.att_mark_present'),
          ),
        ],
      ),
    );
  }
}
