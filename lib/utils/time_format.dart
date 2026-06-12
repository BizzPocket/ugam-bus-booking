import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Helpers to move a tour's time-of-day between the three forms it lives in:
///   - `TimeOfDay`  — what the time picker hands back
///   - `'HH:mm'`    — the 24h string persisted on the Tour model / DB `time`
///   - period-word  — the localized label shown to agents and customers
///
/// Storing the canonical value as 'HH:mm' keeps the model Flutter-free; the
/// conversions here are the only place TimeOfDay and display formatting live.

/// `TimeOfDay` → canonical 'HH:mm' (24h, zero-padded).
String hhmmFromTimeOfDay(TimeOfDay t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Canonical 'HH:mm' → `TimeOfDay`, or null when the string is empty/invalid.
TimeOfDay? timeOfDayFromHhmm(String? hhmm) {
  if (hhmm == null) return null;
  final parts = hhmm.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

/// Canonical 'HH:mm' → localized period-word display label, or null when unset.
///
/// The hour is bucketed into a day-period (morning/afternoon/evening/night) and
/// rendered through `tr('time.period.<bucket>', namedArgs: {'time': h12:mm})`.
/// This unifies every locale via translation values rather than a hard-coded
/// marker: `en` yields "5:00 PM"/"5:00 AM" while `gu`/`hi` yield period words
/// (e.g. "સાંજે 5:00" / "शाम 5:00"). The 12h time is always present so the
/// AM/PM never drops out the way a locale-dependent symbol would.
String? formatHhMm(String? hhmm) {
  final t = timeOfDayFromHhmm(hhmm);
  if (t == null) return null;
  final bucket = t.hour < 12
      ? 'morning'
      : t.hour < 16
          ? 'afternoon'
          : t.hour < 20
              ? 'evening'
              : 'night';
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final mm = t.minute.toString().padLeft(2, '0');
  return tr('time.period.$bucket', namedArgs: {'time': '$h12:$mm'});
}
