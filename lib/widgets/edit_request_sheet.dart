import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import 'booking_capture_form.dart';

/// Bottom sheet for editing an existing passenger's seat request, fully styled
/// under the Ugam Design System.
class EditRequestSheet extends StatefulWidget {
  final Tour tour;
  final Passenger passenger;

  const EditRequestSheet({
    super.key,
    required this.tour,
    required this.passenger,
  });

  static Future<void> show({
    required BuildContext context,
    required Tour tour,
    required Passenger passenger,
  }) {
    return UgamSheet.show<void>(
      context,
      title: tr('edit_request.title'),
      builder: (_) => EditRequestSheet(tour: tour, passenger: passenger),
    );
  }

  @override
  State<EditRequestSheet> createState() => _EditRequestSheetState();
}

class _EditRequestSheetState extends State<EditRequestSheet> {
  final _formKey = GlobalKey<BookingCaptureFormState>();
  bool _saving = false;

  int get _alreadyAssigned => widget.passenger.assignedSeats.length;

  Future<void> _submit() async {
    final data = _formKey.currentState?.collect();
    if (data == null) return; // invalid — inline errors already shown by the form

    setState(() => _saving = true);
    try {
      // The shared form (showSeater:false) only returns Double/Single Sofa lines.
      // Preserve any OTHER request lines (e.g. Seater) the passenger already had
      // so editing the sofa counts never silently drops them.
      final preservedLines = widget.passenger.requestLines.where(
        (l) => l.seatType != SeatType.doubleSofa &&
            l.seatType != SeatType.singleSofa,
      );
      final newLines = <RequestLine>[
        ...preservedLines,
        ...data.lines,
      ];

      final preservedSeatCount = preservedLines.fold<int>(0, (s, l) => s + l.qty);
      final newTotalRequested = preservedSeatCount + data.totalSeats;
      List<SeatAssignment> newAssignedSeats = widget.passenger.assignedSeats;
      int released = 0;
      if (newAssignedSeats.length > newTotalRequested) {
        released = newAssignedSeats.length - newTotalRequested;
        newAssignedSeats = newAssignedSeats.sublist(0, newTotalRequested);
      }

      final updated = widget.passenger.copyWith(
        name: data.name,
        note: data.note,
        requestLines: newLines,
        assignedSeats: newAssignedSeats,
        tripType: data.tripType,
      );
      await Get.find<TourController>().updatePassenger(widget.tour.id, updated);
      if (!mounted) return;
      Get.back();
      AppSnackBar.success(
        tr('edit_request.snack_saved', namedArgs: {'name': updated.displayName}),
      );
      if (released > 0) {
        AppSnackBar.error(
          tr(
            released == 1
                ? 'edit_request.auto_released'
                : 'edit_request.auto_released_many',
            namedArgs: {'count': '$released'},
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        AppSnackBar.error(tr('edit_request.snack_error'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(
              'edit_request.subtitle',
              namedArgs: {'name': widget.passenger.displayName},
            ),
            style: UgamText.caption.copyWith(
              color: c.ink2,
            ),
          ),
          if (_alreadyAssigned > 0) ...[
            const SizedBox(height: UgamSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                '$_alreadyAssigned / ${widget.passenger.totalSeatsRequested} ${tr('requests.seat_chip.seats', namedArgs: {'count': ''}).trim()}',
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          BookingCaptureForm(
            key: _formKey,
            fromCity: widget.tour.fromCity,
            toCity: widget.tour.toCity,
            lockPhone: true,
            maxPerType: 10,
            initial: BookingCaptureInitial.fromLines(
              name: widget.passenger.name,
              phone: widget.passenger.phone,
              tripType: widget.passenger.tripType,
              lines: widget.passenger.requestLines,
              note: widget.passenger.note,
            ),
          ),
          const SizedBox(height: UgamSpacing.xl),
          UgamCTA(
            label: _saving ? tr('edit_request.saving') : tr('edit_request.save'),
            leadingIcon: Icons.check_rounded,
            loading: _saving,
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
    );
  }
}
