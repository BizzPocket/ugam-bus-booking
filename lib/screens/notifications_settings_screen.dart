import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../services/push_service.dart';
import '../utils/app_nav.dart';
import '../utils/app_snackbar.dart';
import '../widgets/settings_row_kit.dart';
import '../widgets/settings_scaffold.dart';

/// Settings → Notifications. Per-admin preferences for which alerts the
/// organiser wants. Persisted to the `admins` row so they follow the
/// account across devices.
class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  final _authCtrl = Get.find<AuthController>();

  late bool _push;
  late bool _bookingRequests;
  late bool _paymentReminders;
  late bool _departureReminders;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final a = _authCtrl.currentAdmin.value;
    _push = a?.pushEnabled ?? true;
    _bookingRequests = a?.notifyBookingRequests ?? true;
    _paymentReminders = a?.notifyPaymentReminders ?? true;
    _departureReminders = a?.notifyDepartureReminders ?? true;
  }

  Future<void> _save() async {
    final admin = _authCtrl.currentAdmin.value;
    if (admin == null) {
      AppSnackBar.error(tr('settings_pages.no_admin'));
      return;
    }
    setState(() => _saving = true);
    try {
      await _authCtrl.saveAdmin(admin.copyWith(
        pushEnabled: _push,
        notifyBookingRequests: _bookingRequests,
        notifyPaymentReminders: _paymentReminders,
        notifyDepartureReminders: _departureReminders,
      ));
      // Keep this device's FCM token in sync with the master Push switch:
      // turning push on registers (and prompts for OS permission); turning it
      // off drops the token so nothing is delivered even if the server lags.
      if (_push) {
        // ignore: unawaited_futures
        PushService.instance.register();
      } else {
        // ignore: unawaited_futures
        PushService.instance.unregister();
      }
      if (!mounted) return;
      AppSnackBar.success(tr('settings_pages.saved'));
      // Pop the nested tab stack this page lives on; a bare Get.back() pops the
      // ROOT navigator and would leave the page open after saving.
      AppNav.pop(context);
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return SettingsScaffold(
      title: tr('settings.notifications_title'),
      saving: _saving,
      saveLabel: tr('settings_pages.save'),
      onSave: _save,
      children: [
        // Master switch — its own card, so it reads as the thing everything
        // below depends on rather than as the first of four equals.
        SettingsGroupCard(
          children: [
            SettingsToggleRow(
              c: c,
              icon: Icons.notifications_active_rounded,
              title: tr('settings_pages.notifications.push_label'),
              subtitle: tr('settings_pages.notifications.push_hint'),
              disabledSubtitle: tr('settings_pages.notifications.turn_on_hint'),
              value: _push,
              onChanged: (v) => setState(() => _push = v),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xl),
        // These three used to be loose tiles separated by 8px of air. Now that
        // every card carries elevation that reads as three stacked shadows;
        // one grouped card with hairlines is also exactly what the Settings hub
        // does, and this cluster has to look like one app.
        UgamSectionLabel(
          tr('settings_pages.notifications.section_alerts'),
          color: c.ink2,
        ),
        const SizedBox(height: UgamSpacing.sm),
        SettingsGroupCard(
          children: [
            SettingsToggleRow(
              c: c,
              icon: Icons.inbox_rounded,
              title: tr('settings_pages.notifications.booking_label'),
              subtitle: tr('settings_pages.notifications.booking_hint'),
              disabledSubtitle: tr('settings_pages.notifications.turn_on_hint'),
              value: _bookingRequests,
              enabled: _push,
              onChanged: (v) => setState(() => _bookingRequests = v),
            ),
            SettingsRowDivider(c: c),
            SettingsToggleRow(
              c: c,
              icon: Icons.payments_rounded,
              title: tr('settings_pages.notifications.payment_label'),
              subtitle: tr('settings_pages.notifications.payment_hint'),
              disabledSubtitle: tr('settings_pages.notifications.turn_on_hint'),
              value: _paymentReminders,
              enabled: _push,
              onChanged: (v) => setState(() => _paymentReminders = v),
            ),
            SettingsRowDivider(c: c),
            SettingsToggleRow(
              c: c,
              icon: Icons.directions_bus_rounded,
              title: tr('settings_pages.notifications.departure_label'),
              subtitle: tr('settings_pages.notifications.departure_hint'),
              disabledSubtitle: tr('settings_pages.notifications.turn_on_hint'),
              value: _departureReminders,
              enabled: _push,
              onChanged: (v) => setState(() => _departureReminders = v),
            ),
          ],
        ),
      ],
    );
  }
}
