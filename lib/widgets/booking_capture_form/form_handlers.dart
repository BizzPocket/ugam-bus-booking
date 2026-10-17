part of '../booking_capture_form.dart';

// Handlers, presentation helpers and sub-section builders of
// [BookingCaptureFormState], split out of the state class. Anything handed out
// as a tear-off (listeners, `onChanged:` / `onTap:` values) stays on the class
// so it keeps a stable identity.

extension _BookingCaptureFormHandlers on BookingCaptureFormState {
  void _pickContact(AppUser user) {
    HapticFeedback.selectionClick();
    _name.text = user.name;
    _phone.text = normalisePhone(user.phone);
    _update(() {
      _nameError = null;
      _phoneError = null;
      _contactMatches = const [];
    });
    FocusScope.of(context).unfocus();
    _notify();
  }

  String _contactInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first.characters.first}${parts.last.characters.first}'.toUpperCase();
    }
    return name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
  }

  // ─── SEAT COUNTERS ────────────────────────────────────────────────────────

  /// Set the quantity for one seat type on a given leg's tab.
  void _setQty(TripType leg, SeatType type, int v) => _update(() {
    final cell = _cells[leg]?[type];
    if (cell == null) return;
    cell.qty = v.clamp(0, widget.maxPerType);
    if (_totalSeats > 0) _seatsError = null;
    _notify();
  });

  /// Ask which band this FULL-TRIP seat is for, then how many, and add the
  /// answer as its own line. Called once per band — taking the same seat type
  /// in two bands is two taps of "add" and produces two lines.
  Future<void> _openBandPicker(SeatType type) async {
    final options = _bandOptions[type] ?? const <BandOption>[];
    final taken = (_banded[type] ?? const <_BandEntry>[])
        .fold<int>(0, (s, e) => s + e.qty);
    final remaining = (widget.maxPerType - taken).clamp(0, widget.maxPerType);
    if (remaining <= 0) return;

    final pick = await showBandPickerDialog(
      context,
      seatTypeLabel: _seatLabel(type),
      options: options,
      maxQty: remaining,
    );
    if (pick == null || !mounted) return;

    _update(() {
      _banded[type]!.add(
        _BandEntry(band: pick.option.band, qty: pick.qty),
      );
      if (_totalSeats > 0) _seatsError = null;
      _notify();
    });
  }

  void _removeBandEntry(SeatType type, int index) {
    final list = _banded[type];
    if (list == null || index < 0 || index >= list.length) return;
    HapticFeedback.lightImpact();
    _update(() {
      list.removeAt(index);
      _notify();
    });
  }

  /// Tap-to-type a quantity on a numeric keypad. 6 seats = one type action.
  Future<void> _promptQuantity({
    required String title,
    required int current,
    required ValueChanged<int> onSet,
  }) async {
    final controller = TextEditingController(
      text: current > 0 ? '$current' : '',
    );
    final entered = await UgamDialog.show<int>(
      context,
      title: title,
      message: tr(
        'booking_form.qty_dialog_hint',
        namedArgs: {'max': '${widget.maxPerType}'},
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(2),
        ],
        style: UgamText.titleXl.copyWith(
          color: UgamColors.of(context).ink,
          fontSize: 28,
        ),
        decoration: const InputDecoration(counterText: '', hintText: '0'),
        onSubmitted: (v) =>
            Navigator.of(context).pop(int.tryParse(v.trim()) ?? current),
      ),
      actions: (ctx) => [
        UgamButton(
          label: tr('booking_form.qty_dialog_cancel'),
          kind: UgamButtonKind.ghost,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
        UgamButton(
          label: tr('booking_form.qty_dialog_set'),
          icon: Icons.check_rounded,
          onPressed: () => Navigator.of(
            ctx,
          ).pop(int.tryParse(controller.text.trim()) ?? current),
        ),
      ],
    );
    controller.dispose();
    if (entered != null) {
      HapticFeedback.selectionClick();
      onSet(entered.clamp(0, widget.maxPerType));
    }
  }

  // ─── SEAT-TYPE / LEG PRESENTATION ─────────────────────────────────────────

  IconData _seatIcon(SeatType t) => switch (t) {
        SeatType.doubleSofa => Icons.king_bed_rounded,
        SeatType.singleSofa => Icons.single_bed_rounded,
        SeatType.seater => Icons.event_seat_rounded,
      };

  String _seatLabel(SeatType t) => switch (t) {
        SeatType.doubleSofa => tr('booking_form.seat_double_sofa_label'),
        SeatType.singleSofa => tr('booking_form.seat_single_sofa_label'),
        SeatType.seater => tr('booking_form.seat_seater_label'),
      };

  String _seatSublabel(SeatType t) => switch (t) {
        SeatType.doubleSofa => tr('booking_form.seat_double_sofa_sub'),
        SeatType.singleSofa => tr('booking_form.seat_single_sofa_sub'),
        SeatType.seater => tr('booking_form.seat_seater_sub'),
      };

  Widget _buildContactMatches(UgamColorSet c) {
    return Container(
      margin: const EdgeInsets.only(top: UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              UgamSpacing.sm,
              UgamSpacing.gutter,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('booking_form.from_contacts'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
            ),
          ),
          for (final u in _contactMatches)
            InkWell(
              onTap: () => _pickContact(u),
              borderRadius: BorderRadius.circular(UgamRadius.input),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.gutter,
                  vertical: UgamSpacing.sm,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.accent.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _contactInitials(u.name),
                        style: UgamText.titleS.copyWith(
                          color: c.accent,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            u.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: UgamText.body.copyWith(
                              color: c.ink,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            u.phone,
                            style: UgamText.tabular(
                              UgamText.caption.copyWith(
                                color: c.ink2,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.north_west_rounded, size: 16, color: c.ink3),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Pickup-point selector. Hidden entirely when the controller isn't
  /// registered or the active list is empty; wrapped in an [Obx] so it appears
  /// on its own once [PickupController.ensureLoaded] resolves. Tapping opens
  /// [_openPickupSheet]. Required only when [BookingCaptureForm.requirePickup]
  /// is set AND a non-empty list exists (see [collect]).
  Widget _buildPickupField(UgamColorSet c) {
    final pickup = _pickup;
    if (pickup == null) return const SizedBox.shrink();
    return Obx(() {
      // Touch an Rx so this rebuilds when the list finishes loading.
      pickup.loadedOnce.value;
      final options = pickup.active;
      if (options.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UgamPickerField(
            label: tr('pickup.form_label'),
            value: _pickupName ?? '',
            placeholder: widget.requirePickup
                ? tr('pickup.form_placeholder_required')
                : tr('pickup.form_placeholder'),
            icon: Icons.place_rounded,
            onTap: _openPickupSheet,
          ),
          if (_pickupError != null) ...[
            const SizedBox(height: UgamSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                _pickupError!,
                style: UgamText.caption.copyWith(color: c.danger),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
        ],
      );
    });
  }
}
