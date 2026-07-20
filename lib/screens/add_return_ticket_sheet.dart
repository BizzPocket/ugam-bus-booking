import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../utils/app_snackbar.dart';
import '../widgets/booking_capture_form.dart';

/// Admin-only "Add return ticket" sheet, shown once a tour is in its RETURN
/// phase (GO leg complete). Reuses the shared [BookingCaptureForm] but forces
/// every line to [TripType.returnOnly] — the GO bus has already departed, so a
/// new rider can only board the return — and books past the lock gate
/// (`overrideLock: true`) because the tour is intentionally locked by then.
class AddReturnTicketSheet extends StatefulWidget {
  final Tour tour;

  const AddReturnTicketSheet({super.key, required this.tour});

  /// Open the sheet. [onAdded] fires after a successful add (so a caller already
  /// on the seat chart can refresh / point the agent at the new pending rider).
  static void show(BuildContext context, Tour tour, {VoidCallback? onAdded}) {
    UgamSheet.show(
      context,
      title: tr('tour_detail.add_return_ticket_title'),
      builder: (_) => AddReturnTicketSheet(tour: tour),
    ).then((_) => onAdded?.call());
  }

  @override
  State<AddReturnTicketSheet> createState() => _AddReturnTicketSheetState();
}

class _AddReturnTicketSheetState extends State<AddReturnTicketSheet> {
  final _formKey = GlobalKey<BookingCaptureFormState>();
  final _userCtrl = Get.find<UserController>();

  bool _saving = false;
  int _seatCount = 0;

  Future<void> _submit() async {
    final data = _formKey.currentState?.collect();
    if (data == null) return; // invalid — inline errors already shown.

    setState(() => _saving = true);
    try {
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: data.name,
        phone: data.normalisedPhone,
        requestLines: data.lines, // already returnOnly via forcedLeg
        note: data.note,
        tripType: TripType.returnOnly,
        pickupLocationId: data.pickupLocationId,
        pickupLocationName: data.pickupLocationName,
      );
      await Get.find<TourController>()
          .addPassenger(widget.tour.id, passenger, overrideLock: true);
      // ignore: unawaited_futures
      _userCtrl.rememberContact(name: data.name, phone: data.phone);
      if (!mounted) return;
      Get.back();
      AppSnackBar.success(
        tr('tour_detail.return_ticket_added', namedArgs: {'name': data.name}),
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('requests.snack.add_error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // Tapping empty space unfocuses the name field, which dismisses the
    // contact-autocomplete dropdown (opaque so gaps between fields count as
    // taps; the scroll view still wins drags and fields still take their taps).
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.opaque,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr('tour_detail.add_return_ticket_hint'),
              style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
            ),
            const SizedBox(height: UgamSpacing.lg),
            BookingCaptureForm(
              key: _formKey,
              fromCity: widget.tour.fromCity,
              toCity: widget.tour.toCity,
              enableContacts: true,
              maxPerType: 10,
              forcedLeg: TripType.returnOnly,
              onChanged: () {
                final n = _formKey.currentState?.totalSeats ?? 0;
                if (n != _seatCount) setState(() => _seatCount = n);
              },
            ),
            const SizedBox(height: UgamSpacing.lg),
            UgamCTA(
              label: _saving
                  ? tr('requests.sheet.saving')
                  : tr('tour_detail.add_return_ticket'),
              leadingIcon: Icons.check_rounded,
              trailingValue: _seatCount > 0 ? '$_seatCount' : null,
              loading: _saving,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
