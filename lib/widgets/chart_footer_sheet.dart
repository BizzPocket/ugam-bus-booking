import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/chart_footer.dart';
import '../models/tour.dart';
import '../utils/passenger_display.dart';

/// Modal bottom sheet: edit boardingPlace / departureTime / note (pre-filled
/// from [initial]). Shows read-only context (bus numbers, departure date,
/// handler name) above the fields. Returns the edited footer, or null on cancel.
Future<ChartFooter?> showChartFooterSheet(
  BuildContext context, {
  required ChartFooter initial,
  required Tour tour,
}) {
  return UgamSheet.show<ChartFooter>(
    context,
    title: tr('chart.sheet_title'),
    builder: (_) => _ChartFooterSheet(initial: initial, tour: tour),
  );
}

class _ChartFooterSheet extends StatefulWidget {
  final ChartFooter initial;
  final Tour tour;

  const _ChartFooterSheet({required this.initial, required this.tour});

  @override
  State<_ChartFooterSheet> createState() => _ChartFooterSheetState();
}

class _ChartFooterSheetState extends State<_ChartFooterSheet> {
  late final TextEditingController _boardingPlace;
  late final TextEditingController _departureTime;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    _boardingPlace = TextEditingController(text: widget.initial.boardingPlace);
    _departureTime = TextEditingController(text: widget.initial.departureTime);
    _note = TextEditingController(text: widget.initial.note);
  }

  @override
  void dispose() {
    _boardingPlace.dispose();
    _departureTime.dispose();
    _note.dispose();
    super.dispose();
  }

  void _generate() {
    final footer = widget.initial.copyWith(
      boardingPlace: _boardingPlace.text.trim(),
      departureTime: _departureTime.text.trim(),
      note: _note.text.trim(),
    );
    Navigator.of(context).pop(footer);
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final busNumbers = widget.tour.buses
        .map((b) => b.busNumber.trim().isNotEmpty ? b.busNumber : b.name)
        .where((s) => s.isNotEmpty)
        .join(', ');
    final dateText =
        DateFormat('d MMM, yyyy').format(widget.tour.departureDate);
    final handlerName = widget.tour.handler?.displayName ?? '';

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Read-only context block ────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UgamSpacing.lg),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.row),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (busNumbers.isNotEmpty)
                  _ContextRow(
                    icon: Icons.directions_bus_rounded,
                    label: tr('chart.context_buses_label'),
                    value: busNumbers,
                  ),
                if (busNumbers.isNotEmpty)
                  const SizedBox(height: UgamSpacing.sm),
                _ContextRow(
                  icon: Icons.event_rounded,
                  label: tr('chart.context_date_label'),
                  value: dateText,
                ),
                if (handlerName.isNotEmpty) ...[
                  const SizedBox(height: UgamSpacing.sm),
                  _ContextRow(
                    icon: Icons.person_rounded,
                    label: tr('chart.context_handler_label'),
                    value: handlerName,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.xl),

          // ── Editable footer fields ─────────────────────────────────
          UgamInput(
            label: tr('chart.boarding_place_label'),
            hint: tr('chart.boarding_place_hint'),
            controller: _boardingPlace,
            keyboardType: TextInputType.text,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('chart.departure_time_label'),
            hint: tr('chart.departure_time_hint'),
            controller: _departureTime,
            keyboardType: TextInputType.text,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('chart.note_label'),
            hint: tr('chart.note_hint'),
            controller: _note,
            keyboardType: TextInputType.multiline,
            maxLength: 160,
          ),
          const SizedBox(height: UgamSpacing.xl),

          // ── Actions ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.cardElev,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(
                      tr('app.action.cancel'),
                      style: UgamText.titleS.copyWith(color: c.ink),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                flex: 2,
                child: UgamCTA(
                  label: tr('chart.generate'),
                  leadingIcon: Icons.picture_as_pdf_rounded,
                  onPressed: _generate,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ContextRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ContextRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: c.ink3),
        const SizedBox(width: UgamSpacing.sm),
        SizedBox(
          width: 88,
          child: Text(
            label.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
        ),
      ],
    );
  }
}
