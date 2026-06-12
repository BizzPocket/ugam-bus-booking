import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'components/ugam_logo.dart';
import 'config/i18n_config.dart';
import 'config/supabase_config.dart';
import 'design/tokens.dart';
import 'firebase_options.dart';
import 'services/push_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Inter is bundled in pubspec.yaml under `fonts:`. Disable
  // google_fonts' runtime fetch from fonts.gstatic.com so any
  // remaining inline `GoogleFonts.inter(...)` call sites resolve from
  // the bundled file instead of triggering a network round-trip on
  // first paint. Without this, low-end devices on slow networks
  // spend hundreds of ms downloading the font before text settles
  // into its final weight.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Fire-and-forget: locking orientation is not a precondition for the
  // first frame, so we don't await it on the cold-start critical path.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Paint a branded splash on the VERY FIRST frame, then run the heavy
  // async init (EasyLocalization prefs + Supabase, which touches the
  // Android Keystore via secure-storage) behind it. Previously these were
  // awaited before runApp(), so low-end devices stared at the blank OS
  // launch theme for the entire init — now they see the brand instantly
  // and the init overlaps with the user reading it.
  runApp(const _Bootstrap());
}

/// Boots the real app once async init finishes, showing a self-contained
/// branded splash in the meantime. The splash deliberately depends on
/// nothing that init provides (no localization, no GetX, no Supabase) so it
/// can render before any of them are ready.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<void> _init = _bootstrap();

  Future<void> _bootstrap() async {
    // Independent of each other — run concurrently so the cold-start cost is
    // max(localization, supabase, firebase) instead of their sum.
    await Future.wait([
      EasyLocalization.ensureInitialized(),
      Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      ),
      Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    ]);

    // Push wiring (best-effort — must never block or break boot). The FCM token
    // itself is only registered later, for an authenticated admin (see
    // AuthController). Here we just arm the background handler + foreground/tap
    // listeners so a notification tapped from a killed state can deep-link.
    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await PushService.instance.init();
    } catch (_) {
      // Firebase/messaging unavailable (e.g. misconfigured device) — the app
      // runs fine without push; the admin simply won't receive alerts.
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _init,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _BootstrapSplash();
        }
        return EasyLocalization(
          supportedLocales: I18nConfig.supportedLocales,
          path: I18nConfig.assetPath,
          fallbackLocale: I18nConfig.fallbackLocale,
          startLocale: I18nConfig.fallbackLocale,
          useOnlyLangCode: true,
          child: const MyApp(),
        );
      },
    );
  }
}

/// Minimal pre-init splash: brand background + logo, no text (text needs
/// localization, which isn't ready yet). Visually continuous with the real
/// [SplashScreen] that takes over once GetMaterialApp mounts.
class _BootstrapSplash extends StatelessWidget {
  const _BootstrapSplash();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.dark;
    // A bare MaterialApp gives the splash the Directionality + MediaQuery that
    // UgamLogo needs to decode at the right pixel size, without pulling in the
    // full app theme/routing stack.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: c.bg,
        body: const Center(child: UgamLogo(size: 140)),
      ),
    );
  }
}
