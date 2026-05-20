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

    // Hand-off as soon as the brand has visibly resolved. Dropping the
    // 900 ms hold the old splash carried — under the new design the
    // splash is brand-only with no decoration to "appreciate", so the
    // sooner we route the better.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final auth = Get.find<AuthController>();
      if (auth.isLoggedIn.value && auth.isAdmin) {
        Get.offAllNamed('/');
      } else {
        Get.offAllNamed('/customer-home');
      }
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.dark;
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
