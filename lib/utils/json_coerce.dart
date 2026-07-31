/// Defensive coercions for values arriving from Supabase.
///
/// WHY THIS EXISTS
/// Model `fromMap` factories parse rows straight off the wire. A cast like
/// `map['note'] as String?` THROWS when the value isn't the expected type, and
/// because `_fetchToursWithRelations` parses the whole passengers array in one
/// pass, a single odd value takes down the ENTIRE tour load — `smartFetch`
/// catches it and returns `failed: true`, so the admin sees "couldn't load
/// tours" instead of one slightly-degraded passenger.
///
/// Typed Postgres columns make most of these unreachable today. JSONB does
/// NOT: Postgres type-checks nothing inside a `jsonb` value, so
/// `assigned_seats = '[null]'` or `'[{"busId": 1}]'` is perfectly valid in the
/// database right now and reaches the parser as-is. A fuzz sweep over the
/// passengers row found 3221 distinct inputs that threw
/// (test/fuzz/passenger_malformed_value_fuzz_test.dart).
///
/// The rule these encode: a value we cannot make sense of degrades to null or
/// a documented default. It never throws.
library;

/// Coerces [v] to a `String?`.
///
/// Scalars stringify (an int id is still a usable id). Collections do not —
/// a Map or List where a scalar belongs is nonsense, not data, so it becomes
/// null rather than the literal text "{}" leaking into the UI.
String? coerceString(dynamic v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null; // Map, List, anything else
}

/// Coerces [v] to a `bool`, falling back to [orElse].
///
/// Accepts real bools, the strings 'true'/'false' (any case), and 1/0 —
/// the three shapes a boolean realistically arrives in from JSON, a CSV
/// import, or an older client.
bool coerceBool(dynamic v, {bool orElse = false}) {
  if (v is bool) return v;
  if (v is num) {
    if (v == 1) return true;
    if (v == 0) return false;
    return orElse;
  }
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
  }
  return orElse;
}

/// Coerces [v] to an `int`, falling back to [orElse].
int coerceInt(dynamic v, {int orElse = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? orElse;
  return orElse;
}

/// The list of JSON objects at [v], with anything that isn't a map dropped.
///
/// Guards the JSONB array columns (`assigned_seats`, `request_lines`). A
/// `[null]` or `['a string']` element yields a shorter list rather than an
/// exception — losing one unparseable seat is survivable, losing the roster
/// is not.
List<Map<String, dynamic>> coerceMapList(dynamic v) {
  if (v is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in v) {
    if (e is Map) {
      out.add(Map<String, dynamic>.from(e));
    }
  }
  return out;
}
