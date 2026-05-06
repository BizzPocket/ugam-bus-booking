import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'config/theme.dart';
import 'routes/app_routes.dart';
import 'controllers/tour_controller.dart';
import 'controllers/theme_controller.dart';
import 'controllers/auth_controller.dart';
import 'screens/main_shell.dart';
import 'services/sync_service.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeCtrl = Get.put<ThemeController>(ThemeController(), permanent: true);

    return Obx(() {
      return GetMaterialApp(
        title: 'Ugam Booking',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeCtrl.isDarkMode.value ? ThemeMode.dark : ThemeMode.light,
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
    Get.put<SyncService>(SyncService(), permanent: true);
    Get.put<AuthController>(AuthController(), permanent: true);
    Get.lazyPut<ShellController>(() => ShellController(), fenix: true);
    Get.lazyPut<TourController>(() => TourController(), fenix: true);
  }
}
