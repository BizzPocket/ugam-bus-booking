import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../services/push_service.dart';
import '../utils/app_snackbar.dart';
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
      AppSnackBar.success(tr('settings_pages.saved'));
      Get.back();
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
        Container(
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              _ToggleRow(
                c: c,
                icon: Icons.notifications_active_rounded,
                tone: UgamStatVariant.accent,
                title: tr('settings_pages.notifications.push_label'),
                subtitle: tr('settings_pages.notifications.push_hint'),
                value: _push,
                onChanged: (v) => setState(() => _push = v),
              ),
              _RowDivider(c: c),
              _ToggleRow(
                c: c,
                icon: Icons.inbox_rounded,
                tone: UgamStatVariant.good,
                title: tr('settings_pages.notifications.booking_label'),
                subtitle: tr('settings_pages.notifications.booking_hint'),
                value: _bookingRequests,
                enabled: _push,
                onChanged: (v) => setState(() => _bookingRequests = v),
              ),
              _RowDivider(c: c),
              _ToggleRow(
                c: c,
                icon: Icons.payments_rounded,
                tone: UgamStatVariant.warm,
                title: tr('settings_pages.notifications.payment_label'),
                subtitle: tr('settings_pages.notifications.payment_hint'),
                value: _paymentReminders,
                enabled: _push,
                onChanged: (v) => setState(() => _paymentReminders = v),
              ),
              _RowDivider(c: c),
              _ToggleRow(
                c: c,
                icon: Icons.directions_bus_rounded,
                tone: UgamStatVariant.neutral,
                title: tr('settings_pages.notifications.departure_label'),
                subtitle: tr('settings_pages.notifications.departure_hint'),
                value: _departureReminders,
                enabled: _push,
                onChanged: (v) => setState(() => _departureReminders = v),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final UgamStatVariant tone;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.c,
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final (iconBg, iconFg) = switch (tone) {
      UgamStatVariant.accent => (c.accentFill, c.accent),
      UgamStatVariant.good => (c.goodFill, c.good),
      UgamStatVariant.warm => (c.warmFill, c.warm),
      UgamStatVariant.neutral => (c.card, c.ink2),
    };
    final on = value && enabled;

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: iconFg),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: UgamText.caption.copyWith(color: c.ink3, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Switch(
              value: on,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  final UgamColorSet c;
  const _RowDivider({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
      child: Divider(height: 1, color: c.border),
    );
  }
}
