import 'package:easy_localization/easy_localization.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_snackbar.dart';

/// Opens the platform dialer pre-filled with [phone].
///
/// Strips formatting (spaces, dashes, parens) but preserves a leading
/// `+` so international numbers still dial correctly. Indian local
/// numbers (10 digits) work as-is. Returns silently when [phone] is
/// empty; surfaces a snackbar when the OS has no handler for `tel:`
/// (e.g. a tablet with no SIM and no dialer app installed).
class PhoneDialer {
  PhoneDialer._();

  static Future<void> call(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: cleaned);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        AppSnackBar.error(
          tr('errors.dialer_open_failed', namedArgs: {'phone': phone}),
          title: tr('errors.call_failed'),
        );
      }
    } catch (_) {
      AppSnackBar.error(
        tr('errors.dialer_open_failed_generic'),
        title: tr('errors.call_failed'),
      );
    }
  }
}
