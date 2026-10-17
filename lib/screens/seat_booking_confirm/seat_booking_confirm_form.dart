part of '../seat_booking_confirm_screen.dart';

// Form sections of [SeatBookingConfirmScreen]: fields, errors, summary,
// next-step line and the gender row.
extension _SeatBookingConfirmForm on _SeatBookingConfirmScreenState {
  /// The form, composed to FILL the viewport.
  ///
  /// It used to be a plain `ListView`, which left whatever height the fields
  /// did not use as dead air between the note field and the pay bar — the
  /// screen read as half-built. The body is now given a minimum height of the
  /// viewport and split into two blocks: the fields at the top and the
  /// "what happens when you tap confirm" line pinned to the bottom, directly
  /// above the CTA it is describing. Slack goes BETWEEN them, so on a tall
  /// phone the gap is a deliberate seam and on a short one (or with the
  /// keyboard up) the whole thing simply scrolls.
  Widget _form(UgamColorSet c) {
    // Must match the scroll padding below, so a form that exactly fits the
    // viewport does not gain a phantom scrollbar.
    const vPad = UgamSpacing.sm + UgamSpacing.lg;

    return AutofillGroup(
      child: LayoutBuilder(
        builder: (context, box) {
          final minH = box.maxHeight - vPad;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              UgamSpacing.sm,
              UgamSpacing.gutter,
              UgamSpacing.lg,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minH > 0 ? minH : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _fields(c),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: UgamSpacing.lg),
                    child: _nextStep(c),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _fields(UgamColorSet c) => [
        _summary(c),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('seat_confirm.name_label'),
          // Every field carries a hint. A filled, hint-less rounded rectangle
          // is pixel-for-pixel the app's own skeleton loader, so a form
          // without them reads as still loading rather than ready to type in.
          hint: tr('seat_confirm.name_hint'),
          controller: _name,
          keyboardType: TextInputType.name,
          autofillHints: const [AutofillHints.name],
          errorText: _nameError,
        ),
        const SizedBox(height: UgamSpacing.sm),
        UgamInput(
          label: tr('seat_confirm.phone_label'),
          hint: tr('seat_confirm.phone_hint'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          // The formatter `UgamPhoneInput` already ships: strip formatting as
          // it is typed and keep the LAST 10 digits, so a pasted
          // `+91 98765 43210` lands as a valid number rather than as 12 digits
          // the customer has to go back and edit.
          inputFormatters: const [IndianMobileFormatter()],
          maxLength: 10,
          autofillHints: const [AutofillHints.telephoneNumber],
          errorText: _phoneError,
        ),
        const SizedBox(height: UgamSpacing.sm),
        // The gender pills used to be the one unlabelled control in the form —
        // three grey lozenges with no caption. Labelled in the same
        // micro-caps as the inputs so the whole form reads as one system.
        UgamSectionLabel(tr('seat_confirm.gender_label'), color: c.ink2),
        const SizedBox(height: UgamSpacing.sm),
        _genderRow(c),
        const SizedBox(height: UgamSpacing.sm),
        // `UgamPickerField`'s own label is sentence-case `caption`, which does
        // not match the inputs above it, and it cannot turn red on error. The
        // label is therefore rendered here instead.
        UgamSectionLabel(
          tr('seat_confirm.pickup_label'),
          color: _pickupError != null ? c.danger : c.ink2,
        ),
        const SizedBox(height: UgamSpacing.sm),
        UgamPickerField(
          value: _pickup?.name ?? '',
          placeholder: tr('seat_confirm.pickup_hint'),
          icon: Icons.place_outlined,
          onTap: _pickPickup,
        ),
        if (_pickupError != null) _fieldError(c, _pickupError!),
        const SizedBox(height: UgamSpacing.sm),
        UgamInput(
          label: tr('seat_confirm.note_label'),
          hint: tr('seat_confirm.note_hint'),
          controller: _note,
          keyboardType: TextInputType.multiline,
          maxLines: 2,
        ),
      ];

  /// Mirrors the error line `UgamInput` paints under itself (glyph + words in
  /// danger ink), because the pickup field is not an input and cannot use it.
  /// The old version was bare micro text on a hand-typed 4px inset.
  Widget _fieldError(UgamColorSet c, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.error_outline_rounded,
              size: UgamScale.px(context, 14),
              color: c.danger,
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: UgamText.caption.copyWith(color: c.danger),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The one line that makes the bottom of this screen deliberate: what the
  /// CTA immediately below is actually about to do. A checkout that says "we
  /// hold the seats for 5 minutes" before you commit is the difference between
  /// a confident tap and a back button.
  Widget _nextStep(UgamColorSet c) {
    final holds = widget.tour.collectsAdvance;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            // The glyph's optical centre sits above its box; a flush top edge
            // reads as floating above the first line of text.
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              holds ? Icons.timer_outlined : Icons.verified_outlined,
              size: UgamScale.px(context, 14),
              color: c.ink3,
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.xs + 2),
        Expanded(
          child: Text(
            tr(holds ? 'seat_confirm.next_hold' : 'seat_confirm.next_confirm'),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
        ),
      ],
    );
  }

  /// The trip summary — the only settled fact on a screen full of empty
  /// fields, so it sits ON the page at [UgamElevationSet.rest] rather than
  /// being another flat grey rectangle level with the inputs. That depth is
  /// what `UgamCard` now applies for the whole app; this was hand-painting
  /// the same fill and hairline with no shadow at all.
  Widget _summary(UgamColorSet c) {
    // A split party (migration 068) has more than one bus, and naming only
    // the first one told a customer their whole party was on it.
    final multi = widget.selections.length > 1;
    final seatStyle = UgamText.tabular(
      UgamText.bodyStrong.copyWith(color: c.accent),
    );

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.tour.fromCity} → ${widget.tour.toCity}',
            style: UgamText.titleS.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            multi ? _legLabel() : '${_soleBus.name} · ${_legLabel()}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          for (var i = 0; i < widget.selections.length; i++) ...[
            if (i > 0) const SizedBox(height: UgamSpacing.xs),
            if (multi)
              Text(
                widget.selections[i].bus.name,
                style: UgamText.caption.copyWith(color: c.ink3),
              ),
            Text(_seatsOf(widget.selections[i]), style: seatStyle),
          ],
        ],
      ),
    );
  }

  String _seatsOf(ChartBusSelection selection) => selection.picks
      .map((p) => p.berths > 1 ? '${p.seatId} ×${p.berths}' : p.seatId)
      .join(' · ');

  /// A mixed booking must SAY it is mixed. Collapsing it to the coarse
  /// round-trip summary would tell a family that everyone is coming back.
  String _legLabel() {
    final picks = [for (final s in widget.selections) ...s.picks];
    final legs = picks.map((p) => p.leg).toSet();
    if (legs.length > 1) return tr('seat_confirm.leg_mixed');
    switch (legs.isEmpty ? TripType.roundTrip : legs.first) {
      case TripType.roundTrip:
        return tr('seat_pick.leg_round');
      case TripType.outboundOnly:
        return tr('seat_pick.leg_go');
      case TripType.returnOnly:
        return tr('seat_pick.leg_return');
    }
  }

  /// Gender drives the ladies marker other customers see on the chart — a
  /// marker, never a name. Optional: a rider who declines simply shows as a
  /// neutral booked seat.
  Widget _genderRow(UgamColorSet c) {
    Widget opt(String? value, String label) {
      final on = _gender == value;
      return Expanded(
        // Was a bare GestureDetector: it fired, but the finger got nothing
        // back — no scale, no haptic — which is what made the row read as a
        // mockup next to the CTA.
        child: UgamTappable(
          onTap: () => _update(() => _gender = value),
          pressedScale: 0.95,
          child: Container(
            // Floored at the 44pt tap minimum. The padding alone resolved to
            // ~32pt, so all three pills were under-target.
            height: UgamScale.tap(context, 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xs),
            decoration: BoxDecoration(
              color: on ? c.cardElev : Colors.transparent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(color: on ? c.ink3 : c.border),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              // Gujarati runs ~30% longer than the English source and
              // "Prefer not to say" is the longest option in every locale —
              // it wraps to a second line inside the pill rather than
              // overflowing the row.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: UgamText.caption.copyWith(
                color: on ? c.ink : c.ink2,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        opt('female', tr('seat_confirm.gender_female')),
        // A gap BETWEEN the pills, not a trailing margin on each — the old
        // right margin left the last pill 4px short of the fields above it.
        const SizedBox(width: UgamSpacing.xs),
        opt('male', tr('seat_confirm.gender_male')),
        const SizedBox(width: UgamSpacing.xs),
        opt(null, tr('seat_confirm.gender_skip')),
      ],
    );
  }
}
