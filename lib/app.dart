import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'design/theme.dart';
import 'routes/app_routes.dart';
import 'controllers/tour_controller.dart';
import 'controllers/theme_controller.dart';
import 'controllers/auth_controller.dart';
import 'controllers/locale_controller.dart';
import 'controllers/user_controller.dart';
import 'screens/main_shell.dart';
import 'services/realtime_service.dart';
import 'services/sync_service.dart';
import 'services/user_service.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeCtrl = Get.put<ThemeController>(ThemeController(), permanent: true);

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
      );
    });
  }
}

class AppBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<LocaleController>(LocaleController(), permanent: true);
    Get.put<SyncService>(SyncService(), permanent: true);
    // RealtimeService must come before TourController — the latter calls
    // Get.find<RealtimeService>() in its onInit to subscribe to live events.
    Get.put<RealtimeService>(RealtimeService(), permanent: true);
    Get.put<AuthController>(AuthController(), permanent: true);
    Get.lazyPut<UserService>(() => UserService(), fenix: true);
    Get.put<UserController>(UserController(), permanent: true);
    Get.lazyPut<ShellController>(() => ShellController(), fenix: true);
    Get.lazyPut<TourController>(() => TourController(), fenix: true);
  }
}
