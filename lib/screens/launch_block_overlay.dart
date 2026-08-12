import 'dart:io' show Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/ugam_logo.dart';
import '../design/ugam.dart';
import '../services/remote_flags_service.dart';
import '../utils/app_snackbar.dart';

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
                // A maintenance block used to be a pure dead end: no control
                // of any kind, so the only way out was to guess when to force-
                // quit and relaunch. The flags are re-read on demand here and
                // the block lifts the instant the document says so — the Obx
                // above already rebuilds without a restart.
                //
                // Returns whether the user is STILL blocked, so the button can
                // say "still down" rather than looking dead. Asking the widget
                // to infer that from its own `mounted` flag would race the
                // Obx rebuild.
                onCheckAgain: () async {
                  await flags.refreshNow();
                  return flags.decide() == LaunchDecision.maintenance;
                },
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

/// Opens the store listing for this app.
///
/// A refusal used to be swallowed in silence, which on a HARD block is the
/// worst possible outcome: the one control on an otherwise dead screen appears
/// to do nothing, and the user has no way to tell a broken button from a
/// missing store app. Failure now says so, and says what to search for.
Future<void> openStoreListing() async {
  final uri = Uri.parse(
    Platform.isIOS
        ? 'https://apps.apple.com/app/id6773817469'
        : 'https://play.google.com/store/apps/details?id=com.occubitsolution.ugambooking',
  );
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No store app, no browser, or the launch was refused.
    opened = false;
  }
  if (!opened) {
    AppSnackBar.error(
      tr('launch_block.store_unavailable_body'),
      title: tr('launch_block.store_unavailable_title'),
    );
  }
}

class _BlockScreen extends StatelessWidget {
  final String title;
  final String body;
  final String? actionLabel;

  /// Re-checks the remote flags. Resolves to `true` when the block is still in
  /// force. Null on the update gate, where re-checking cannot help — the build
  /// number is not going to change without a store trip.
  final Future<bool> Function()? onCheckAgain;

  const _BlockScreen({
    required this.title,
    required this.body,
    required this.actionLabel,
    this.onCheckAgain,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final checkAgain = onCheckAgain;
    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
            child: ConstrainedBox(
              // Keeps the copy at a readable measure on a tablet instead of
              // letting one sentence run the full width of a 10" screen.
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Decorative -> px(), never tap(). This was a hard 72 while
                  // the wordmark beneath it shrank with the device.
                  UgamLogo(size: UgamScale.px(context, 72)),
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
                    // Full width, like every other primary in the app. Left to
                    // hug its label inside a min-size Column it read as a
                    // floating pill rather than the screen's one action.
                    SizedBox(
                      width: double.infinity,
                      child: UgamCTA(
                        label: actionLabel!,
                        leadingIcon: Icons.system_update_rounded,
                        onPressed: openStoreListing,
                      ),
                    ),
                  ],
                  if (checkAgain != null) ...[
                    const SizedBox(height: UgamSpacing.xl),
                    SizedBox(
                      width: double.infinity,
                      child: _CheckAgainButton(onCheckAgain: checkAgain),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Check again" on the maintenance block, with its own in-flight state.
///
/// Lifting the block is the success case and needs no message — the overlay
/// simply disappears. Still being blocked is the case that needs one, or the
/// button reads as broken.
class _CheckAgainButton extends StatefulWidget {
  final Future<bool> Function() onCheckAgain;

  const _CheckAgainButton({required this.onCheckAgain});

  @override
  State<_CheckAgainButton> createState() => _CheckAgainButtonState();
}

class _CheckAgainButtonState extends State<_CheckAgainButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    bool stillBlocked;
    try {
      stillBlocked = await widget.onCheckAgain();
    } catch (_) {
      // Offline, DNS failure, bad document — the service keeps last-known-good
      // and we are, by definition, still blocked.
      stillBlocked = true;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (stillBlocked) AppSnackBar.info(tr('launch_block.still_down'));
  }

  @override
  Widget build(BuildContext context) => UgamCTA(
        label: tr('launch_block.check_again'),
        leadingIcon: Icons.refresh_rounded,
        loading: _busy,
        onPressed: _run,
      );
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
            // Container-then-Material rather than a coloured Material: the
            // strip floats above the whole app and had no shadow at all, so it
            // sat at the same optical height as the cards behind it.
            child: Container(
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.card),
                border: Border.all(color: c.border),
                boxShadow: UgamElevation.of(context).raised,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.lg,
                    UgamSpacing.md,
                    UgamSpacing.tight,
                    UgamSpacing.md,
                  ),
                  // Two rows, not one.
                  //
                  // It was `Expanded(Text) + TextButton + IconButton` — a Row
                  // whose two trailing children take their natural width first
                  // and leave the message whatever is left. In Gujarati
                  // ("અપડેટ કરો" / "નવું વર્ઝન આવ્યું છે") at the 1.3x text
                  // scale app.dart permits, that is ~195pt of chrome against a
                  // 347pt strip, squeezing the sentence into a three-line
                  // sliver. The action now owns its own row and cannot
                  // compete with the copy for width.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                top: UgamSpacing.tight,
                              ),
                              child: Text(
                                tr('launch_block.recommended_title'),
                                style: UgamText.bodyStrong
                                    .copyWith(color: c.ink),
                              ),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.sm),
                          // No `tooltip:` — this overlay sits ABOVE the
                          // Navigator in GetMaterialApp.builder, so there is no
                          // Overlay ancestor for a Tooltip to mount into. The
                          // shared button carries the semantic label, plus the
                          // press feedback and the 44pt box the bare
                          // Material IconButton never gave it.
                          UgamIconButton(
                            icon: Icons.close_rounded,
                            onTap: onDismiss,
                            semanticLabel: tr('launch_block.later_action'),
                          ),
                        ],
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      // Tonal, not solid: an OPTIONAL update must not outrank
                      // whatever primary action the screen underneath is
                      // showing. Was a bare Material TextButton — the only one
                      // on this surface, styled by the ambient theme rather
                      // than by the design system.
                      UgamButton(
                        kind: UgamButtonKind.tonal,
                        label: tr('launch_block.update_action'),
                        icon: Icons.system_update_rounded,
                        expand: true,
                        onPressed: openStoreListing,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
