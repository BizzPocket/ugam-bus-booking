import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';

/// Imperative toast API. The public surface (`success`, `error`, `info`,
/// `warning`) is unchanged, so every existing call site across the app keeps
/// working untouched.
///
/// Rendering, however, no longer goes through `ScaffoldMessenger`. A root
/// `ScaffoldMessenger` floating snackbar is positioned relative to whichever
/// `Scaffold` happens to be front-most and silently lifts itself above that
/// scaffold's `bottomNavigationBar` — which, combined with a second manual
/// lift, pushed the toast a third of the way up the screen. The app's real
/// screens also live inside nested per-tab navigators that the root chrome
/// observer could never see, so the height it fed back was wrong everywhere.
///
/// Instead we render a single toast directly in the **root [Overlay]** at a
/// fixed, predictable spot just above the floating dock (or the keyboard, when
/// it's open). The overlay measures from the true screen edges, so there is no
/// `bottomNavigationBar` double-count and no dependency on the navigation
/// stack — the toast lands in the same place on every screen.
///
/// `warning` is intentionally aliased to `error` — the design system merged
/// the two tones under a single attention treatment, since the two were
/// visually indistinguishable to users in practice.
class AppSnackBar {
  AppSnackBar._();

  /// The single live toast. Reused while visible so rapid-fire calls swap the
  /// message in place instead of stacking a pile of overlays.
  static OverlayEntry? _entry;
  static final GlobalKey<_ToastHostState> _hostKey =
      GlobalKey<_ToastHostState>();

  static void _show({
    required String message,
    String? title,
    required UgamSnackTone tone,
    Duration duration = const Duration(seconds: 3),
  }) {
    final context = Get.overlayContext ?? Get.context;
    if (context == null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    HapticFeedback.lightImpact();
    if (tone == UgamSnackTone.error) HapticFeedback.mediumImpact();

    final msg = _ToastMsg(
      message: message,
      title: title,
      tone: tone,
      duration: duration,
    );

    // A toast is already on screen → hand it the new content and let it reset
    // its own timer/animation rather than tearing down and rebuilding.
    final live = _hostKey.currentState;
    if (_entry != null && live != null) {
      live.replace(msg);
      return;
    }

    final entry = OverlayEntry(
      builder: (_) => _ToastHost(
        key: _hostKey,
        initial: msg,
        onClosed: () {
          _entry?.remove();
          _entry = null;
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void success(String message, {String? title}) =>
      _show(title: title, message: message, tone: UgamSnackTone.success);

  static void error(String message, {String? title}) => _show(
    title: title,
    message: message,
    tone: UgamSnackTone.error,
    duration: const Duration(seconds: 4),
  );

  /// Aliased to error — same visual treatment in the new design system.
  static void warning(String message, {String? title}) =>
      error(message, title: title);

  static void info(String message, {String? title}) =>
      _show(title: title, message: message, tone: UgamSnackTone.info);
}

/// Immutable payload for one toast appearance.
class _ToastMsg {
  final String message;
  final String? title;
  final UgamSnackTone tone;
  final Duration duration;

  const _ToastMsg({
    required this.message,
    this.title,
    required this.tone,
    required this.duration,
  });
}

/// The overlay-resident toast. Owns its slide/fade animation and auto-dismiss
/// timer, positions itself above the dock / keyboard, and supports
/// tap-to-dismiss and horizontal swipe-to-dismiss.
class _ToastHost extends StatefulWidget {
  final _ToastMsg initial;
  final VoidCallback onClosed;

  const _ToastHost({super.key, required this.initial, required this.onClosed});

  @override
  State<_ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<_ToastHost>
    with SingleTickerProviderStateMixin {
  /// Height the floating dock occupies above the bottom safe area: its lateral
  /// padding (lg top + md bottom) plus the 52px capsule. The dock is the same
  /// height wherever it appears, so a constant clears it on every screen; on a
  /// rare dockless screen the toast simply rests a little higher — never in the
  /// middle. Kept in sync with [UgamDockNav].
  static const double _dockClearance = UgamSpacing.lg + 52 + UgamSpacing.md;

  late final AnimationController _ctrl;
  late _ToastMsg _msg;
  Timer? _timer;
  bool _closing = false;
  // Bumped on each replace() so the Dismissible resets cleanly between messages.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _msg = widget.initial;
    _ctrl = AnimationController(vsync: this, duration: UgamMotion.sheet);
    _ctrl.forward();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(_msg.duration, _close);
  }

  /// Swap in a new message without tearing the overlay down. Re-shows if it was
  /// mid-dismiss and restarts the auto-dismiss timer.
  void replace(_ToastMsg msg) {
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _msg = msg;
      _closing = false;
      _seq++;
    });
    _ctrl.forward();
    _arm();
  }

  Future<void> _close() async {
    if (_closing || !mounted) return;
    _closing = true;
    _timer?.cancel();
    await _ctrl.reverse();
    // A replace() during the exit animation flips _closing back to false and
    // re-shows the toast; in that case this in-flight close must NOT tear it
    // down. Only finalize if we're still the active close.
    if (_closing && mounted) widget.onClosed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Above the keyboard when it's up, otherwise above the dock. Either way a
    // small gap keeps the card off the chrome below it.
    final keyboard = mq.viewInsets.bottom;
    final bottom =
        (keyboard > 0 ? keyboard : mq.padding.bottom + _dockClearance) +
        UgamSpacing.md;

    final curve = CurvedAnimation(
      parent: _ctrl,
      curve: UgamMotion.easeOut,
      reverseCurve: UgamMotion.easeIn,
    );

    return Positioned(
      left: UgamSpacing.gutter,
      right: UgamSpacing.gutter,
      bottom: bottom,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.35),
            end: Offset.zero,
          ).animate(curve),
          child: Dismissible(
            key: ValueKey<int>(_seq),
            direction: DismissDirection.horizontal,
            onDismissed: (_) => widget.onClosed(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: UgamSnackbar(
                message: _msg.message,
                title: _msg.title,
                tone: _msg.tone,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
