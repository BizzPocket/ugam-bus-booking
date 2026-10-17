part of 'passenger_sheet.dart';

// The header and fact grid of [PassengerSheet].
extension _PassengerSheetSections on _PassengerSheetState {
  // ── Pieces ──────────────────────────────────────────────────

  /// Initial disc + name + berth code/type + the lens's word for this berth.
  ///
  /// The whole block carries ONE semantic node holding the full spec §11 label
  /// ("DL3, Priti Patel, paid, double sofa, boarding at Adajan") rather than
  /// four nodes a screen reader would read as disconnected fragments.
  Widget _header(BuildContext context, UgamColorSet c) {
    final berth = _berth;
    final paint = widget.lens.paint(berth, c);
    final name = _displayName;

    return Semantics(
      container: true,
      label: _semanticLabel,
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: UgamScale.px(context, 46),
              height: UgamScale.px(context, 46),
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                SeatChartTile.initials(name),
                style: UgamText.bodyStrong.copyWith(color: c.onAccent),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: UgamText.titleM.copyWith(color: c.ink),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr(
                      'occupant_sheet.seat_on',
                      namedArgs: {
                        'seat': berth.code,
                        'bus': widget.busName,
                      },
                    ),
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  // The scannable identity row: code · type · state. The berth
                  // CODE is a chip of its own rather than only living inside
                  // the sentence above — it is the one string a handler reads
                  // out loud ("DL3?"), and it must survive at a glance.
                  //
                  // Colour is never the only signal: the state chip carries the
                  // lens's glyph as well as its fill.
                  Wrap(
                    spacing: UgamSpacing.sm,
                    runSpacing: UgamSpacing.xs,
                    children: [
                      UgamReqChip(
                        label: berth.code,
                        variant: UgamChipVariant.accent,
                      ),
                      _GlyphChip(
                        glyph: paint.glyph,
                        label: widget.lens.stateLabel(berth),
                        fill: paint.fill,
                        ink: paint.ink,
                      ),
                      // The same `♀` the occupancy lens paints, carried across
                      // the other four lenses so the fact survives the switch.
                      if (_ladiesIsHidden)
                        _GlyphChip(
                          glyph: '♀',
                          label: tr('board_lens.state_ladies'),
                          fill: c.warmFill,
                          ink: c.warm,
                          variant: UgamChipVariant.warm,
                        ),
                      if (berth.seatTypeLabel != null &&
                          berth.seatTypeLabel!.trim().isNotEmpty)
                        UgamReqChip(
                          label: berth.seatTypeLabel!,
                          variant: UgamChipVariant.neutral,
                          leading: Icons.event_seat_rounded,
                        ),
                      if (_livePassenger?.isPriorityApproved ?? false)
                        UgamReqChip(
                          label: tr('requests.chip.priority').toUpperCase(),
                          variant: UgamChipVariant.warm,
                          leading: Icons.star_rounded,
                        ),
                      if (_occ.passenger?.isCancelRequested ?? false)
                        UgamReqChip(
                          label: tr(
                            'requests.chip.cancel_requested',
                          ).toUpperCase(),
                          variant: UgamChipVariant.danger,
                          leading: Icons.report_problem_rounded,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Leg, pickup, group, fare — everything the three old surfaces each showed
  /// some of. Two columns where there is room, one where a Gujarati value needs
  /// the whole width.
  Widget _facts(BuildContext context, UgamColorSet c) {
    final berth = _berth;
    final leg = _legLabel;

    final facts = <(String, String)>[
      if (leg != null) (tr('passenger_sheet.field_leg'), leg),
      (tr('passenger_sheet.field_payment'), _paymentLabel),
      (
        tr('passenger_sheet.field_pickup'),
        (berth.pickupStopName?.trim().isNotEmpty ?? false)
            ? berth.pickupStopName!
            : tr('board_lens.state_no_stop'),
      ),
      (
        tr('passenger_sheet.field_group'),
        (berth.groupName?.trim().isNotEmpty ?? false)
            ? berth.groupName!
            : tr('board_lens.state_no_group'),
      ),
      (
        tr('passenger_sheet.field_fare'),
        Formatters.formatMoneyInr(berth.fareDue),
      ),
      (tr('passenger_sheet.field_paid'), Formatters.formatMoneyInr(berth.paid)),
      if (berth.outstanding > 0)
        (
          tr('passenger_sheet.field_due'),
          Formatters.formatMoneyInr(berth.outstanding),
        ),
      if (berth.changeOwed > 0)
        (
          tr('passenger_sheet.field_change'),
          Formatters.formatMoneyInr(berth.changeOwed),
        ),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        // Below this a Gujarati label + its value cannot share a line with a
        // second column without both truncating.
        const twoColumnFloor = 280.0;
        final columns = box.maxWidth >= twoColumnFloor ? 2 : 1;
        final width = columns == 1
            ? box.maxWidth
            : (box.maxWidth - UgamSpacing.md) / 2;
        return Wrap(
          spacing: UgamSpacing.md,
          runSpacing: UgamSpacing.md,
          children: [
            for (final (label, value) in facts)
              SizedBox(
                width: width,
                child: _Fact(label: label, value: value, c: c),
              ),
          ],
        );
      },
    );
  }
}
