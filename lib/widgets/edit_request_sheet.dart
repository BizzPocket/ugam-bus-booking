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
  bool _saving = false;

  int get _totalSeats => _doubleSofa + _singleSofa;
  int get _alreadyAssigned => widget.passenger.assignedSeats.length;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.passenger.name);
    _note = TextEditingController(text: widget.passenger.note ?? '');
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? AppTheme.cardDark : Colors.white;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
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
                    color: AppTheme.borderDefault,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                tr('edit_request.title'),
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                tr(
                  'edit_request.subtitle',
                  namedArgs: {'name': widget.passenger.displayName},
                ),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppTheme.textMuted,
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
                    color: AppTheme.textMuted,
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
    final theme = Theme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.bgLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface,
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
                color: theme.colorScheme.onSurface,
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
