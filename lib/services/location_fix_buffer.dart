import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/bus_position.dart';

/// The handler's outbound queue of GPS fixes: an in-memory list mirrored to
/// SharedPreferences after every mutation.
///
/// WHY DISK. A handler drives through dead zones, and Android's battery saver
/// will kill a backgrounded app. An in-memory-only queue would lose the trail
/// in both cases — exactly the situations the trail is most wanted for.
///
/// WHY OLDEST-OUT ON OVERFLOW. This is the opposite of `ErrorReporter`'s
/// newest-out rule, and deliberately so: in a crash cascade the first error is
/// the informative one, but in a position trail the newest fix is the only one
/// that can still move the map. Position data ages into worthlessness.
class LocationFixBuffer {
  LocationFixBuffer({required this.busId, this.maxFixes = 2000});

  final String busId;

  /// ~16 h at one fix per 30 s. Bounds both the disk footprint and the worst
  /// case flush size after a very long offline stretch.
  final int maxFixes;

  final List<LocationFix> _fixes = <LocationFix>[];

  String get _key => 'loc_buffer_$busId';

  int get length => _fixes.length;
  List<LocationFix> get fixes => List.unmodifiable(_fixes);

  Future<void> add(LocationFix fix) async {
    _fixes.add(fix);
    _trim();
    await _persist();
  }

  /// The oldest [n] fixes, WITHOUT removing them. They are removed by [drop]
  /// only once the RPC has returned, so a thrown call leaves the queue intact.
  List<LocationFix> take(int n) =>
      _fixes.take(n < 0 ? 0 : n).toList(growable: false);

  Future<void> drop(int n) async {
    if (n <= 0) return;
    _fixes.removeRange(0, n > _fixes.length ? _fixes.length : n);
    await _persist();
  }

  Future<void> clear() async {
    _fixes.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Losing the mirror is survivable; memory is already clear.
    }
  }

  /// Reloads from disk, replacing whatever is in memory. Call once on start.
  Future<void> rehydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? const <String>[];
      _fixes
        ..clear()
        ..addAll(raw.map(_decode).whereType<LocationFix>());
      _trim();
    } catch (_) {
      _fixes.clear();
    }
  }

  void _trim() {
    if (_fixes.length > maxFixes) {
      _fixes.removeRange(0, _fixes.length - maxFixes);
    }
  }

  /// A single malformed entry must not cost the whole trail — the same
  /// reasoning as 047's poison-pill guard on the server side.
  static LocationFix? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return LocationFix.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _key,
        _fixes.map((f) => jsonEncode(f.toJson())).toList(growable: false),
      );
    } catch (_) {
      // Disk full or prefs unavailable: keep going on memory alone rather
      // than dropping a fix that could still be uploaded this session.
    }
  }
}
