import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../services/push_service.dart';
import '../utils/app_nav.dart';
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
        // Master switch — its own floating surface. The dependent alerts below
        // are quieter rows that gate on this being on.
        _ToggleRow(
          c: c,
          icon: Icons.notifications_active_rounded,
          title: tr('settings_pages.notifications.push_label'),
          subtitle: tr('settings_pages.notifications.push_hint'),
          value: _push,
          onChanged: (v) => setState(() => _push = v),
        ),
        const SizedBox(height: UgamSpacing.xl),
        // Per-alert toggles — separated by space, not dividers, so each reads as
        // its own soft tile floating on the ground.
        _ToggleRow(
          c: c,
          icon: Icons.inbox_rounded,
          title: tr('settings_pages.notifications.booking_label'),
          subtitle: tr('settings_pages.notifications.booking_hint'),
          value: _bookingRequests,
          enabled: _push,
          onChanged: (v) => setState(() => _bookingRequests = v),
        ),
        const SizedBox(height: UgamSpacing.sm),
        _ToggleRow(
          c: c,
          icon: Icons.payments_rounded,
          title: tr('settings_pages.notifications.payment_label'),
          subtitle: tr('settings_pages.notifications.payment_hint'),
          value: _paymentReminders,
          enabled: _push,
          onChanged: (v) => setState(() => _paymentReminders = v),
        ),
        const SizedBox(height: UgamSpacing.sm),
        _ToggleRow(
          c: c,
          icon: Icons.directions_bus_rounded,
          title: tr('settings_pages.notifications.departure_label'),
          subtitle: tr('settings_pages.notifications.departure_hint'),
          value: _departureReminders,
          enabled: _push,
          onChanged: (v) => setState(() => _departureReminders = v),
        ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final on = value && enabled;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.lg - 2,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        children: [
          // Single neutral icon tile — the Switch is the only colour signal.
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: enabled ? c.ink2 : c.ink3),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: UgamText.titleS.copyWith(
                    color: enabled ? c.ink : c.ink3,
                  ),
                ),
                const SizedBox(height: 2),
                // When the master Push switch is off, dependent rows can't be
                // toggled — say so inline instead of dimming the whole row.
                Text(
                  enabled
                      ? subtitle
                      : tr('settings_pages.notifications.turn_on_hint'),
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Switch(
            value: on,
            onChanged: enabled ? onChanged : null,
            activeTrackColor: c.accent,
            activeThumbColor: c.onAccent,
          ),
        ],
      ),
    );
  }
}

