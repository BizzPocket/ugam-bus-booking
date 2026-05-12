import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../config/i18n_config.dart';
import '../controllers/locale_controller.dart';

/// Modal bottom-sheet language picker. Opens from the Settings screen.
class LanguagePickerSheet extends StatelessWidget {
  const LanguagePickerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const LanguagePickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.isRegistered<LocaleController>()
        ? Get.find<LocaleController>()
        : Get.put<LocaleController>(LocaleController(), permanent: true);
    controller.syncWithContext(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                tr('language.pick_title'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final locale in I18nConfig.supportedLocales)
              Obx(() {
                final isActive =
                    controller.currentLocale.value.languageCode ==
                    locale.languageCode;
                return RadioListTile<String>(
                  value: locale.languageCode,
                  groupValue: controller.currentLocale.value.languageCode,
                  title: Text(I18nConfig.labelFor(locale)),
                  selected: isActive,
                  onChanged: (_) async {
                    await controller.setLocale(context, locale);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                );
              }),
          ],
        ),
      ),
    );
  }
}
