part of '../add_bus_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// Step 3 — Price
// ════════════════════════════════════════════════════════════════════════

enum _PriceMode { fixed, bands }

class _Step3Price extends StatefulWidget {
  final UgamColorSet c;
  final TextEditingController price;
  final TextEditingController busPrice;
  final TextEditingController singleSofaPrice;
  final TextEditingController doubleSofaPrice;

  /// Flexible price bands edited by the agent, owned by the parent state so they
  /// survive step navigation. [onBandsChanged] hands an updated copy back up.
  final List<PriceBand> priceBands;
  final ValueChanged<List<PriceBand>> onBandsChanged;

  /// The layout the band row range clamps against: the saved one when editing
  /// an unchanged bus, otherwise a preview built from the Step 2 inputs (add
  /// mode included). Null only when no grid can be built — e.g. editing a
  /// layout-less bus — which is when `rows_clamped_note` shows.
  final BusLayout? layout;
  final Tour? tour;
  final int totalSeats;
  final VoidCallback onChanged;

  /// Uniform vs per-row pricing, and the bands parked while uniform is active.
  /// Both are owned by the WIZARD, not by this step's State — the step is
  /// disposed every time the agent walks back to Capacity, which used to reset
  /// the chosen tab and bin the stash.
  final _PriceMode mode;
  final ValueChanged<_PriceMode> onModeChanged;
  final List<PriceBand> stashedBands;
  final ValueChanged<List<PriceBand>> onStashBands;
  final bool rentIncludesFuel;
  final ValueChanged<bool> onRentIncludesFuelChanged;

  const _Step3Price({
    required this.c,
    required this.price,
    required this.busPrice,
    required this.singleSofaPrice,
    required this.doubleSofaPrice,
    required this.priceBands,
    required this.onBandsChanged,
    required this.layout,
    required this.tour,
    required this.totalSeats,
    required this.onChanged,
    required this.mode,
    required this.onModeChanged,
    required this.stashedBands,
    required this.onStashBands,
    required this.rentIncludesFuel,
    required this.onRentIncludesFuelChanged,
  });

  @override
  State<_Step3Price> createState() => _Step3PriceState();
}

class _Step3PriceState extends State<_Step3Price> {
  /// Whether this bus uses one uniform price ([_PriceMode.fixed]) or explicit
  /// per-row price bands ([_PriceMode.bands]). Lives on the wizard.
  _PriceMode get _mode => widget.mode;

  /// The per-person base the sofa fields were last auto-seeded from. A later
  /// base change re-seeds a field only while it still equals this base's default
  /// (an untouched auto-value) — any other number is a hand-typed override and
  /// is left alone. Held in state so the check survives this step's rebuilds.
  double _lastBase = 0;

  @override
  void initState() {
    super.initState();
    // Pre-fill any empty sofa field with its base-derived default; a value
    // already present (edit-mode override, or a default seeded before navigating
    // away) is preserved.
    _lastBase = _basePerSeat;
    if (_lastBase > 0) {
      if (singleSofaPrice.text.trim().isEmpty) {
        singleSofaPrice.text = _money(_lastBase);
      }
      if (doubleSofaPrice.text.trim().isEmpty) {
        doubleSofaPrice.text = _money(_lastBase * 2);
      }
    }
  }

  List<PriceBand> get _bands => widget.priceBands;

  /// Hand an updated band list up to the parent and refresh this step.
  void _commitBands(List<PriceBand> next) {
    widget.onBandsChanged(next);
    onChanged();
  }

  void _addBand(PriceBand band) {
    HapticFeedback.selectionClick();
    _commitBands([..._bands, band]);
  }

  void _updateBand(int index, PriceBand band) {
    final next = [..._bands];
    if (index >= 0 && index < next.length) {
      next[index] = band;
      _commitBands(next);
    }
  }

  void _removeBand(int index) {
    HapticFeedback.selectionClick();
    final next = [..._bands]..removeAt(index);
    _commitBands(next);
  }

