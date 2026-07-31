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
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

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
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
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
        Future.delayed(const Duration(milliseconds: 450)),
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
    return UgamScaffold(
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Decorative mark -> px(), not tap(): nothing here is tappable,
              // so it may shrink freely with the device instead of towering
              // over a wordmark that textScaler has already shrunk to 0.85x.
              UgamLogo(size: UgamScale.px(context, 140)),
              const SizedBox(height: UgamSpacing.xxl),
              Text(
                tr('splash.brand_name'),
                style: UgamText.display.copyWith(
                  color: c.ink,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: UgamSpacing.md),
              Text(
                tr('splash.tagline'),
                style: UgamText.caption.copyWith(
                  color: c.ink2,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
