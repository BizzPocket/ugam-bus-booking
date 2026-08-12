import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../services/push_service.dart';
import '../utils/app_nav.dart';
import '../utils/app_snackbar.dart';
import '../widgets/settings_scaffold.dart';

/// ── Canonical settings-row geometry ────────────────────────────────────────
/// Kept identical to the block at the top of `settings_screen.dart`. See the
/// note there for why these exist; change both together.
const double _rowIconBox = 40;
const double _rowIconGlyph = 20;
const double _rowIconRadius = 12;
const double _rowMinHeight = 64;

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
        _GroupCard(
          children: [
            _ToggleRow(
              c: c,
              icon: Icons.notifications_active_rounded,
              title: tr('settings_pages.notifications.push_label'),
              subtitle: tr('settings_pages.notifications.push_hint'),
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
        _GroupCard(
          children: [
            _ToggleRow(
              c: c,
              icon: Icons.inbox_rounded,
              title: tr('settings_pages.notifications.booking_label'),
              subtitle: tr('settings_pages.notifications.booking_hint'),
              value: _bookingRequests,
              enabled: _push,
              onChanged: (v) => setState(() => _bookingRequests = v),
            ),
            _Divider(c: c),
            _ToggleRow(
              c: c,
              icon: Icons.payments_rounded,
              title: tr('settings_pages.notifications.payment_label'),
              subtitle: tr('settings_pages.notifications.payment_hint'),
              value: _paymentReminders,
              enabled: _push,
              onChanged: (v) => setState(() => _paymentReminders = v),
            ),
            _Divider(c: c),
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
        ),
      ],
    );
  }
}

/// Grouped rows on one card surface. Mirrors `_GroupCard` in
/// `settings_screen.dart` — see the note there on why the [Material] matters.
class _GroupCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    // SettingsScaffold uses CrossAxisAlignment.start, so claim the width.
    return SizedBox(
      width: double.infinity,
      child: UgamCard.plain(
        elev: true,
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(UgamRadius.card),
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: children),
          ),
        ),
      ),
    );
  }
}

/// Mirrors `_Divider` in `settings_screen.dart`.
class _Divider extends StatelessWidget {
  final UgamColorSet c;
  const _Divider({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: UgamSpacing.lg +
            UgamScale.px(context, _rowIconBox) +
            UgamSpacing.md,
        right: UgamSpacing.lg,
      ),
      child: Divider(height: 1, color: c.border),
    );
  }
}

/// Mirrors `_RowIcon` in `settings_screen.dart`.
class _RowIcon extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color foreground;

  const _RowIcon({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final box = UgamScale.px(context, _rowIconBox);
    return Container(
      width: box,
      height: box,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(_rowIconRadius),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: UgamScale.px(context, _rowIconGlyph),
        color: foreground,
      ),
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

    return InkWell(
      // The whole row toggles, not just the ~50px switch. The nav rows on the
      // Settings hub have always been fully tappable; these looked identical
      // but only responded to a hit on the control itself.
      onTap: enabled ? () => onChanged(!value) : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              // Single neutral icon tile — the Switch is the only colour
              // signal. `card` on a `cardElev` group, matching the hub: this
              // pairing used to be inverted (a cardElev tile on a card row).
              _RowIcon(
                icon: icon,
                background: c.card,
                foreground: enabled ? c.ink2 : c.ink3,
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Nothing here is clamped to one line: the Hindi
                    // `turn_on_hint` overruns the space left beside a switch at
                    // 375px, so it has to be free to wrap rather than ellipsis.
                    Text(
                      title,
                      style: UgamText.titleS.copyWith(
                        color: enabled ? c.ink : c.ink3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // When the master Push switch is off, dependent rows can't
                    // be toggled — say so inline instead of dimming the row.
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
              // Was a raw Material Switch that set only the two ACTIVE colours,
              // so the off state fell back to Material's grey. UgamSwitch tints
              // all four, adds the haptic, guarantees the 44pt box and
              // announces the toggled state to a screen reader.
              UgamSwitch(
                value: on,
                onChanged: enabled ? onChanged : null,
                semanticLabel: title,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

