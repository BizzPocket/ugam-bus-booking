import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';

/// Small formatting helpers shared by the customer screens (tour list, tour
/// detail, booking request, my requests), which each used to carry a private
/// copy.

const _monthShortKeys = [
  'app.month.short.jan',
  'app.month.short.feb',
  'app.month.short.mar',
  'app.month.short.apr',
  'app.month.short.may',
  'app.month.short.jun',
  'app.month.short.jul',
  'app.month.short.aug',
  'app.month.short.sep',
  'app.month.short.oct',
  'app.month.short.nov',
  'app.month.short.dec',
];

/// Localized 3-letter month abbreviation (`app.month.short.*`) for a 1-based
/// [month]. Never a hard-coded English array — that printed "OCT" on a
/// Gujarati screen.
String customerMonthShort(int month) => tr(_monthShortKeys[month - 1]);

/// Route monogram for a bus backdrop, e.g. "S→M" from "Surat"/"Mumbai".
/// Empty when neither city is set, so the backdrop shows just the bus motif.
String customerRouteInitials(String from, String to) {
  String first(String s) {
    final t = s.trim();
    return t.isEmpty ? '' : t.characters.first.toUpperCase();
  }

  final f = first(from);
  final t = first(to);
  if (f.isEmpty && t.isEmpty) return '';
  return '$f→$t';
}
