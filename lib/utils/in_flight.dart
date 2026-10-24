import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';

/// One-at-a-time guard for side-effecting taps.
///
/// On a 2G link a write or a WhatsApp send can take several seconds, and the
/// agent — seeing nothing happen — taps again. Every second tap used to run the
/// whole action a second time: two confirmation messages to the same rider, a
/// UPI claim posted twice, a tour completed twice. [run] drops a call while an
/// earlier call with the same [key] is still running.
///
/// Keyed and global rather than a `_busy` field, because many of these actions
/// live on const helper classes, extensions or `StatelessWidget`s that have no
/// state to hold a flag — and a row that rebuilds (or a sheet that reopens)
/// mid-write must still see the first tap as in flight. Keys name the action
/// AND its subject (`'upi-confirm:<claimId>'`), so two different riders are
/// never blocked by each other.
abstract final class InFlight {
  static final RxSet<String> _keys = <String>{}.obs;

  /// Whether an action under [key] is running. Reactive inside an `Obx`, so a
  /// button can show its loading state for exactly as long as the write lasts.
  static bool isBusy(String key) => _keys.contains(key);

  /// Runs [body] unless [key] is already in flight, in which case it returns
  /// null at once without running anything. The key is released when [body]
  /// completes, throws or is abandoned — never left latched.
  static Future<T?> run<T>(String key, Future<T> Function() body) async {
    if (_keys.contains(key)) return null;
    _keys.add(key);
    try {
      return await body();
    } finally {
      _keys.remove(key);
    }
  }

  /// Clears every key — a test that leaves an action pending must not leak
  /// its "busy" into the next test.
  @visibleForTesting
  static void reset() => _keys.clear();
}
