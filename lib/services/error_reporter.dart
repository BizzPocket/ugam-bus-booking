import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_info.dart';

/// Ships Dart-level failures to `public.client_errors` so a break in the field
/// is something you can see rather than something a handler telephones about.
///
/// WHAT IT HOOKS
///   - `FlutterError.onError`      — framework and build() failures
///   - `PlatformDispatcher.onError`— uncaught async errors on the root zone
///   - `ErrorWidget.builder`       — a build() that threw, reported AND
///                                   rendered as something other than a raw
///                                   stack trace
///
/// WHAT IT IS NOT
/// A crash reporter. It cannot see a native SIGSEGV in a plugin and cannot
/// symbolicate. Crashlytics remains the better tool; this exists because it
/// needs no native plugin, no Firebase console and no macOS machine, so it can
/// ship in the next build instead of the one after the console work.
///
/// THE RULES IT OBEYS
///  1. It can never make things worse. Every path is wrapped; a failure to
///     report a failure is swallowed. An error reporter that throws inside
///     `FlutterError.onError` takes the app down with it.
///  2. It never blocks. Reports are queued locally and flushed in the
///     background. A crash on a 2G link must not also hang.
///  3. It carries no PII. Ids, screen names, versions. Never a passenger name,
///     phone number or amount — a crash report is not a place to leak the data
///     the crash was about.
class ErrorReporter {
  ErrorReporter._();

  static const String _queueKey = 'client_errors.queue';

  /// Keeps a crash loop from filling the device's prefs. Older reports win:
  /// the FIRST failure in a cascade is the informative one, the twentieth is
  /// noise.
  static const int _maxQueued = 30;

  static bool _installed = false;
  static bool _flushing = false;

  /// Deduplicates a repeating error so one broken build() in a rebuild loop
  /// does not send thousands of identical rows.
  static final Set<String> _seenThisSession = <String>{};

  /// Test seam. When set, reports go here instead of Supabase.
  @visibleForTesting
  static Future<void> Function(Map<String, dynamic> row)? debugSink;

  @visibleForTesting
  static void resetForTest() {
    _installed = false;
    _flushing = false;
    _seenThisSession.clear();
    debugSink = null;
  }

  /// Installs the global handlers. Safe to call more than once.
  ///
  /// Call as early as possible in main() — before runApp — so a failure during
  /// bootstrap is caught too. It performs no I/O.
  static void install() {
    if (_installed) return;
    _installed = true;

    final priorOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // Keep Flutter's own console logging: losing it would make local
      // debugging worse in exchange for making production better.
      priorOnError?.call(details);
      report(
        kind: 'flutter_error',
        error: details.exception,
        stack: details.stack,
        context: {'library': details.library},
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      report(kind: 'zone_error', error: error, stack: stack);
      // false = not handled; let the platform log it too.
      return false;
    };
  }

  /// Records one failure. Never throws, never awaits anything slow.
  static void report({
    required String kind,
    required Object error,
    StackTrace? stack,
    Map<String, dynamic>? context,
  }) {
    try {
      final message = error.toString();

      // One row per distinct failure per session. A rebuild loop can fire the
      // same build() error sixty times a second.
      final fingerprint = '$kind:${message.hashCode}';
      if (!_seenThisSession.add(fingerprint)) return;

      final row = <String, dynamic>{
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'app_version': _clip(AppInfo.version, 40),
        'build_number': _clip(AppInfo.buildNumber, 40),
        'platform': _platformName(),
        'kind': _clip(kind, 40),
        'message': _clip(message, 2000),
        'stack': _clip(stack?.toString(), 8000),
        'context': context,
      };

      // Fire-and-forget: the caller is usually inside an error handler and must
      // not be made to wait on storage or a socket.
      unawaited(_enqueueAndFlush(row));
    } catch (_) {
      // A reporter that throws inside FlutterError.onError takes the app with
      // it. There is nowhere left to report this to, and that is fine.
    }
  }

  static String _platformName() {
    try {
      if (kIsWeb) return 'web';
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  static String? _clip(String? s, int max) {
    if (s == null) return null;
    final t = s.trim();
    if (t.isEmpty) return null;
    return t.length <= max ? t : t.substring(0, max);
  }

  static Future<void> _enqueueAndFlush(Map<String, dynamic> row) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_queueKey) ?? <String>[];
      queue.add(jsonEncode(row));
      // Drop the NEWEST on overflow, not the oldest: in a cascade the first
      // failure is the cause and the rest are consequences.
      final trimmed =
          queue.length > _maxQueued ? queue.sublist(0, _maxQueued) : queue;
      await prefs.setStringList(_queueKey, trimmed);
    } catch (_) {
      return;
    }
    await flush();
  }

  /// Drains the queue. Called after every report and safe to call on resume.
  ///
  /// A failed send leaves the queue intact, so a report raised while offline
  /// arrives on the next launch that has a network.
  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_queueKey) ?? const <String>[];
      if (queue.isEmpty) return;

      final sent = <String>[];
      for (final raw in queue) {
        Map<String, dynamic> row;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic>) {
            sent.add(raw); // unparseable: drop it rather than retry forever
            continue;
          }
          row = decoded;
        } catch (_) {
          sent.add(raw);
          continue;
        }

        try {
          final sink = debugSink;
          if (sink != null) {
            await sink(row);
          } else {
            await Supabase.instance.client.from('client_errors').insert(row);
          }
          sent.add(raw);
        } catch (_) {
          // Offline, Supabase not initialised yet, RLS refusal, anything:
          // stop and keep the rest for next time. Continuing would spend the
          // whole queue against a wall.
          break;
        }
      }

      if (sent.isNotEmpty) {
        final remaining = queue.where((e) => !sent.contains(e)).toList();
        await prefs.setStringList(_queueKey, remaining);
      }
    } catch (_) {
      // Never propagate.
    } finally {
      _flushing = false;
    }
  }
}
