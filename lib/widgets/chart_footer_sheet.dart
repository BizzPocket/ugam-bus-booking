import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/chart_footer.dart';
import '../models/tour.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_occupants.dart';

/// What the agent asked the chart sheet to produce: the edited footer plus the
/// journey [leg] the chart should be scoped to (null = the whole journey).
class ChartExportOptions {
  final ChartFooter footer;
  final CollectLeg? leg;

  const ChartExportOptions({required this.footer, this.leg});
}

/// Modal bottom sheet: pick the journey leg and edit boardingPlace /
/// departureTime / note (pre-filled from [initial]). Shows read-only context
/// (bus numbers, departure date, handler name) above the fields. Returns the
/// chosen options, or null on cancel.
Future<ChartExportOptions?> showChartFooterSheet(
  BuildContext context, {
  required ChartFooter initial,
  required Tour tour,
}) {
  return UgamSheet.show<ChartExportOptions>(
    context,
    title: tr('chart.sheet_title'),
    builder: (_) => _ChartFooterSheet(initial: initial, tour: tour),
  );
}

/// The leg options offered by the sheet, in pill order. Null is the
/// whole-journey chart (both legs on one sheet, today's behaviour).
const List<CollectLeg?> _legOptions = [null, CollectLeg.go, CollectLeg.ret];

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

  /// Index into [_legOptions]. Once the GO leg is completed the outbound riders
  /// have travelled and their seats are freed, so the chart the agent needs is
  /// the RETURN one — default to it instead of making them re-pick every time.
  late int _legIndex;

  @override
  void initState() {
    super.initState();
    _boardingPlace = TextEditingController(text: widget.initial.boardingPlace);
    _departureTime = TextEditingController(text: widget.initial.departureTime);
    _note = TextEditingController(text: widget.initial.note);
    _legIndex = widget.tour.goLegCompleted
        ? _legOptions.indexOf(CollectLeg.ret)
        : 0;
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
    Navigator.of(context).pop(
      ChartExportOptions(footer: footer, leg: _legOptions[_legIndex]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final busNumbers = widget.tour.buses
        .map((b) => b.displayLabel)
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

          // ── Journey leg ────────────────────────────────────────────
          // Which journey this chart is for. The RETURN chart lists only the
          // riders who travel home (round-trip + return-only), flips the route,
          // and banners itself RETURN — so a completed GO leg no longer leaves
          // the agent printing an outbound chart for the way back.
          Text(
            tr('chart.scope_label').toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamSelectorPills(
            padding: EdgeInsets.zero,
            items: [
              UgamSelectorItem(label: tr('chart.scope_full')),
              UgamSelectorItem(label: tr('chart.scope_go')),
              UgamSelectorItem(label: tr('chart.scope_return')),
            ],
            currentIndex: _legIndex,
            onChanged: (i) => setState(() => _legIndex = i),
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
