import 'dart:io' show Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/ugam_logo.dart';
import '../design/ugam.dart';
import '../services/remote_flags_service.dart';

/// Wraps the whole app and, when the remote flags say so, covers it.
///
/// WHY AN OVERLAY AND NOT A ROUTE
/// A route-based gate is not a kill switch in this app. Three paths never touch
/// the splash and would walk straight past a `GetPage`:
///   - `PushService.init()` is awaited in main.dart BEFORE the splash mounts,
///     and a cold launch from a notification tap fires
///     `Get.offAllNamed(AppRoutes.home)` from a post-frame callback.
///   - `AuthController.verifyOtp` and `_completeLogin` both do
///     `Get.offAllNamed('/')` after login.
/// Sitting in `GetMaterialApp.builder` puts this above the Navigator, so no
/// amount of `offAllNamed` can escape it. That closes those bypasses
/// structurally rather than by patching each call site.
///
/// It is also inside `GetMaterialApp`, which matters: anything rendered above
/// it cannot call `tr()`, and this app's users are Gujarati-primary
/// (`startLocale` is pinned to `gu`). A blocking screen in the wrong language
/// is barely better than no screen.
///
/// FAIL OPEN
/// The decision comes from cached-or-default state and resolves synchronously.
/// It never waits on a fetch, and every uncertain case resolves to
/// [LaunchDecision.proceed] — see [RemoteFlagsService.decide].
class LaunchBlockOverlay extends StatefulWidget {
  final Widget child;

  const LaunchBlockOverlay({super.key, required this.child});

  @override
  State<LaunchBlockOverlay> createState() => _LaunchBlockOverlayState();
}

class _LaunchBlockOverlayState extends State<LaunchBlockOverlay> {
  /// The soft nudge is dismissible and stays dismissed for the session. The
  /// hard block is not dismissible and ignores this.
  bool _nudgeDismissed = false;

  @override
  Widget build(BuildContext context) {
    // Not registered in tests that never run AppBinding — degrade to showing
    // the app rather than throwing "not found" over the top of it.
    if (!Get.isRegistered<RemoteFlagsService>()) return widget.child;
    final flags = Get.find<RemoteFlagsService>();

    return Obx(() {
      final decision = flags.decide();
      final blocking =
          decision == LaunchDecision.maintenance ||
          decision == LaunchDecision.updateRequired;

      // The app is COVERED, never unmounted. Replacing `child` would tear down
      // the Navigator, and background callers do not know that: PushService
      // fires Get.offAllNamed from a post-frame callback on a notification tap,
      // and AuthController does the same after login. Those must land
      // harmlessly underneath the block, not on a dead navigator.
      return Stack(
        children: [
          AbsorbPointer(absorbing: blocking, child: widget.child),
          if (decision == LaunchDecision.maintenance)
            Positioned.fill(
              child: _BlockScreen(
                title: tr('launch_block.maintenance_title'),
                body: tr('launch_block.maintenance_body'),
                actionLabel: null,
              ),
            ),
          if (decision == LaunchDecision.updateRequired)
            Positioned.fill(
              child: _BlockScreen(
                title: tr('launch_block.update_required_title'),
                body: tr('launch_block.update_required_body'),
                actionLabel: tr('launch_block.update_action'),
              ),
            ),
          if (decision == LaunchDecision.updateRecommended && !_nudgeDismissed)
            _NudgeBanner(
              onDismiss: () => setState(() => _nudgeDismissed = true),
            ),
        ],
      );
    });
  }
}

/// Opens the store listing for this app. Best-effort: a failure leaves the
/// block screen up rather than doing anything clever.
Future<void> openStoreListing() async {
  final uri = Uri.parse(
    Platform.isIOS
        ? 'https://apps.apple.com/app/id6773817469'
        : 'https://play.google.com/store/apps/details?id=com.occubitsolution.ugambooking',
  );
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No store app, no browser, or the launch was refused. Nothing useful to
    // say beyond what is already on screen.
  }
}

class _BlockScreen extends StatelessWidget {
  final String title;
  final String body;
  final String? actionLabel;

  const _BlockScreen({
    required this.title,
    required this.body,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const UgamLogo(size: 72),
                const SizedBox(height: UgamSpacing.xl),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: UgamText.titleL.copyWith(color: c.ink),
                ),
                const SizedBox(height: UgamSpacing.md),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: UgamText.body.copyWith(color: c.ink2),
                ),
                if (actionLabel != null) ...[
                  const SizedBox(height: UgamSpacing.xl),
                  UgamCTA(
                    label: actionLabel!,
                    leadingIcon: Icons.system_update_rounded,
                    onPressed: openStoreListing,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dismissible strip over the live app for the soft nudge. Deliberately not a
/// dialog: an optional update must not interrupt an agent mid-booking.
///
/// Rendered as a positioned sibling of the app inside the overlay's Stack, so
/// it never participates in sizing that Stack.
class _NudgeBanner extends StatelessWidget {
  final VoidCallback onDismiss;

  const _NudgeBanner({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Positioned.fill + Align rather than Positioned(left/right/bottom): the
    // fill guarantees a bounded width for the Row no matter what constraints
    // the overlay's Stack is handed, and the max width keeps the strip from
    // stretching absurdly wide on a tablet. Padding and Align do not absorb
    // hits, so taps outside the strip still reach the app underneath.
    return Positioned.fill(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            0,
            UgamSpacing.gutter,
            MediaQuery.paddingOf(context).bottom + UgamSpacing.lg,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Material(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.card),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.lg,
                  UgamSpacing.md,
                  UgamSpacing.sm,
                  UgamSpacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr('launch_block.recommended_title'),
                        style: UgamText.body.copyWith(color: c.ink),
                      ),
                    ),
                    TextButton(
                      onPressed: openStoreListing,
                      child: Text(tr('launch_block.update_action')),
                    ),
                    // No `tooltip:` — this overlay sits ABOVE the Navigator in
                    // GetMaterialApp.builder, so there is no Overlay ancestor
                    // for a Tooltip to mount into. Semantics carries the label
                    // instead.
                    Semantics(
                      label: tr('launch_block.later_action'),
                      button: true,
                      child: IconButton(
                        onPressed: onDismiss,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: c.ink2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
