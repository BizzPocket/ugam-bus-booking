import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'design/theme.dart';
import 'design/tokens.dart';
import 'design/ui_scale.dart';
import 'routes/app_routes.dart';
import 'controllers/tour_controller.dart';
import 'controllers/money_controller.dart';
import 'controllers/finance_controller.dart';
import 'controllers/pickup_controller.dart';
import 'controllers/inbox_controller.dart';
import 'controllers/theme_controller.dart';
import 'controllers/auth_controller.dart';
import 'controllers/locale_controller.dart';
import 'controllers/user_controller.dart';
import 'controllers/customer_memory_controller.dart';
import 'screens/launch_block_overlay.dart';
import 'screens/main_shell.dart';
import 'services/location_tracker_service.dart';
import 'services/realtime_service.dart';
import 'services/remote_content_service.dart';
import 'services/remote_flags_service.dart';
import 'services/sync_service.dart';
import 'services/user_service.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeCtrl = Get.put<ThemeController>(
      ThemeController(),
      permanent: true,
    );

    return Obx(() {
      return GetMaterialApp(
        title: 'Ugam Booking',
        debugShowCheckedModeBanner: false,
        theme: UgamTheme.light(),
        darkTheme: UgamTheme.dark(),
        themeMode: themeCtrl.themeMode.value,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        initialRoute: AppRoutes.splash,
        getPages: AppRoutes.routes,
        initialBinding: AppBinding(),
        defaultTransition: Transition.fadeIn,
        transitionDuration: UgamMotion.route,
        // App-wide, theme-aware system chrome. This is the ONE place the OS
        // status/navigation bars are styled — the builder sits under the
        // MaterialApp's resolved Theme, so `Theme.of` gives the live brightness
        // and this re-runs on every theme toggle AND "System" brightness flip.
        // Every screen (admin + customer + pushed) inherits it because none of
        // them use a Material AppBar to set their own overlay.
        //
        // NOTE on enforced edge-to-edge (Android 15+, unavoidable at targetSdk
        // 36): the engine gates `systemNavigationBarColor` and
        // `systemNavigationBarDividerColor` behind device SDK_INT < 35, so on
        // Android 15+ they are no-ops — the nav-bar ground is whatever the app
        // paints there, plus the OS contrast scrim. They are kept because the
        // gate is on the DEVICE version, not targetSdk, and Android 7–14 is
        // still most of the install base. The *IconBrightness fields and
        // statusBarColor continue to apply on every version. If a solid
        // nav-bar ground is ever wanted on 15+, paint it in Dart behind
        // MediaQuery.viewPaddingOf(context).bottom.
        builder: (context, child) {
          final c = UgamColors.of(context);
          final isDark = Theme.of(context).brightness == Brightness.dark;
          // App-wide responsive text scaling. One override here scales every
          // label/title/number on every screen (admin + customer + pushed) with
          // the device — smaller phones shrink toward the tuned baseline instead
          // of reading oversized. The user's accessibility font preference is
          // honoured but capped at 1.3× so large settings can't overflow layouts.
          final mq = MediaQuery.of(context);
          final ui = UgamScale.of(context);
          final userFactor = mq.textScaler.scale(1.0).clamp(0.9, 1.3);
          final overlay = SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            // Icons must contrast the ground: light glyphs on the dark theme,
            // dark glyphs on the light theme. (This is the exact bug the old
            // hardcoded `SystemUiOverlayStyle.dark` got backwards.)
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: c.bg,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarDividerColor: Colors.transparent,
          );
          return MediaQuery(
            data: mq.copyWith(
              textScaler: TextScaler.linear(userFactor * ui),
            ),
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: overlay,
              // Above the Navigator, so no Get.offAllNamed — from a push deep
              // link or a post-login redirect — can slip past the block.
              child: LaunchBlockOverlay(
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          );
        },
      );
    });
  }
}

class AppBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<LocaleController>(LocaleController(), permanent: true);
    // Registered before everything else and warmed fire-and-forget: the launch
    // gate reads it from cached-or-default state, so no caller ever waits on a
    // network round trip. Deliberately NOT reusing SyncService — its cellular
    // read gate would queue this behind the tour load with a 28s timeout.
    Get.put<RemoteFlagsService>(RemoteFlagsService(), permanent: true)
        .warm()
        .ignore();
    // Server-driven content for the customer surface's content slot. Same
    // fire-and-forget discipline: it reads its cache immediately and refreshes
    // behind the app. Dormant unless REMOTE_CONTENT_URL is compiled in.
    Get.put<RemoteContentService>(RemoteContentService(), permanent: true)
        .warm()
        .ignore();
    Get.put<SyncService>(SyncService(), permanent: true);
    // RealtimeService must come before TourController — the latter calls
    // Get.find<RealtimeService>() in its onInit to subscribe to live events.
    Get.put<RealtimeService>(RealtimeService(), permanent: true);
    Get.put<AuthController>(AuthController(), permanent: true);
    Get.lazyPut<UserService>(() => UserService(), fenix: true);
    Get.put<UserController>(UserController(), permanent: true);
    Get.put<CustomerMemoryController>(
      CustomerMemoryController(),
      permanent: true,
    );
    // Handler live-location tracking. Permanent because sharing outlives the
    // bus-chart screen: a handler who backs out or pockets the phone must keep
    // reporting for the rest of the trip.
    Get.put<LocationTrackerService>(LocationTrackerService(), permanent: true);
    Get.lazyPut<ShellController>(() => ShellController(), fenix: true);
    Get.lazyPut<TourController>(() => TourController(), fenix: true);
    Get.lazyPut<MoneyController>(() => MoneyController(), fenix: true);
    Get.lazyPut<FinanceController>(() => FinanceController(), fenix: true);
    Get.lazyPut<PickupController>(() => PickupController(), fenix: true);
    // Admin-only WhatsApp inbox. Lazy + fenix: it only instantiates (and starts
    // its realtime subscription) once an admin surface first reads it — the
    // Dashboard unread badge / the Inbox screen — so a logged-out or customer
    // session never subscribes.
    Get.lazyPut<InboxController>(() => InboxController(), fenix: true);
  }
}
