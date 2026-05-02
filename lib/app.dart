import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'config/theme.dart';
import 'routes/app_routes.dart';
import 'screens/main_shell.dart';
import 'controllers/tour_controller.dart';
import 'controllers/theme_controller.dart';
import 'controllers/auth_controller.dart';
import 'controllers/bus_controller.dart';
// search_controller.dart is no longer registered here — SearchScreen uses TourController directly
import 'services/sync_service.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Ugam Booking',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,  // ThemeController handles runtime changes via Get.changeThemeMode()
      initialRoute: AppRoutes.splash,
      getPages: AppRoutes.routes,
      initialBinding: AppBinding(),
    );
  }
}

class AppBinding extends Bindings {
  @override
  void dependencies() {
    // Core services — initialize first
    Get.put<SyncService>(SyncService(), permanent: true);

    // Auth controller (global — permanent so it is never disposed mid-navigation)
    Get.put<AuthController>(AuthController(), permanent: true);

    // Shell controller
    Get.lazyPut<ShellController>(() => ShellController(), fenix: true);

    // Controllers
    Get.lazyPut<TourController>(() => TourController(), fenix: true);
    Get.lazyPut<ThemeController>(() => ThemeController(), fenix: true);
    Get.lazyPut<BusController>(() => BusController(), fenix: true);
    // AppSearchController removed — SearchScreen uses TourController directly
  }
}