  UgamColorSet get c => widget.c;
  Tour? get tour => widget.tour;
  TextEditingController get price => widget.price;
  TextEditingController get busPrice => widget.busPrice;
  TextEditingController get singleSofaPrice => widget.singleSofaPrice;
  TextEditingController get doubleSofaPrice => widget.doubleSofaPrice;
  int get totalSeats => widget.totalSeats;
  VoidCallback get onChanged => widget.onChanged;

  /// Row count of the bus, when a layout is known (see [_Step3Price.layout]).
  /// Used to clamp the band row range.
  int? get _rowCount => widget.layout?.rows;

  /// Format a derived rupee value the way the per-seat auto-fill does: whole
  /// numbers print clean, anything else to two decimals.
  static String _money(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// The per-person base the sofa defaults derive from: the typed per-seat
  /// value, falling back to full bus price ÷ total seats.
  double get _basePerSeat {
    final perSeat = double.tryParse(price.text.trim());
    if (perSeat != null && perSeat > 0) return perSeat;
    final bus = double.tryParse(busPrice.text.trim());
    if (bus != null && bus > 0 && totalSeats > 0) return bus / totalSeats;
    return 0;
  }

  /// True while [ctrl] still holds the auto-default for [prevDefault] (or is
  /// empty) — i.e. the agent hasn't typed their own number over it, so a base
  /// change may freely re-seed it. The tolerance absorbs 2-decimal rounding.
  bool _stillAuto(TextEditingController ctrl, double prevDefault) {
    final t = ctrl.text.trim();
    if (t.isEmpty) return true;
    final v = double.tryParse(t);
    return v != null && prevDefault > 0 && (v - prevDefault).abs() < 0.005;
  }

  /// Re-derive the single/double sofa defaults from [newBase] so the agent sees
  /// concrete, editable numbers instead of an empty placeholder. A single sofa
  /// is one berth (= base); a whole double sofa is two berths (= 2 × base),
  /// matching [BusDetails.berthPriceFor], so an untouched default resolves to
  /// exactly what a blank field would. Hand-typed overrides are preserved.
  void _reseedSofaDefaults(double newBase) {
    if (newBase > 0) {
      if (_stillAuto(singleSofaPrice, _lastBase)) {
        singleSofaPrice.text = _money(newBase);
      }
      if (_stillAuto(doubleSofaPrice, _lastBase * 2)) {
        doubleSofaPrice.text = _money(newBase * 2);
      }
    }
    _lastBase = newBase;
  }

  /// When the agent edits the full bus price, auto-fill the per-seat field by
  /// dividing across the total seats, then re-derive the sofa defaults. Setting
  /// the controller text directly does NOT fire those fields' own onChanged, so
  /// each stays a soft default the agent can freely type over.
  void _onBusPriceChanged() {
    final parsed = double.tryParse(busPrice.text.trim());
    if (parsed != null && parsed > 0 && totalSeats > 0) {
      final newBase = parsed / totalSeats;
      price.text = _money(newBase);
      _reseedSofaDefaults(newBase);
    }
    onChanged();
  }

  /// A manual per-seat edit re-bases the (untouched) sofa defaults too.
  void _onPerSeatChanged() {
    _reseedSofaDefaults(_basePerSeat);
    onChanged();
  }

  /// Switch between uniform pricing and explicit price bands. Switching to
  /// "Same for all" stashes any current bands and clears them from the parent
  /// (so _save persists priceBands=[]); switching back restores the stash.
  void _onModeChanged(int i) {
    final next = _PriceMode.values[i];
    if (next == _PriceMode.fixed && widget.priceBands.isNotEmpty) {
      widget.onStashBands(List<PriceBand>.of(widget.priceBands));
      widget.onBandsChanged(const []);
    } else if (next == _PriceMode.bands &&
        widget.priceBands.isEmpty &&
        widget.stashedBands.isNotEmpty) {
      widget.onBandsChanged(List<PriceBand>.of(widget.stashedBands));
    }
    HapticFeedback.selectionClick();
    widget.onModeChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final hint = tour != null && tour!.pricePerSeat > 0
        ? tr(
            'add_bus.hint.price_default',
            namedArgs: {'price': tour!.pricePerSeat.toStringAsFixed(0)},
          )
        : tr('add_bus.hint.price_plain');

    final busPriceParsed = double.tryParse(busPrice.text.trim()) ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const BouncingScrollPhysics(),
      children: [
        _StepIntro(
          c: c,
          title: tr('add_bus.step3.title'),
          body: tr('add_bus.step3.body'),
        ),
        const SizedBox(height: UgamSpacing.xl),
        _moneyInput(
          c,
          label: tr('add_bus.label.bus_price'),
          controller: busPrice,
          hint: tr('add_bus.hint.bus_price'),
          onChanged: (_) => _onBusPriceChanged(),
        ),
        if (busPriceParsed > 0) ...[
          const SizedBox(height: UgamSpacing.md),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: widget.rentIncludesFuel,
            onChanged: widget.onRentIncludesFuelChanged,
            title: Text(
              tr('add_bus.rent_includes_fuel_label'),
              style: UgamText.body.copyWith(color: c.ink),
            ),
            subtitle: Text(
              tr('add_bus.rent_includes_fuel_hint'),
              style: UgamText.caption.copyWith(color: c.ink3),
            ),
          ),
        ],
        // Per-seat price only in "Same for all": under bands every banded row
        // ignores it, so a visible box there invited typing the bus RENT into
        // it — where it silently never became an expense (bus_price stayed 0).
        // The value is kept (not cleared) and still prices any row no band
        // covers; the uncovered-rows warning below says when that happens.
        if (_mode == _PriceMode.fixed) ...[
          const SizedBox(height: UgamSpacing.lg),
          _moneyInput(
            c,
            label: tr('add_bus.label.price_per_seat'),
            controller: price,
            hint: hint,
            onChanged: (_) => _onPerSeatChanged(),
          ),
        ],
        if (_mode == _PriceMode.fixed &&
            busPriceParsed > 0 &&
            totalSeats > 0) ...[
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr(
              'add_bus.per_seat.auto_note',
              namedArgs: {'seats': '$totalSeats'},
            ),
            style: UgamText.caption.copyWith(color: c.ink3, height: 1.4),
          ),
        ],
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: tr('add_bus.price_mode.question')),
        const SizedBox(height: UgamSpacing.sm),
        UgamTabPills(
          items: [
            UgamTabItem(
              label: tr('add_bus.price_mode.same_label'),
              icon: Icons.attach_money_rounded,
            ),
            UgamTabItem(
              label: tr('add_bus.price_mode.bands_label'),
              icon: Icons.tune_rounded,
              count: widget.priceBands.isNotEmpty
                  ? widget.priceBands.length
                  : null,
            ),
          ],
          currentIndex: _mode.index,
          onChanged: _onModeChanged,
        ),
        const SizedBox(height: UgamSpacing.lg),
        AnimatedSize(
          duration: UgamMotion.tab,
          curve: UgamMotion.easeOut,
          alignment: Alignment.topCenter,
          child: _mode == _PriceMode.fixed
              ? _buildFixedBody()
              : _buildBandsBody(),
        ),
        const SizedBox(height: UgamSpacing.xl),
      ],
    );
  }

  /// Uniform-pricing body: the optional per-type single/double sofa overrides.
  Widget _buildFixedBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('add_bus.price_mode.same_body'),
          style: UgamText.caption.copyWith(color: c.ink3, height: 1.4),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _moneyInput(
          c,
          label: tr('add_bus.overrides.single_price'),
          controller: singleSofaPrice,
          hint: tr('add_bus.overrides.defaults_to_base'),
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _moneyInput(
          c,
          label: tr('add_bus.overrides.double_price'),
          controller: doubleSofaPrice,
          hint: tr('add_bus.overrides.defaults_to_base'),
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}
