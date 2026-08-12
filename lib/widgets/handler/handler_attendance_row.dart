// One passenger row in the boarding list.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../design/group_color.dart';
import '../../design/ugam.dart';
import '../../models/passenger.dart';
import '../../utils/passenger_display.dart';
import 'handler_atoms.dart';

/// One attendance line, laid out over TWO lines so nothing has to ellipse:
///
///   line 1 — the passenger's NAME (full, wrapping) + group dot + pickup, with
///            the present / left-behind toggle pinned right;
///   line 2 — their mobile and the call button.
///
/// A single-line row could not hold all of that: the chips, phone, call button
/// and switch squeezed the name down to "vi…", which is useless on roll-call —
/// the handler calls the name out and looks for a hand. Splitting the row gives
/// the name the full width.
///
/// NO seat chip (user call, 2026-07-26): boarding is a name check, and the seat
/// id belongs to the grid view. Don't re-add it.
class HandlerAttendanceRow extends StatelessWidget {
  final Passenger passenger;
  final bool present;
  final ValueChanged<bool> onChanged;
  final UgamColorSet c;

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
    this.showPickup = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColorForId(p.groupId!) : null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Line 1: name (+ group dot, pickup) · present toggle ──────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: UgamSpacing.sm,
                  runSpacing: UgamSpacing.xs,
                  children: [
                    Text(
                      p.displayName,
                      style: UgamText.bodyStrong.copyWith(color: c.ink),
                    ),
                    if (groupColor != null)
                      // 6, matching UgamStatusDot's dot. The shared component
                      // can't be used directly — it resolves its colour from a
                      // 4-value tone enum, and a group colour is an arbitrary
                      // hue off the golden-angle generator.
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(bottom: 3),
                        decoration: BoxDecoration(
                          color: groupColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    if (showPickup) HandlerPickupChip(passenger: p),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // `good` tone: green carries real meaning here ("marked
              // present"), not just "enabled". UgamSwitch also drops the old
              // `activeThumbColor: c.onAccent` — copper ink on a green track
              // meant the accent read as scattered down every row of a boarded
              // bus. The haptic and the Semantics(toggled:) wrapper live in it.
              UgamSwitch(
                value: present,
                onChanged: onChanged,
                tone: UgamSwitchTone.good,
                semanticLabel: tr('handler_chart.att_mark_present'),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          // ── Line 2: mobile · call ────────────────────────────────────────
          // No seat chip: roll-call is done by NAME, and the seat id is the
          // grid view's job (user call, 2026-07-26).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
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
              // Tap-to-call — reach a no-show straight from the roster.
              if (hasPhone) ...[
                const SizedBox(width: UgamSpacing.sm),
                HandlerCallButton(phone: p.phone),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
