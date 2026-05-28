import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../config/i18n_config.dart';
import '../controllers/locale_controller.dart';
import '../design/ugam.dart';

/// Modal bottom-sheet language picker. Opens from the Settings screen.
/// Fully styled under the Ugam Design System, resolving deprecation warnings.
class LanguagePickerSheet extends StatelessWidget {
  const LanguagePickerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return UgamSheet.show<void>(
      context,
      title: tr('language.pick_title'),
      builder: (_) => const LanguagePickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final controller = Get.isRegistered<LocaleController>()
        ? Get.find<LocaleController>()
        : Get.put<LocaleController>(LocaleController(), permanent: true);
    controller.syncWithContext(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final locale in I18nConfig.supportedLocales)
          Obx(() {
            final isActive =
                controller.currentLocale.value.languageCode ==
                locale.languageCode;
            return Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: GestureDetector(
                onTap: () async {
                  await controller.setLocale(context, locale);
                  if (context.mounted) Navigator.of(context).pop();
                },
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.lg,
                    vertical: UgamSpacing.md + 2,
                  ),
                  decoration: BoxDecoration(
                    color: isActive ? c.accentFill : c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
                    border: Border.all(
                      color: isActive ? c.accent : c.border,
                      width: isActive ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          I18nConfig.labelFor(locale),
                          style: UgamText.bodyStrong.copyWith(
                            color: isActive ? c.ink : c.ink2,
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: UgamMotion.tab,
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: isActive ? c.accent : Colors.transparent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isActive ? c.accent : c.border,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: isActive
                            ? Icon(Icons.check_rounded,
                                size: 14, color: c.onAccent)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }
}
