import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../controllers/auth_controller.dart';
import '../design/ugam.dart';

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
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

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
    await Future.wait([
      auth.whenRestored,
      Future.delayed(const Duration(milliseconds: 450)),
    ]);
    if (!mounted) return;
    if (auth.isLoggedIn.value && auth.isAdmin) {
      Get.offAllNamed('/');
    } else {
      Get.offAllNamed('/customer-home');
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
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const UgamLogo(size: 140),
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
