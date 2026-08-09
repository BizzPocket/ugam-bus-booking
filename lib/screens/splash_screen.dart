import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../routes/app_routes.dart';
import '../utils/app_snackbar.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;

  // "Dawn bloom" entrance, choreographed on ONE controller (the same
  // single-ticker pattern this screen already used — just staged instead of a
  // single flat fade). `ઉગમ` means *rising / dawn*, so the amber cabin-lamp
  // glow blooms behind the mark like a sunrise, then the logo settles, then
  // the wordmark and tagline rise in. Each stage is an Interval slice of the
  // controller's 0→1 progress.
  late final Animation<double> _glow;
  late final Animation<double> _logo;
  late final Animation<double> _word;
  late final Animation<double> _tag;

  Animation<double> _stage(double begin, double end) => CurvedAnimation(
        parent: _animController,
        curve: Interval(begin, end, curve: UgamMotion.easeOut),
      );

  @override
  void initState() {
    super.initState();
    // NO imperative SystemUiOverlayStyle here. `app.dart` installs a
    // theme-aware AnnotatedRegion app-wide (light glyphs on dark, dark glyphs
    // on light); hard-pinning `.light` made the clock/battery/signal invisible
    // on the cream light theme. `main_shell.dart` had this exact call removed
    // for the same reason.
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _glow = _stage(0.0, 0.60); // sunrise halo blooms first
    _logo = _stage(0.10, 0.62); // mark fades + settles into the glow
    _word = _stage(0.40, 0.80); // wordmark rises
    _tag = _stage(0.62, 1.0); // tagline rises last
    _animController.forward();

    _routeWhenReady();
  }

  /// Route only AFTER the persisted session has actually been restored, not
  /// after an arbitrary timer. We still hold the brand on screen for a short
  /// minimum so the splash doesn't flash by, but the routing DECISION waits on
  /// real auth state — so a logged-in admin always lands on the admin home and
  /// a customer always lands on the customer home, deterministically.
  Future<void> _routeWhenReady() async {
    final auth = Get.find<AuthController>();
    var restoreTimedOut = false;
    try {
      await Future.wait([
        // Bound the session-restore read. On a stalled network the underlying
        // admin lookup can hang WITHOUT throwing, so `whenRestored` would never
        // complete and the user would stare at the splash forever. Time it out
        // and route on whatever auth state we already have (an admin's
        // isLoggedIn/isAdmin are set before that network hop, so a logged-in
        // admin still lands on the admin home; the tour list re-fetches once
        // online). A finite fall-through always beats an infinite spinner.
        auth.whenRestored.timeout(const Duration(seconds: 10)),
        // Minimum hold. Raised from 450ms so the dawn-bloom entrance (900ms)
        // completes before we route — otherwise a returning admin, whose
        // session restores instantly, would see the animation cut a third of
        // the way in. Routing STILL keys on real auth state via the wait
        // above; only the visual floor moved.
        Future.delayed(const Duration(milliseconds: 950)),
      ]);
    } on TimeoutException {
      restoreTimedOut = true;
    }
    if (!mounted) return;
    if (auth.isLoggedIn.value && auth.isAdmin) {
      Get.offAllNamed(AppRoutes.home);
    } else {
      Get.offAllNamed(AppRoutes.customerHome);
    }
    // Tell the user why we moved on without a fully confirmed session. The
    // toast lives in the root overlay, so it survives the route change and
    // lands on the destination screen rather than the torn-down splash.
    if (restoreTimedOut) {
      AppSnackBar.warning(
        tr('splash.restore_timeout_message'),
        title: tr('splash.restore_timeout_title'),
      );
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Decorative brand block -> px(), never tap(): nothing here is tappable, so
    // it may shrink freely with the device instead of towering over a wordmark
    // textScaler has already shrunk to 0.85x.
    final logoSize = UgamScale.px(context, 140);
    final haloSize = UgamScale.px(context, 300);
    return UgamScaffold(
      body: Center(
        child: AnimatedBuilder(
          animation: _animController,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo on the rising amber halo — the design system's signature
                // "copper glow behind a hero figure" (see login_screen), here
                // bloomed like a sunrise. The layout box hugs the logo; the far
                // larger glow overflows it (Clip.none) so scaling the halo only
                // repaints and never reflows the wordmark below.
                SizedBox(
                  width: logoSize,
                  height: logoSize,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Opacity(
                        opacity: _glow.value,
                        child: Transform.scale(
                          scale: 0.55 + 0.45 * _glow.value,
                          child: Container(
                            width: haloSize,
                            height: haloSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [c.glow, c.glow.withValues(alpha: 0)],
                                stops: const [0.0, 0.7],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: _logo.value,
                        child: Transform.scale(
                          scale: 0.90 + 0.10 * _logo.value,
                          child: UgamLogo(size: logoSize),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: UgamSpacing.xxl),
                Opacity(
                  opacity: _word.value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - _word.value) * 12),
                    child: Text(
                      tr('splash.brand_name'),
                      style: UgamText.display.copyWith(
                        color: c.ink,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: UgamSpacing.md),
                Opacity(
                  opacity: _tag.value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - _tag.value) * 10),
                    child: Text(
                      tr('splash.tagline'),
                      style: UgamText.caption.copyWith(
                        color: c.ink2,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
