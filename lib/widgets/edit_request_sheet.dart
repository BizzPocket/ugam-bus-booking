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
import '../models/trip_type.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';

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
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('edit_request.name_label'),
            controller: _name,
            keyboardType: TextInputType.text,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('edit_request.phone_label'),
            controller: TextEditingController(text: widget.passenger.phone),
            enabled: false,
          ),
          const SizedBox(height: UgamSpacing.lg),
          _EditTripTypeSegmented(
            value: _tripType,
            fromCity: widget.tour.fromCity,
            toCity: widget.tour.toCity,
            onChanged: (v) => setState(() => _tripType = v),
          ),
          const SizedBox(height: UgamSpacing.lg),
          _EditSeatCounter(
            label: tr('requests.sheet.double_sofa'),
            value: _doubleSofa,
            onChanged: (v) => setState(() => _doubleSofa = v),
          ),
          const SizedBox(height: UgamSpacing.sm),
          _EditSeatCounter(
            label: tr('requests.sheet.single_sofa'),
            value: _singleSofa,
            onChanged: (v) => setState(() => _singleSofa = v),
          ),
          if (_alreadyAssigned > 0) ...[
            const SizedBox(height: UgamSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '$_alreadyAssigned / ${widget.passenger.totalSeatsRequested} ${tr('requests.seat_chip.seats', namedArgs: {'count': ''}).trim()}',
                style: UgamText.caption.copyWith(
                  color: c.ink2,
                ),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('requests.sheet.note_label'),
            hint: tr('requests.sheet.note_hint'),
            controller: _note,
            maxLength: 160,
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
    final c = UgamColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('requests.sheet.trip_type_label').toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.sm),
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
            const SizedBox(width: UgamSpacing.sm),
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
            const SizedBox(width: UgamSpacing.sm),
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
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? c.accent : c.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? c.accent : c.ink3,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: UgamText.caption.copyWith(
                fontSize: 9,
                height: 1.2,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? c.ink : c.ink2,
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
    final c = UgamColors.of(context);
    final canMinus = value > 0;
    final canPlus = value < 10;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          _CounterButton(
            icon: Icons.remove_rounded,
            enabled: canMinus,
            onTap: canMinus ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: UgamText.tabular(
                UgamText.titleM.copyWith(
                  color: c.ink,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          _CounterButton(
            icon: Icons.add_rounded,
            enabled: canPlus,
            onTap: canPlus ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _CounterButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _CounterButton({
    required this.icon,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tapIn,
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: enabled ? c.card : c.card.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled ? c.border : c.border.withValues(alpha: 0.5),
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 16,
          color: enabled ? c.ink : c.ink3,
        ),
      ),
    );
  }
}
