part of '../add_bus_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// Step 1 — Identity
// ════════════════════════════════════════════════════════════════════════

class _Step1Identity extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController busName;
  final TextEditingController busNumber;
  final TextEditingController boardingPoint;
  final TimeOfDay? departureTime;
  final TextEditingController driverName;
  final TextEditingController driverPhone;
  final bool isAC;
  final String slotBadge;

  /// Owned by the wizard so the duplicate-plate check can fire on blur.
  final FocusNode busNumberFocus;
  final String? busNumberError;
  final VoidCallback onBusNumberChanged;
  final ValueChanged<bool> onToggleAC;
  final VoidCallback onPickDepartureTime;
  final VoidCallback onAnyChange;

  const _Step1Identity({
    required this.c,
    required this.busName,
    required this.busNumber,
    required this.boardingPoint,
    required this.departureTime,
    required this.driverName,
    required this.driverPhone,
    required this.isAC,
    required this.slotBadge,
    required this.busNumberFocus,
    required this.busNumberError,
    required this.onBusNumberChanged,
    required this.onToggleAC,
    required this.onPickDepartureTime,
    required this.onAnyChange,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const BouncingScrollPhysics(),
      children: [
        // Title only — the old intro paragraph just restated the field hints,
        // so it's dropped to cut the wall of text at the top of this step.
        Text(
          tr('add_bus.step1.title'),
          style: UgamText.titleXl.copyWith(color: c.ink),
        ),
        const SizedBox(height: UgamSpacing.xl),

        // ── The bus ───────────────────────────────────────────────
        _GroupHeader(c: c, text: tr('add_bus.group.bus')),
        const SizedBox(height: UgamSpacing.md),
        _Label(c: c, text: tr('add_bus.label.slot')),
        const SizedBox(height: UgamSpacing.sm),
        _SlotBadge(c: c, label: slotBadge),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('add_bus.label.bus_name'),
          controller: busName,
          hint: tr('add_bus.hint.bus_name'),
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('add_bus.label.bus_number'),
          controller: busNumber,
          focusNode: busNumberFocus,
          hint: tr('add_bus.hint.bus_number_plain'),
          errorText: busNumberError,
          onChanged: (_) => onBusNumberChanged(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _ToggleRow(
          c: c,
          icon: Icons.ac_unit_rounded,
          label: tr('add_bus.ac_toggle.label'),
          subtitle: isAC
              ? tr('add_bus.ac_toggle.on')
              : tr('add_bus.ac_toggle.off'),
          value: isAC,
          onChanged: onToggleAC,
        ),
        const SizedBox(height: UgamSpacing.xl),

        // ── Boarding — place (wide) + time (narrow) share a row, so the
        //    step is no longer a stack of identical full-width boxes. ──
        _GroupHeader(c: c, text: tr('add_bus.group.boarding')),
        const SizedBox(height: UgamSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: UgamInput(
                label: tr('add_bus.label.boarding_point'),
                controller: boardingPoint,
                hint: tr('add_bus.hint.boarding_point_short'),
                onChanged: (_) => onAnyChange(),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              flex: 2,
              child: UgamPickerField(
                label: tr('add_bus.label.departure_time'),
                value: departureTime != null
                    ? (formatHhMm(hhmmFromTimeOfDay(departureTime!)) ?? '')
                    : '',
                placeholder: tr('add_bus.hint.departure_time_short'),
                icon: Icons.access_time_rounded,
                onTap: onPickDepartureTime,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xl),

        // ── Driver (optional) ─────────────────────────────────────
        _GroupHeader(c: c, text: tr('add_bus.group.driver')),
        const SizedBox(height: UgamSpacing.md),
        UgamInput(
          label: tr('add_bus.label.driver_name'),
          controller: driverName,
          hint: tr('add_bus.hint.driver_name_plain'),
          // These two were the only inputs on the step with no change hook, so
          // typing a driver in did not register as unsaved work.
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamPhoneInput(
          label: tr('add_bus.label.driver_phone'),
          controller: driverPhone,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.xl),
      ],
    );
  }
}
