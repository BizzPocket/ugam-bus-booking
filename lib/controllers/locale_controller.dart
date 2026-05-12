import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../config/i18n_config.dart';

/// Wraps `EasyLocalization`'s BuildContext-based API so non-widget code can
/// read and change the current locale through GetX.
///
/// Persistence is handled by easy_localization itself (SharedPreferences).
class LocaleController extends GetxController {
  final currentLocale = I18nConfig.fallbackLocale.obs;

  /// Pulls the active locale from the [BuildContext] the picker passes in,
  /// then mirrors any subsequent change back into [currentLocale].
  void syncWithContext(BuildContext context) {
    currentLocale.value = context.locale;
  }

  /// Switch the app locale. Must be called with a live BuildContext so
  /// easy_localization can rebuild the tree and persist the choice.
  ///
  /// We push the locale change through THREE places on purpose:
  ///   1. `context.setLocale(...)` — easy_localization stores it in
  ///      SharedPreferences and rebuilds anything that reads
  ///      `context.locale` / uses `tr(...)`.
  ///   2. `Get.updateLocale(...)` — `GetMaterialApp` caches its `locale`
  ///      arg; without this call the Material chrome (date pickers,
  ///      tooltips, system widgets) keeps showing the old language until
  ///      the next cold start.
  ///   3. `currentLocale.value = ...` — drives the radio selection in
  ///      the picker sheet.
  Future<void> setLocale(BuildContext context, Locale locale) async {
    await context.setLocale(locale);
    Get.updateLocale(locale);
    currentLocale.value = locale;
  }
}
