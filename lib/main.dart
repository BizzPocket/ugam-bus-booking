import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/i18n_config.dart';
import 'config/supabase_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await EasyLocalization.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  runApp(
    EasyLocalization(
      supportedLocales: I18nConfig.supportedLocales,
      path: I18nConfig.assetPath,
      fallbackLocale: I18nConfig.fallbackLocale,
      startLocale: I18nConfig.fallbackLocale,
      useOnlyLangCode: true,
      child: const MyApp(),
    ),
  );
}
