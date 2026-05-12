import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';

/// Bottom sheet for editing an existing passenger's seat request.
///
/// Why this exists: customers often call back after submitting to switch
/// "2 sofa" → "1 single + 1 double" etc. The admin needs to update the
/// underlying request lines without retyping the name/phone/note.
///
/// Behaviour notes:
/// - Phone is shown but not editable — it is the (tour_id, phone)
///   idempotency key in Postgres. Changing it would either create a
///   duplicate row or hit the unique-index violation.
/// - If the admin reduces the total seat count below what is currently
///   assigned, the extra `assigned_seats` entries are auto-trimmed from
///   the tail of the list and the admin is shown a snackbar so they know
///   which seats need re-assigning.
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
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EditRequestSheet(tour: tour, passenger: passenger),
    );
  }

  @override
  State<EditRequestSheet> createState() => _EditRequestSheetState();
}

class _EditRequestSheetState extends State<EditRequestSheet> {
  late final TextEditingController _name;
  late final TextEditingController _note;
  int _doubleSofa = 0;
  int _singleSofa = 0;
  late TripType _tripType;
  bool _saving = false;

  int get _totalSeats => _doubleSofa + _singleSofa;
  int get _alreadyAssigned => widget.passenger.assignedSeats.length;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.passenger.name);
    _note = TextEditingController(text: widget.passenger.note ?? '');
    _tripType = widget.passenger.tripType;
    for (final line in widget.passenger.requestLines) {
      if (line.seatType == SeatType.doubleSofa) {
        _doubleSofa += line.qty;
      } else if (line.seatType == SeatType.singleSofa) {
        _singleSofa += line.qty;
      }
      // Seater requests aren't expressible in this sheet today; the
      // existing _AddRequestSheet only captures Double/Single Sofa, so
      // mirroring that here keeps the edit UX consistent. If a passenger
      // has a Seater line, it stays untouched (we add the sofa lines we
      // captured back in onto whatever non-sofa lines already exist).
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppSnackBar.error(tr('requests.validation.name_required'));
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error(tr('edit_request.no_seats_error'));
      return;
    }

    setState(() => _saving = true);
    try {
      // Preserve any non-sofa lines (e.g. Seater) the sheet didn't render.
      final preservedLines = widget.passenger.requestLines.where(
        (l) => l.seatType != SeatType.doubleSofa &&
            l.seatType != SeatType.singleSofa,
      );
      final newLines = <RequestLine>[
        ...preservedLines,
        if (_doubleSofa > 0)
          RequestLine(seatType: SeatType.doubleSofa, qty: _doubleSofa),
        if (_singleSofa > 0)
          RequestLine(seatType: SeatType.singleSofa, qty: _singleSofa),
      ];

      // If admin reduced the request below what is currently assigned,
      // trim extra assignments from the tail so the schema stays
      // consistent (totalSeatsAssigned <= totalSeatsRequested).
      final preservedSeatCount = preservedLines.fold<int>(0, (s, l) => s + l.qty);
      final newTotalRequested = preservedSeatCount + _totalSeats;
      List<SeatAssignment> newAssignedSeats = widget.passenger.assignedSeats;
      int released = 0;
      if (newAssignedSeats.length > newTotalRequested) {
        released = newAssignedSeats.length - newTotalRequested;
        newAssignedSeats = newAssignedSeats.sublist(0, newTotalRequested);
      }

      final note = _note.text.trim();
      final updated = widget.passenger.copyWith(
        name: name,
        note: note.isEmpty ? null : note,
        requestLines: newLines,
        assignedSeats: newAssignedSeats,
        tripType: _tripType,
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
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.border(context),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                tr('edit_request.title'),
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text(context),
                ),
              ),
              Text(
                tr(
                  'edit_request.subtitle',
                  namedArgs: {'name': widget.passenger.displayName},
                ),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppColors.textMuted(context),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: tr('edit_request.name_label'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                enabled: false,
                controller: TextEditingController(text: widget.passenger.phone),
                decoration: InputDecoration(
                  labelText: tr('edit_request.phone_label'),
                ),
              ),
              const SizedBox(height: 16),
              _EditTripTypeSegmented(
                value: _tripType,
                fromCity: widget.tour.fromCity,
                toCity: widget.tour.toCity,
                onChanged: (v) => setState(() => _tripType = v),
              ),
              const SizedBox(height: 12),
              _EditSeatCounter(
                label: tr('requests.sheet.double_sofa'),
                value: _doubleSofa,
                onChanged: (v) => setState(() => _doubleSofa = v),
              ),
              const SizedBox(height: 8),
              _EditSeatCounter(
                label: tr('requests.sheet.single_sofa'),
                value: _singleSofa,
                onChanged: (v) => setState(() => _singleSofa = v),
              ),
              if (_alreadyAssigned > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '$_alreadyAssigned / ${widget.passenger.totalSeatsRequested} ${tr('requests.seat_chip.seats', namedArgs: {'count': ''}).trim()}',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.textMuted(context),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _note,
                maxLines: 2,
                maxLength: 160,
                decoration: InputDecoration(
                  labelText: tr('requests.sheet.note_label'),
                  hintText: tr('requests.sheet.note_hint'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _submit,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_rounded, size: 18),
                  label: Text(
                    _saving ? tr('edit_request.saving') : tr('edit_request.save'),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditTripTypeSegmented extends StatelessWidget {
  final TripType value;
  final String fromCity;
  final String toCity;
  final ValueChanged<TripType> onChanged;

  const _EditTripTypeSegmented({
    required this.value,
    required this.fromCity,
    required this.toCity,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('requests.sheet.trip_type_label'),
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textMuted(context),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _EditTripChip(
                icon: Icons.sync_alt_rounded,
                label: tr('requests.sheet.trip_round'),
                selected: value == TripType.roundTrip,
                onTap: () => onChanged(TripType.roundTrip),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _EditTripChip(
                icon: Icons.arrow_forward_rounded,
                label: tr('requests.sheet.trip_outbound', namedArgs: {
                  'from': fromCity,
                  'to': toCity,
                }),
                selected: value == TripType.outboundOnly,
                onTap: () => onChanged(TripType.outboundOnly),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _EditTripChip(
                icon: Icons.arrow_back_rounded,
                label: tr('requests.sheet.trip_return', namedArgs: {
                  'from': toCity,
                  'to': fromCity,
                }),
                selected: value == TripType.returnOnly,
                onTap: () => onChanged(TripType.returnOnly),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EditTripChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _EditTripChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.brandLight : AppColors.surfaceAlt(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppTheme.brand : AppColors.border(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? AppTheme.brand : AppColors.textMuted(context),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 10,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: selected ? AppTheme.brandDark : AppColors.text(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditSeatCounter extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _EditSeatCounter({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.text(context),
              ),
            ),
          ),
          IconButton.outlined(
            visualDensity: VisualDensity.compact,
            onPressed: value > 0 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.text(context),
              ),
            ),
          ),
          IconButton.outlined(
            visualDensity: VisualDensity.compact,
            onPressed: value < 10 ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
