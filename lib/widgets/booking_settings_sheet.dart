import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/booking_mode.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../utils/upi_uri.dart';

/// Organiser controls for how ONE tour sells seats.
///
/// Per tour, not global, so a new flow can be trialled on a single trip while
/// everything else keeps working exactly as before.
Future<void> showBookingSettingsSheet(BuildContext context, Tour tour) {
  return UgamSheet.show<void>(
    context,
    title: tr('booking_settings.title'),
    builder: (_) => _BookingSettingsSheet(tour: tour),
  );
}

class _BookingSettingsSheet extends StatefulWidget {
  final Tour tour;
  const _BookingSettingsSheet({required this.tour});

  @override
  State<_BookingSettingsSheet> createState() => _BookingSettingsSheetState();
}

class _BookingSettingsSheetState extends State<_BookingSettingsSheet> {
  late BookingMode _mode = widget.tour.bookingMode;
  late final _vpa = TextEditingController(text: widget.tour.collectVpa ?? '');
  late final _payee =
      TextEditingController(text: widget.tour.collectPayeeName ?? '');
  late final _advance = TextEditingController(
    text: (widget.tour.advancePerBerthPaise ?? 0) > 0
        ? (widget.tour.advancePerBerthPaise! ~/ 100).toString()
        : '',
  );

  bool _saving = false;
  String? _vpaError;

  /// A tour that already has bookings keeps its mode: switching midway would
  /// change the rules under people who have already booked.
  bool get _modeLocked => widget.tour.passengers.isNotEmpty;

  @override
  void dispose() {
    _vpa.dispose();
    _payee.dispose();
    _advance.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final vpa = _vpa.text.trim();
    if (vpa.isNotEmpty && !isValidVpa(vpa)) {
      setState(() => _vpaError = tr('booking_settings.err_vpa'));
      return;
    }
    setState(() {
      _vpaError = null;
      _saving = true;
    });

    final rupees = int.tryParse(_advance.text.trim());
    try {
      await Get.find<TourController>().updateBookingSettings(
        widget.tour.id,
        bookingMode: _modeLocked ? null : _mode,
        advancePerBerthPaise: rupees != null && rupees > 0 ? rupees * 100 : null,
        clearAdvance: rupees == null || rupees <= 0,
        collectVpa: vpa,
        collectPayeeName: _payee.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      AppSnackBar.success(tr('booking_settings.saved'));
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _eyebrow(c, tr('booking_settings.how_customers_book')),
          const SizedBox(height: UgamSpacing.sm),
          _modeCard(c, BookingMode.request),
          const SizedBox(height: UgamSpacing.xs),
          _modeCard(c, BookingMode.chart),

          Padding(
            padding: const EdgeInsets.only(top: UgamSpacing.sm),
            child: Text(
              tr('booking_settings.move_money_help'),
              style: UgamText.micro.copyWith(color: c.ink3),
            ),
          ),

          if (_modeLocked)
            Padding(
              padding: const EdgeInsets.only(top: UgamSpacing.sm),
              child: Text(
                tr('booking_settings.mode_locked'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
            )
          else if (_mode.isChart && widget.tour.chartNeedsBus)
            Padding(
              padding: const EdgeInsets.only(top: UgamSpacing.sm),
              child: Text(
                tr('booking_settings.needs_bus'),
                style: UgamText.micro.copyWith(color: c.warm),
              ),
            ),

          const SizedBox(height: UgamSpacing.lg),
          _eyebrow(c, tr('booking_settings.money')),
          const SizedBox(height: UgamSpacing.sm),

          UgamInput(
            label: tr('booking_settings.vpa_label'),
            hint: 'name@bank',
            controller: _vpa,
            errorText: _vpaError,
          ),
          const SizedBox(height: 4),
          Text(
            tr('booking_settings.vpa_help'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamInput(
            label: tr('booking_settings.payee_label'),
            controller: _payee,
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamInput(
            label: tr('booking_settings.advance_label'),
            hint: '2000',
            controller: _advance,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 4),
          Text(
            tr('booking_settings.advance_help'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),

          const SizedBox(height: UgamSpacing.lg),
          UgamButton(
            label: tr('booking_settings.save'),
            expand: true,
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }

  Widget _eyebrow(UgamColorSet c, String label) => Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink3),
      );

  Widget _modeCard(UgamColorSet c, BookingMode mode) {
    final on = _mode == mode;
    return GestureDetector(
      onTap: _modeLocked ? null : () => setState(() => _mode = mode),
      child: Opacity(
        opacity: _modeLocked && !on ? 0.4 : 1,
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.md),
          decoration: BoxDecoration(
            color: on ? c.accentFill : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.card),
            border: Border.all(color: on ? c.accent : c.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                on
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 18,
                color: on ? c.accent : c.ink3,
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.displayName,
                      style: UgamText.bodyStrong.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mode.description,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
