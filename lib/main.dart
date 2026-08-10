
// Prefixed because easy_localization re-exports intl's TextDirection (LTR/RTL),
// which shadows dart:ui's TextDirection (ltr/rtl) used by Directionality below.
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'components/ugam_logo.dart';
import 'config/app_info.dart';
import 'config/i18n_config.dart';
import 'config/supabase_config.dart';
import 'design/tokens.dart';
import 'firebase_options.dart';
import 'services/error_reporter.dart';
import 'services/push_service.dart';
import 'services/remote_translation_loader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Load intl's date symbols for EVERY locale up front. Without this, any
  // `DateFormat(pattern, 'gu'|'hi')` throws LocaleDataException — which is
  // what `Formatters.formatDateShort(..., locale: context.locale...)` does on
  // the tours list. The data is compiled into the intl package (no I/O), so
  // the returned Future is already complete and `main()` stays synchronous.
  initializeDateFormatting();

  // Catch Dart failures app-wide and queue them for public.client_errors.
  // Installed before anything else can throw, and performs no I/O itself.
  ErrorReporter.install();

  // Flutter's default ErrorWidget is a light-grey box sized 100000x100000 once
  // asserts are stripped, so a build() that throws in RELEASE reads to the user
  // as a blank screen overflowing off-frame. This replaces it.
  //
  // It used to print the raw exception and stack trace — labelled "DIAGNOSTIC
  // (temporary)" and shipped to users for months. That is a leak (stack traces
  // name internals) and it tells a bus handler nothing. Now the exception goes
  // where it is useful, and the user gets a quiet placeholder.
  //
  // It still SWALLOWS the error rather than rethrowing: this builder exists
  // because a throwing build() used to take the whole app down, and that has
  // not changed. Kept dependency-free — no theme, no localization, no GetX —
  // because it must paint in ANY slot, including one whose ancestors never
  // built.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    ErrorReporter.report(
      kind: 'widget_build',
      error: details.exception,
      stack: details.stack,
      context: {'library': details.library},
    );
    return Directionality(
      textDirection: ui.TextDirection.ltr,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 340),
        padding: const EdgeInsets.all(16),
        color: const Color(0xFF1A1A1A),
        alignment: Alignment.center,
        child: const Text(
          '—',
          style: TextStyle(color: Color(0xFF6B6B6B), fontSize: 20),
        ),
      ),
    );
  };

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
  // Not `final`: a failed init can be retried by re-running _bootstrap() and
  // re-pointing the FutureBuilder at the fresh future (see the error branch).
  late Future<void> _init = _bootstrap();

  Future<void> _bootstrap() async {
    // Independent of each other — run concurrently so the cold-start cost is
    // max(localization, supabase, firebase) instead of their sum.
    await Future.wait([
      EasyLocalization.ensureInitialized(),
      AppInfo.load(),
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
        // Init failed (e.g. Supabase/Firebase unreachable on a bad network).
        // Previously this fell through to build the real app on top of a
        // half-initialized stack — a broken screen with no way out. Show a
        // simple retry surface instead so the user isn't stranded.
        if (snap.hasError) {
          return _BootstrapError(
            onRetry: () => setState(() => _init = _bootstrap()),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return const _BootstrapSplash();
        }
        return EasyLocalization(
          supportedLocales: I18nConfig.supportedLocales,
          path: I18nConfig.assetPath,
          fallbackLocale: I18nConfig.fallbackLocale,
          startLocale: I18nConfig.fallbackLocale,
          useOnlyLangCode: true,
          // Bundled catalogue + a cached remote delta merged over it, so copy
          // fixes ship without a store release. Reads no network and cannot
          // throw; see RemoteTranslationLoader.
          assetLoader: const RemoteTranslationLoader(),
          // MANDATORY alongside a custom loader. EasyLocalization renders
          // `errorWidget ?? ErrorWidget(...)` on a load failure, and
          // ErrorWidget.builder is globally overridden above as a red
          // diagnostic dump — without this, any load failure becomes a
          // full-screen crash-looking page for every user.
          errorWidget: (_) => const _BootstrapSplash(),
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

/// Last-resort screen when cold-start init (Supabase/Firebase/localization)
/// fails. Deliberately dependency-free — no GetX, no app theme, and crucially
/// NO localization: this renders in the FutureBuilder's error branch, before
/// the EasyLocalization ancestor is ever mounted, so `tr()` cannot resolve.
/// The copy is therefore hardcoded English (the app's fallback locale), same
/// no-localization rationale as [_BootstrapSplash]. Offers a single Retry that
/// re-runs [_bootstrap].
class _BootstrapError extends StatelessWidget {
  final VoidCallback onRetry;
  const _BootstrapError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.dark;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const UgamLogo(size: 96),
                  const SizedBox(height: 28),
                  Text(
                    "Couldn't start the app",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Please check your internet connection and try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.ink2, fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 14,
                      ),
                    ),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
