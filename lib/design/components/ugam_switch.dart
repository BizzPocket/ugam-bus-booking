import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import '../ui_scale.dart';

/// Track tint for [UgamSwitch].
enum UgamSwitchTone {
  /// Default. A setting the user turns on/off (notifications, preferences).
  accent,

  /// A present/done state where green carries real meaning (attendance
  /// "marked present"), not just "enabled".
  good,
}

/// The app's one toggle. Wraps Material's [Switch] so the five raw call sites
/// stop each passing their own `activeTrackColor` / `activeThumbColor` pair.
///
/// The thumb is [UgamColorSet.bg], **not** `onAccent`. `onAccent` is the ink
/// that belongs on a copper fill; borrowing it for a green track drags accent
/// warmth onto a success control. `bg` reads as a neutral punched-out knob on
/// either track colour.
///
/// A null [onChanged] renders the switch disabled, matching every other Ugam
/// control.
class UgamSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final UgamSwitchTone tone;

  /// Screen-reader label. Supply it and the toggled state is announced too.
  final String? semanticLabel;

  const UgamSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.tone = UgamSwitchTone.accent,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final track = switch (tone) {
      UgamSwitchTone.accent => c.accent,
      UgamSwitchTone.good => c.good,
    };

    final sw = Switch(
      value: value,
      onChanged: onChanged == null
          ? null
          : (v) {
              HapticFeedback.lightImpact();
              onChanged!(v);
            },
      activeTrackColor: track,
      activeThumbColor: c.bg,
      inactiveTrackColor: c.cardElev,
      inactiveThumbColor: c.ink3,
    );

    // Interactive box: a floor, not a resize. Material already pads its own
    // tap target past 44, so this only guarantees the minimum on a host that
    // constrains the switch — it never clips the painted control.
    final sized = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: UgamScale.tap(context, 44),
        minHeight: UgamScale.tap(context, 44),
      ),
      child: Center(widthFactor: 1, heightFactor: 1, child: sw),
    );

    if (semanticLabel == null) return sized;
    return Semantics(label: semanticLabel, toggled: value, child: sized);
  }
}
