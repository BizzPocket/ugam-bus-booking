import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_type.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../utils/time_format.dart';

/// 3-step wizard for adding (or editing) a bus on a tour.
///
/// Add mode:  Step 1 → Step 2 → Step 3 (identity → capacity → price)
/// Edit mode: Step 1 → Step 2 → Step 3 (same — capacity is now editable)
///
/// Editing the capacity REGENERATES the seat layout, which renumbers every seat
/// ID. So when the bus already has passengers seated, [_save] warns and clears
/// those seat assignments on this bus (via [TourController.unassignBus] — the
/// people return to "unassigned", request lines intact) before applying the new
/// size. When the capacity isn't touched, the saved layout is reused untouched
/// so seat IDs (and assignments) stay exactly as they were.
///
/// All controller calls (`addBus`, `updateBus`) and the layout-generation
/// math are preserved bit-for-bit from the legacy single-page form — only
/// the presentation is rebuilt.
class AddBusScreen extends StatefulWidget {
  final String tourId;
  final Bus? existing;

  const AddBusScreen({super.key, required this.tourId, this.existing});

  bool get isEditing => existing != null;

  @override
  State<AddBusScreen> createState() => _AddBusScreenState();
}

class _AddBusScreenState extends State<AddBusScreen> {
  // ── Form state (1:1 with the legacy screen) ─────────────────────────
  final _slotLabel = TextEditingController();
  final _busNumber = TextEditingController();
  final _boardingPoint = TextEditingController();
  final _driverName = TextEditingController();
  final _driverPhone = TextEditingController();
  final _price = TextEditingController();
  final _busPrice = TextEditingController();
  final _singleSofaPrice = TextEditingController();
  final _doubleSofaPrice = TextEditingController();
  final _rearRows = TextEditingController();
  final _rearPrice = TextEditingController();

  /// Per-bus departure time. Stored as a [TimeOfDay] while editing the form and
  /// serialized to canonical 'HH:mm' (via [hhmmFromTimeOfDay]) on save.
  TimeOfDay? _departureTime;

  /// Flexible, named price bands for this bus (front premium, back discount,
  /// or any explicit row range). Edited via the Step 3 "Price bands"
  /// sub-section; serialized onto the Bus at save time.
  List<PriceBand> _priceBands = const [];
  bool _isAC = true;
  int _totalSeats = 40;
  // Every bus is a sleeper coach — no seater/mixed types in this app.
  static const BusType _busType = BusType.sleeper;
  int _singleSofaCount = 0;
  bool _hasBalcony = false;
  bool _saving = false;
  bool _priceInitialized = false;

  /// Capacity values as first shown when EDITING an existing bus (derived from
  /// its saved layout in [initState]). Used to detect whether the admin actually
  /// touched the capacity, so a plain field edit (driver, price, …) never
  /// regenerates the layout or threatens existing seat assignments.
  int _initTotalSeats = 40;
  int _initSingleSofaCount = 0;
  bool _initHasBalcony = false;

  // ── Wizard state ────────────────────────────────────────────────────
  /// 0 = identity, 1 = capacity (add only), 2 = price.
  /// In edit mode the user moves from 0 → 2 directly (step 1 is skipped).
  int _currentStep = 0;

  /// Steps the wizard actually walks through, in order. Capacity (step 1) is now
  /// included in edit mode too, so an admin can resize an existing bus.
  List<int> get _stepSequence => const [0, 1, 2];

  int get _indexInSequence => _stepSequence.indexOf(_currentStep);
  bool get _isFirstStep => _indexInSequence == 0;
  bool get _isLastStep => _indexInSequence == _stepSequence.length - 1;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _slotLabel.text = e.name;
      _busNumber.text = e.busNumber;
      _boardingPoint.text = e.boardingPoint;
      _departureTime = timeOfDayFromHhmm(e.departureTime);
      _driverName.text = e.driverName;
      _driverPhone.text = e.driverPhone;
      _price.text = e.pricePerSeat > 0 ? e.pricePerSeat.toStringAsFixed(0) : '';
      if (e.busPrice > 0) {
        _busPrice.text = e.busPrice.toStringAsFixed(0);
      }
      if (e.singleSofaPrice != null) {
        _singleSofaPrice.text = e.singleSofaPrice!.toStringAsFixed(0);
      }
      if (e.doubleSofaPrice != null) {
        _doubleSofaPrice.text = e.doubleSofaPrice!.toStringAsFixed(0);
      }
      if (e.rearRows > 0) {
        _rearRows.text = '${e.rearRows}';
      }
      if (e.rearPrice != null) {
        _rearPrice.text = e.rearPrice!.toStringAsFixed(0);
      }
      _priceBands = List<PriceBand>.from(e.priceBands);
      _isAC = e.isAC;
      _seedCapacityFromLayout(e);
      _priceInitialized = true;
    }
  }

  /// Reconstruct the capacity-step inputs from a saved bus so EDIT mode shows the
  /// bus's current size. The toggle balcony adds a 2-berth aisle pair on top, so
  /// it shows as exactly two aisle cells; a single relocated "orphan" berth shows
  /// as one. `totalSeats` for the stepper is the sleeper berths EXCLUDING that
  /// toggle pair (matching what [BusLayout.generate] expects as its `totalSeats`).
  /// The derived values are snapshotted so [_save] can tell whether the admin
  /// actually changed the capacity.
  void _seedCapacityFromLayout(Bus e) {
    final layout = e.layout;
    if (layout != null) {
      final balconyAisle = layout.grid.where((cl) => cl.isBalconyAisle).length;
      _hasBalcony = balconyAisle >= 2;
      _singleSofaCount = layout.grid
          .where((cl) =>
              cl.hasSeat &&
              cl.seatType == SeatType.singleSofa &&
              (cl.col == SeatGridCols.singleUpper ||
                  cl.col == SeatGridCols.singleLower))
          .length;
      _totalSeats =
          (layout.totalSeats - (_hasBalcony ? 2 : 0)).clamp(1, 100);
    } else {
      _totalSeats = e.totalSeats;
    }
    _initTotalSeats = _totalSeats;
    _initSingleSofaCount = _singleSofaCount;
    _initHasBalcony = _hasBalcony;
  }

  @override
  void dispose() {
    _slotLabel.dispose();
    _busNumber.dispose();
    _boardingPoint.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    _price.dispose();
    _busPrice.dispose();
    _singleSofaPrice.dispose();
    _doubleSofaPrice.dispose();
    _rearRows.dispose();
    _rearPrice.dispose();
    super.dispose();
  }

  TourController get _tourCtrl => Get.find<TourController>();
  Tour? get _tour => _tourCtrl.getTour(widget.tourId);

  /// Positional slot label ("Bus N") — the bus's order within its tour. Used as
  /// a read-only badge and as the fallback name when the agent leaves the name
  /// field blank. Computed, never stored, so it stays correct as buses change.
  String get _slotPositionLabel {
    final tour = _tour;
    if (tour == null) {
      return tr('add_bus.slot_position', namedArgs: {'n': '1'});
    }
    final e = widget.existing;
    if (e != null) {
      final idx = tour.buses.indexWhere((b) => b.id == e.id);
      return tr(
        'add_bus.slot_position',
        namedArgs: {'n': '${(idx < 0 ? tour.buses.length : idx) + 1}'},
      );
    }
    return tr(
      'add_bus.slot_position',
      namedArgs: {'n': '${tour.buses.length + 1}'},
    );
  }

  // Always a full sleeper coach now, so every seat is a sleeper berth.
  int get _sleeperSeats => _totalSeats;

  /// Distinct passengers currently holding at least one seat on the bus being
  /// edited (0 in add mode). Drives the resize warning banner and the
  /// clear-on-resize confirm flow.
  int get _seatedOnThisBus {
    final e = widget.existing;
    final tour = _tour;
    if (e == null || tour == null) return 0;
    return tour.passengers
        .where((p) => p.assignedSeats.any((a) => a.busId == e.id))
        .length;
  }

  /// True when the admin has changed any capacity value from what the edited bus
  /// started with — so the layout (and seat IDs) will be regenerated on save.
  bool get _capacityChanged =>
      widget.isEditing &&
      (_totalSeats != _initTotalSeats ||
          _singleSofaCount != _initSingleSofaCount ||
          _hasBalcony != _initHasBalcony);

  /// The layout the price step previews its rear-zone / price-band rows against:
  /// the freshly-sized layout when editing and capacity was changed, otherwise
  /// the bus's saved layout. Keeps the band editor's row range in sync with a
  /// just-changed seat count.
  BusLayout? get _previewLayout {
    if (!widget.isEditing) return null;
    if (!_capacityChanged) return widget.existing?.layout;
    return BusLayout.generate(
      busType: _busType,
      totalSeats: _totalSeats,
      seaterCount: 0,
      singleSofaCount: _singleSofaCount,
      hasBalcony: _hasBalcony,
    );
  }

  String get _subtitle {
    final tour = _tour;
    if (tour == null) return '';
    final label = _slotLabel.text.trim().isEmpty
        ? _slotPositionLabel
        : _slotLabel.text.trim();
    return '${tour.title} · $label';
  }

  void _maybeSeedPrice() {
    if (_priceInitialized) return;
    final tour = _tour;
    if (tour == null) return;
    if (tour.pricePerSeat > 0) {
      _price.text = tour.pricePerSeat.toStringAsFixed(0);
    }
    _priceInitialized = true;
  }

  /// Berths left for doubles after the singles; odd means one spare berth that
  /// can't pair into a whole double sofa.
  int get _doubleBerths => _sleeperSeats - _singleSofaCount;
  bool get _hasOddSleeperBerth => _doubleBerths.isOdd;

  String get _singleSofaSummary {
    // Two berths per double sofa, so the leftover berths pair up 2-for-1.
    final doubleCount = _doubleBerths ~/ 2;
    final summaryKey = _singleSofaCount == 1
        ? 'add_bus.summary.single_sofa_summary_one'
        : 'add_bus.summary.single_sofa_summary_other';
    final doubleLabel = doubleCount == 1
        ? tr('add_bus.summary.double_sofa')
        : tr('add_bus.summary.double_sofas');
    return tr(
      summaryKey,
      namedArgs: {
        'single': '$_singleSofaCount',
        'double': '$doubleCount',
        'double_label': doubleLabel,
      },
    );
  }

  // ── Navigation ──────────────────────────────────────────────────────

  void _goNext() {
    HapticFeedback.selectionClick();
    final idx = _indexInSequence;
    if (idx < _stepSequence.length - 1) {
      setState(() => _currentStep = _stepSequence[idx + 1]);
    }
  }

  void _goBack() {
    HapticFeedback.selectionClick();
    final idx = _indexInSequence;
    if (idx > 0) {
      setState(() => _currentStep = _stepSequence[idx - 1]);
    } else {
      Get.back();
    }
  }

  /// True when more single sofas were requested than there are sleeper berths.
  /// Surfaced inline under the single-sofa stepper and blocks advancing.
  bool get _singleSofaInvalid => _singleSofaCount > _sleeperSeats;

  bool get _canAdvance {
    switch (_currentStep) {
      case 0:
        // Identity has no hard-required field — bus number is optional and can
        // be filled in later when the owner confirms the vehicle.
        return true;
      case 1:
        // Capacity advances only when the layout is buildable. The invalid
        // state is shown inline under the single-sofa stepper.
        return !_singleSofaInvalid;
      case 2:
        return true;
    }
    return false;
  }

  /// Pick this bus's departure time. Mirrors the tour-level time picker — the
  /// chosen [TimeOfDay] is held in [_departureTime] and serialized to canonical
  /// 'HH:mm' at save time.
  Future<void> _pickDepartureTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _departureTime ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked != null) {
      setState(() => _departureTime = picked);
    }
  }

  // ── Save ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!widget.isEditing) {
      // Layout-buildability is enforced inline on Step 2 (see _canAdvance);
      // these guards are a final safety net and surface no toast.
      if (_singleSofaInvalid) return;
    }

    final tour = _tour;
    if (tour == null) {
      AppSnackBar.error(tr('add_bus.snackbar.error_tour_not_found'));
      return;
    }

    final priceText = _price.text.trim();
    final pricePerSeat = priceText.isEmpty
        ? tour.pricePerSeat
        : (double.tryParse(priceText) ?? tour.pricePerSeat);

    // Full bus rent paid to the owner — auto-counted as a busOwner expense.
    final busPrice = double.tryParse(_busPrice.text.trim()) ?? 0;
    final boardingPoint = _boardingPoint.text.trim();

    double? parseOpt(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : double.tryParse(t);
    }

    final singleSofaPrice = parseOpt(_singleSofaPrice);
    final doubleSofaPrice = parseOpt(_doubleSofaPrice);

    // Rear-zone: how many of the LAST rows are priced differently, and at what
    // per-person rate. Clamped to the layout's row count below (different per
    // branch — edit reuses the saved layout, add uses the freshly built one).
    final rearRowsRaw = int.tryParse(_rearRows.text.trim()) ?? 0;
    final rearPrice = rearRowsRaw <= 0 ? null : parseOpt(_rearPrice);

    final slotLabel = _slotLabel.text.trim().isEmpty
        ? _slotPositionLabel
        : _slotLabel.text.trim();

    setState(() => _saving = true);
    try {
      if (widget.isEditing) {
        final source = widget.existing!;

        // A plain field edit (driver, price, …) reuses the saved layout
        // untouched, so seat IDs — and every existing seat assignment — stay
        // exactly as they were. Only a touched capacity regenerates the layout.
        final newLayout = _capacityChanged
            ? BusLayout.generate(
                busType: _busType,
                totalSeats: _totalSeats,
                seaterCount: 0,
                singleSofaCount: _singleSofaCount,
                hasBalcony: _hasBalcony,
              )
            : source.layout;

        // A real resize renumbers the seat IDs, so anyone seated on this bus
        // would be orphaned. Confirm-then-clear those assignments first.
        final oldIds = source.layout?.allSeatIds.toSet() ?? <String>{};
        final newIds = newLayout?.allSeatIds.toSet() ?? <String>{};
        final structuralChange = _capacityChanged &&
            (oldIds.length != newIds.length || !oldIds.containsAll(newIds));

        final seated = _seatedOnThisBus;
        if (structuralChange && seated > 0) {
          final ok = await UgamDialog.confirm(
            context,
            title: tr('add_bus.resize_confirm_title'),
            message: tr(
              'add_bus.resize_confirm_msg',
              namedArgs: {'count': '$seated'},
            ),
            confirmLabel: tr('add_bus.resize_confirm_cta'),
            destructive: true,
          );
          if (ok != true) {
            if (mounted) setState(() => _saving = false);
            return;
          }
          // Frees every seat on this bus; the passengers' request lines stay
          // intact so they reappear as needing assignment and can be re-seated.
          await _tourCtrl.unassignBus(widget.tourId, source.id);
        }

        final rowCount = newLayout?.rows ?? rearRowsRaw;
        final rearRows = rearRowsRaw.clamp(0, rowCount);
        final updated = source.copyWith(
          name: slotLabel,
          busNumber: _busNumber.text.trim(),
          boardingPoint: boardingPoint,
          departureTime: _departureTime != null
              ? hhmmFromTimeOfDay(_departureTime!)
              : null,
          driverName: _driverName.text.trim(),
          driverPhone: _driverPhone.text.trim(),
          isAC: _isAC,
          pricePerSeat: pricePerSeat,
          busPrice: busPrice,
          singleSofaPrice: singleSofaPrice,
          doubleSofaPrice: doubleSofaPrice,
          rearRows: rearRows,
          rearPrice: rearRows == 0 ? null : rearPrice,
          priceBands: _sanitizedBands(rowCount),
          layout: newLayout,
          totalSeatsLegacy: structuralChange ? _totalSeats : null,
        );
        await _tourCtrl.updateBus(widget.tourId, updated);
        if (!mounted) return;
        AppSnackBar.success(
          tr('add_bus.snackbar.updated', namedArgs: {'name': updated.name}),
        );
        Get.back();
        return;
      }

      final layout = BusLayout.generate(
        busType: _busType,
        totalSeats: _totalSeats,
        seaterCount: 0,
        singleSofaCount: _singleSofaCount,
        hasBalcony: _hasBalcony,
      );

      final rearRows = rearRowsRaw.clamp(0, layout.rows);

      final bus = Bus(
        name: slotLabel,
        busNumber: _busNumber.text.trim(),
        boardingPoint: boardingPoint,
        departureTime: _departureTime != null
            ? hhmmFromTimeOfDay(_departureTime!)
            : null,
        driverName: _driverName.text.trim(),
        driverPhone: _driverPhone.text.trim(),
        isAC: _isAC,
        busType: _busType.displayName,
        totalSeatsLegacy: _totalSeats,
        pricePerSeat: pricePerSeat,
        busPrice: busPrice,
        singleSofaPrice: singleSofaPrice,
        doubleSofaPrice: doubleSofaPrice,
        rearRows: rearRows,
        rearPrice: rearRows == 0 ? null : rearPrice,
        priceBands: _sanitizedBands(layout.rows),
        layout: layout,
      );

      await _tourCtrl.addBus(widget.tourId, bus);
      if (!mounted) return;
      AppSnackBar.success(
        tr('add_bus.snackbar.added', namedArgs: {'name': bus.name}),
      );
      Get.back();
    } catch (_) {
      AppSnackBar.error(tr('add_bus.snackbar.error_save'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Clean the edited bands for persistence: drop bands with no price, normalise
  /// each range (fromRow <= toRow) and clamp both ends to the bus's [rowCount]
  /// so an out-of-range band can never silently shadow nothing.
  List<PriceBand> _sanitizedBands(int rowCount) {
    final maxRow = (rowCount - 1).clamp(0, 1 << 30);
    final out = <PriceBand>[];
    for (final b in _priceBands) {
      if (b.price <= 0) continue;
      var lo = b.fromRow <= b.toRow ? b.fromRow : b.toRow;
      var hi = b.fromRow <= b.toRow ? b.toRow : b.fromRow;
      lo = lo.clamp(0, maxRow);
      hi = hi.clamp(0, maxRow);
      out.add(b.copyWith(fromRow: lo, toRow: hi));
    }
    return out;
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _maybeSeedPrice();
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            _WizardHeader(
              c: c,
              title: widget.isEditing
                  ? tr('add_bus.title_edit')
                  : tr('add_bus.title'),
              subtitle: _subtitle,
              steps: _stepSequence.length,
              index: _indexInSequence,
              onBack: _goBack,
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: UgamMotion.easeOut,
                switchOutCurve: UgamMotion.easeIn,
                transitionBuilder: (child, anim) {
                  final slide = Tween<Offset>(
                    begin: const Offset(0.05, 0),
                    end: Offset.zero,
                  ).animate(anim);
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(position: slide, child: child),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey(_currentStep),
                  child: _buildStep(c),
                ),
              ),
            ),
            _BottomBar(
              c: c,
              isFirst: _isFirstStep,
              isLast: _isLastStep,
              canAdvance: _canAdvance,
              saving: _saving,
              onBack: _goBack,
              onNext: _isLastStep ? _save : _goNext,
              isEditing: widget.isEditing,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(UgamColorSet c) {
    switch (_currentStep) {
      case 0:
        return _Step1Identity(
          c: c,
          busName: _slotLabel,
          busNumber: _busNumber,
          boardingPoint: _boardingPoint,
          departureTime: _departureTime,
          driverName: _driverName,
          driverPhone: _driverPhone,
          isAC: _isAC,
          slotBadge: _slotPositionLabel,
          onToggleAC: (v) => setState(() => _isAC = v),
          onPickDepartureTime: _pickDepartureTime,
          onAnyChange: () => setState(() {}),
        );
      case 1:
        return _Step2Capacity(
          c: c,
          totalSeats: _totalSeats,
          singleSofaCount: _singleSofaCount,
          sleeperSeats: _sleeperSeats,
          singleSofaSummary: _singleSofaSummary,
          hasOddSleeperBerth: _hasOddSleeperBerth,
          hasBalcony: _hasBalcony,
          // Edit mode only: warn that resizing will unassign the people already
          // seated on this bus (their seat IDs change when the layout rebuilds).
          seatedWarning: (widget.isEditing && _seatedOnThisBus > 0)
              ? tr(
                  'add_bus.resize_warning',
                  namedArgs: {'count': '$_seatedOnThisBus'},
                )
              : null,
          singleSofaError: _singleSofaInvalid
              ? tr('add_bus.snackbar.error_single_sofa')
              : null,
          onTotalSeats: (v) => setState(() {
            _totalSeats = v;
            if (_singleSofaCount > _sleeperSeats) {
              _singleSofaCount = _sleeperSeats;
            }
          }),
          onSingleSofa: (v) => setState(() => _singleSofaCount = v),
          onBalcony: (v) => setState(() => _hasBalcony = v),
        );
      case 2:
      default:
        return _Step3Price(
          c: c,
          price: _price,
          busPrice: _busPrice,
          singleSofaPrice: _singleSofaPrice,
          doubleSofaPrice: _doubleSofaPrice,
          rearRows: _rearRows,
          rearPrice: _rearPrice,
          priceBands: _priceBands,
          onBandsChanged: (bands) => setState(() => _priceBands = bands),
          layout: _previewLayout,
          tour: _tour,
          slotLabel: _slotLabel.text.trim().isEmpty
              ? _slotPositionLabel
              : _slotLabel.text.trim(),
          busNumber: _busNumber.text.trim(),
          isAC: _isAC,
          totalSeats: _totalSeats,
          onChanged: () => setState(() {}),
        );
    }
  }
}

// ════════════════════════════════════════════════════════════════════════
// Header — back chevron + title + step dots
// ════════════════════════════════════════════════════════════════════════

class _WizardHeader extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String subtitle;
  final int steps;
  final int index;
  final VoidCallback onBack;

  const _WizardHeader({
    required this.c,
    required this.title,
    required this.subtitle,
    required this.steps,
    required this.index,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.md,
        UgamSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    index == 0
                        ? Icons.arrow_back_rounded
                        : Icons.chevron_left_rounded,
                    size: 21,
                    color: c.ink,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: UgamText.titleL.copyWith(color: c.ink)),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: UgamText.caption.copyWith(color: c.ink2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Text(
                tr(
                  'add_bus.step_progress',
                  namedArgs: {'current': '${index + 1}', 'total': '$steps'},
                ),
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3, fontSize: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: List.generate(steps, (i) {
              final active = i == index;
              final done = i < index;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == steps - 1 ? 0 : 6),
                  child: AnimatedContainer(
                    duration: UgamMotion.tab,
                    curve: UgamMotion.easeOut,
                    height: 4,
                    decoration: BoxDecoration(
                      color: active || done ? c.accent : c.cardElev,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Bottom bar — Back pill + Next/Save CTA
// ════════════════════════════════════════════════════════════════════════

class _BottomBar extends StatelessWidget {
  final UgamColorSet c;
  final bool isFirst;
  final bool isLast;
  final bool canAdvance;
  final bool saving;
  final bool isEditing;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const _BottomBar({
    required this.c,
    required this.isFirst,
    required this.isLast,
    required this.canAdvance,
    required this.saving,
    required this.isEditing,
    required this.onBack,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final ctaLabel = isLast
        ? (saving
              ? tr('add_bus.action.saving')
              : (isEditing
                    ? tr('add_bus.action.save_changes')
                    : tr('add_bus.action.save')))
        : tr('app.action.next');
    final ctaIcon = isLast
        ? (isEditing ? Icons.check_rounded : Icons.add_rounded)
        : Icons.arrow_forward_rounded;

    return UgamStickyCTA(
      child: Row(
        children: [
          if (!isFirst) ...[
            _BackPill(c: c, onTap: onBack),
            const SizedBox(width: UgamSpacing.md),
          ],
          Expanded(
            child: UgamCTA(
              label: ctaLabel,
              leadingIcon: ctaIcon,
              loading: saving,
              onPressed: canAdvance ? onNext : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _BackPill extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _BackPill({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.lg + 2,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chevron_left_rounded, size: 18, color: c.ink),
            const SizedBox(width: 4),
            Text(
              tr('app.action.back'),
              style: UgamText.titleS.copyWith(color: c.ink),
            ),
          ],
        ),
      ),
    );
  }
}

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
        _StepIntro(
          c: c,
          eyebrow: tr('add_bus.step1.eyebrow'),
          title: tr('add_bus.step1.title'),
          body: tr('add_bus.step1.body', namedArgs: {'slot': slotBadge}),
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: tr('add_bus.label.slot')),
        const SizedBox(height: UgamSpacing.sm),
        _SlotBadge(c: c, label: slotBadge),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.bus_name')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: busName,
          hint: tr('add_bus.hint.bus_name'),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.bus_number')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: busNumber,
          hint: tr('add_bus.hint.bus_number_plain'),
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.boarding_point')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: boardingPoint,
          hint: tr('add_bus.hint.boarding_point'),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.departure_time')),
        const SizedBox(height: UgamSpacing.sm),
        _TimeField(
          c: c,
          hint: tr('add_bus.hint.departure_time'),
          time: departureTime,
          onTap: onPickDepartureTime,
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.driver_name')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: driverName,
          hint: tr('add_bus.hint.driver_name_plain'),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.driver_phone')),
        const SizedBox(height: UgamSpacing.sm),
        UgamPhoneInput(controller: driverPhone),
        const SizedBox(height: UgamSpacing.lg),
        _ACToggle(c: c, value: isAC, onChanged: onToggleAC),
        const SizedBox(height: UgamSpacing.xl),
      ],
    );
  }
}

class _ACToggle extends StatelessWidget {
  final UgamColorSet c;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ACToggle({
    required this.c,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: value ? c.accentFill : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.ac_unit_rounded,
                size: 18,
                color: value ? c.accent : c.ink3,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('add_bus.ac_toggle.label'),
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    value
                        ? tr('add_bus.ac_toggle.on')
                        : tr('add_bus.ac_toggle.off'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            // No per-switch colour overrides — the global SwitchTheme already
            // renders a white thumb on the accent track. Overriding the thumb
            // to accent made it orange-on-orange (a solid pill, no visible
            // thumb).
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Step 2 — Capacity & layout
// ════════════════════════════════════════════════════════════════════════

class _Step2Capacity extends StatelessWidget {
  final UgamColorSet c;
  final int totalSeats;
  final int singleSofaCount;
  final int sleeperSeats;
  final String singleSofaSummary;
  final bool hasOddSleeperBerth;
  final bool hasBalcony;

  /// Inline validation caption shown under the single-sofa stepper, or null
  /// when the value is valid. Replaces the legacy save-time toast.
  final String? singleSofaError;

  /// Edit-mode resize warning shown above the controls when the bus already has
  /// passengers seated — changing the size will unassign them. Null hides it.
  final String? seatedWarning;
  final ValueChanged<int> onTotalSeats;
  final ValueChanged<int> onSingleSofa;
  final ValueChanged<bool> onBalcony;

  const _Step2Capacity({
    required this.c,
    required this.totalSeats,
    required this.singleSofaCount,
    required this.sleeperSeats,
    required this.singleSofaSummary,
    required this.hasOddSleeperBerth,
    required this.hasBalcony,
    this.singleSofaError,
    this.seatedWarning,
    required this.onTotalSeats,
    required this.onSingleSofa,
    required this.onBalcony,
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
        _StepIntro(
          c: c,
          eyebrow: tr('add_bus.step2.eyebrow'),
          title: tr('add_bus.step2.title'),
          body: tr('add_bus.step2.body'),
        ),
        if (seatedWarning != null) ...[
          const SizedBox(height: UgamSpacing.lg),
          _ResizeWarning(c: c, text: seatedWarning!),
        ],
        const SizedBox(height: UgamSpacing.xl),
        // Every bus in this app is a sleeper coach, so there's no bus-type
        // picker — the layout is always sleeper berths (single + double sofa).
        _Label(c: c, text: tr('add_bus.label.total_seats')),
        const SizedBox(height: UgamSpacing.sm),
        _StepperRow(
          c: c,
          value: totalSeats,
          min: 1,
          max: 100,
          onChanged: onTotalSeats,
        ),
        if (sleeperSeats > 0) ...[
          const SizedBox(height: UgamSpacing.xl),
          _Label(c: c, text: tr('add_bus.label.single_sofa_count')),
          const SizedBox(height: UgamSpacing.sm),
          _StepperRow(
            c: c,
            value: singleSofaCount,
            min: 0,
            max: sleeperSeats,
            onChanged: onSingleSofa,
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            singleSofaSummary,
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          if (singleSofaError != null) ...[
            const SizedBox(height: UgamSpacing.xs),
            _InlineError(c: c, text: singleSofaError!),
          ],
          if (hasOddSleeperBerth) ...[
            const SizedBox(height: UgamSpacing.sm),
            _OddBerthWarning(c: c),
          ],
          const SizedBox(height: UgamSpacing.xl),
          _Label(c: c, text: tr('add_bus.label.back_row_balcony')),
          const SizedBox(height: UgamSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.lg,
              vertical: UgamSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(UgamRadius.row),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('add_bus.balcony_body'),
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Switch(value: hasBalcony, onChanged: onBalcony),
              ],
            ),
          ),
        ],
        const SizedBox(height: UgamSpacing.xl),
      ],
    );
  }
}

/// Edit-mode caution shown above the capacity controls when the bus already has
/// passengers seated: resizing renumbers the seats, so those people will be
/// unassigned (and returned to the pool) if the admin changes the size.
class _ResizeWarning extends StatelessWidget {
  final UgamColorSet c;
  final String text;

  const _ResizeWarning({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.warm.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the sleeper berths left for doubles is odd — one berth can't pair
/// into a whole double sofa, so it's placed as an extra single sofa.
class _OddBerthWarning extends StatelessWidget {
  final UgamColorSet c;

  const _OddBerthWarning({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.warm.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr('add_bus.odd_berth_warning'),
              style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  final UgamColorSet c;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _StepperRow({
    required this.c,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          _StepperBtn(
            c: c,
            icon: Icons.remove_rounded,
            enabled: value > min,
            onTap: () => onChanged(value - 1),
          ),
          Expanded(
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: UgamText.tabular(
                UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
              ),
            ),
          ),
          _StepperBtn(
            c: c,
            icon: Icons.add_rounded,
            enabled: value < max,
            onTap: () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }
}

class _StepperBtn extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperBtn({
    required this.c,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56,
        height: 56,
        alignment: Alignment.center,
        child: Icon(icon, size: 20, color: enabled ? c.ink : c.ink3),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Step 3 — Price + preview
// ════════════════════════════════════════════════════════════════════════

class _Step3Price extends StatefulWidget {
  final UgamColorSet c;
  final TextEditingController price;
  final TextEditingController busPrice;
  final TextEditingController singleSofaPrice;
  final TextEditingController doubleSofaPrice;
  final TextEditingController rearRows;
  final TextEditingController rearPrice;

  /// Flexible price bands edited by the agent, owned by the parent state so they
  /// survive step navigation. [onBandsChanged] hands an updated copy back up.
  final List<PriceBand> priceBands;
  final ValueChanged<List<PriceBand>> onBandsChanged;

  /// The saved layout (edit mode). Null in add mode — the layout is only built
  /// at save time there, so the rear-zone row count can't be clamped/previewed
  /// against a concrete grid until then.
  final BusLayout? layout;
  final Tour? tour;
  final String slotLabel;
  final String busNumber;
  final bool isAC;
  final int totalSeats;
  final VoidCallback onChanged;

  const _Step3Price({
    required this.c,
    required this.price,
    required this.busPrice,
    required this.singleSofaPrice,
    required this.doubleSofaPrice,
    required this.rearRows,
    required this.rearPrice,
    required this.priceBands,
    required this.onBandsChanged,
    required this.layout,
    required this.tour,
    required this.slotLabel,
    required this.busNumber,
    required this.isAC,
    required this.totalSeats,
    required this.onChanged,
  });

  @override
  State<_Step3Price> createState() => _Step3PriceState();
}

class _Step3PriceState extends State<_Step3Price> {
  late bool _overridesOpen;
  late bool _bandsOpen;

  @override
  void initState() {
    super.initState();
    // Auto-expand the per-type overrides if any are already set (edit mode).
    _overridesOpen =
        widget.singleSofaPrice.text.trim().isNotEmpty ||
        widget.doubleSofaPrice.text.trim().isNotEmpty;
    // Auto-expand price bands when the bus already carries some.
    _bandsOpen = widget.priceBands.isNotEmpty;
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
  TextEditingController get rearRows => widget.rearRows;
  TextEditingController get rearPrice => widget.rearPrice;
  String get slotLabel => widget.slotLabel;
  String get busNumber => widget.busNumber;
  bool get isAC => widget.isAC;
  int get totalSeats => widget.totalSeats;
  VoidCallback get onChanged => widget.onChanged;

  /// Row count of the bus, when known (edit mode). Used to clamp the rear-zone
  /// input and label the highlight legend. Null in add mode.
  int? get _rowCount => widget.layout?.rows;

  /// Rear-zone rows currently entered, clamped to the known row count.
  int get _rearRowsValue {
    final raw = int.tryParse(rearRows.text.trim()) ?? 0;
    if (raw <= 0) return 0;
    final rows = _rowCount;
    return rows == null ? raw : raw.clamp(0, rows);
  }

  double get _parsedPrice {
    final raw = price.text.trim();
    if (raw.isEmpty) return tour?.pricePerSeat ?? 0;
    return double.tryParse(raw) ?? tour?.pricePerSeat ?? 0;
  }

  String _formatINR(double value) {
    if (value >= 100000) {
      final lakhs = value / 100000;
      return lakhs == lakhs.roundToDouble()
          ? '₹${lakhs.toInt()}L'
          : '₹${lakhs.toStringAsFixed(2)}L';
    }
    if (value >= 1000) {
      final k = value / 1000;
      return k == k.roundToDouble()
          ? '₹${k.toInt()}K'
          : '₹${k.toStringAsFixed(1)}K';
    }
    return '₹${value.toInt()}';
  }

  @override
  Widget build(BuildContext context) {
    final per = _parsedPrice;
    final ifFull = per * totalSeats;
    final hint = tour != null && tour!.pricePerSeat > 0
        ? tr(
            'add_bus.hint.price_default',
            namedArgs: {'price': tour!.pricePerSeat.toStringAsFixed(0)},
          )
        : tr('add_bus.hint.price_plain');

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
          eyebrow: tr('add_bus.step3.eyebrow'),
          title: tr('add_bus.step3.title'),
          body: tr('add_bus.step3.body'),
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: tr('add_bus.label.price_per_seat')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: price,
          hint: hint,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: '₹',
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.bus_price')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: busPrice,
          hint: tr('add_bus.hint.bus_price'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: '₹',
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: UgamSpacing.xl),
        _buildRearZone(),
        const SizedBox(height: UgamSpacing.xl),
        _buildBandsSection(),
        const SizedBox(height: UgamSpacing.xl),
        _buildOverridesSection(),
        const SizedBox(height: UgamSpacing.xl),
        Container(
          padding: const EdgeInsets.all(UgamSpacing.lg),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.card),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('add_bus.preview.eyebrow'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
              const SizedBox(height: UgamSpacing.sm),
              Text(slotLabel, style: UgamText.titleM.copyWith(color: c.ink)),
              const SizedBox(height: 2),
              Text(
                [
                  if (busNumber.isNotEmpty) busNumber,
                  isAC ? tr('add_bus.ac') : tr('add_bus.non_ac'),
                  tr('add_bus.seats_count', namedArgs: {'count': '$totalSeats'}),
                ].join(' · '),
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
              const SizedBox(height: UgamSpacing.lg),
              Container(
                padding: const EdgeInsets.all(UgamSpacing.md),
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calculate_rounded, size: 18, color: c.accent),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        tr(
                          'add_bus.preview.seats_times_price',
                          namedArgs: {
                            'count': '$totalSeats',
                            'price': per.toStringAsFixed(0),
                          },
                        ),
                        style: UgamText.bodyStrong.copyWith(
                          color: c.ink,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '= ${_formatINR(ifFull)}',
                      style: UgamText.tabular(
                        UgamText.titleS.copyWith(color: c.accent, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                tr('add_bus.preview.if_fully_booked'),
                style: UgamText.caption.copyWith(color: c.ink3, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Rear-zone pricing group: how many of the LAST rows are priced differently,
  /// and the per-person price for them. The price field only appears once the
  /// row count is > 0. In edit mode (where the layout is known) the rear rows
  /// are highlighted in a legend so the agent sees exactly which seats apply.
  Widget _buildRearZone() {
    final rearRows = _rearRowsValue;
    final rowCount = _rowCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepIntro(
          c: c,
          eyebrow: tr('add_bus.section.rear_zone_eyebrow'),
          title: tr('add_bus.section.rear_zone_title'),
          body: tr('add_bus.section.rear_zone_body'),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: tr('add_bus.label.rear_rows')),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: this.rearRows,
          hint: rowCount == null
              ? tr('add_bus.hint.rear_rows')
              : tr(
                  'add_bus.hint.rear_rows_max',
                  namedArgs: {'max': '$rowCount'},
                ),
          keyboardType: const TextInputType.numberWithOptions(decimal: false),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
          ],
          onChanged: (_) => onChanged(),
        ),
        AnimatedSize(
          duration: UgamMotion.tab,
          curve: UgamMotion.easeOut,
          alignment: Alignment.topCenter,
          child: rearRows > 0
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: UgamSpacing.lg),
                    _Label(c: c, text: tr('add_bus.label.rear_price')),
                    const SizedBox(height: UgamSpacing.sm),
                    _Field(
                      c: c,
                      controller: rearPrice,
                      hint: tr('add_bus.hint.rear_price'),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      prefix: '₹',
                      onChanged: (_) => onChanged(),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    _RearZoneLegend(
                      c: c,
                      rearRows: rearRows,
                      layout: widget.layout,
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Collapsible "Price bands" sub-section. Lets the agent add named bands —
  /// a premium front range, a discounted back range, or any explicit row range
  /// — each with a per-person price that overrides the base/per-type pricing for
  /// the rows it covers. Bands are owned by the parent state (so they survive
  /// step navigation) and are surfaced to pricing alongside the legacy rear zone.
  Widget _buildBandsSection() {
    final rowCount = _rowCount;
    return Container(
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _bandsOpen = !_bandsOpen);
            },
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(UgamSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              tr('add_bus.bands.title'),
                              style: UgamText.bodyStrong.copyWith(
                                color: c.ink,
                                fontSize: 14,
                              ),
                            ),
                            if (_bands.isNotEmpty) ...[
                              const SizedBox(width: UgamSpacing.sm),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.accentFill,
                                  borderRadius: BorderRadius.circular(
                                    UgamRadius.chip,
                                  ),
                                ),
                                child: Text(
                                  '${_bands.length}',
                                  style: UgamText.tabular(
                                    UgamText.micro.copyWith(color: c.accent),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('add_bus.bands.subtitle'),
                          style: UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  AnimatedRotation(
                    duration: UgamMotion.tab,
                    curve: UgamMotion.easeOut,
                    turns: _bandsOpen ? 0.5 : 0,
                    child: Icon(Icons.expand_more_rounded, color: c.ink3),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            alignment: Alignment.topCenter,
            child: _bandsOpen
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.lg,
                      0,
                      UgamSpacing.lg,
                      UgamSpacing.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _bands.length; i++) ...[
                          _BandRow(
                            c: c,
                            band: _bands[i],
                            onEdit: () => _openBandSheet(index: i),
                            onRemove: () => _removeBand(i),
                          ),
                          const SizedBox(height: UgamSpacing.sm),
                        ],
                        const SizedBox(height: UgamSpacing.xs),
                        GestureDetector(
                          onTap: () => _openBandSheet(),
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              vertical: UgamSpacing.md,
                            ),
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              borderRadius: BorderRadius.circular(
                                UgamRadius.row,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_rounded,
                                  size: 18,
                                  color: c.accent,
                                ),
                                const SizedBox(width: UgamSpacing.sm),
                                Text(
                                  tr('add_bus.bands.add'),
                                  style: UgamText.bodyStrong.copyWith(
                                    color: c.accent,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (rowCount == null) ...[
                          const SizedBox(height: UgamSpacing.sm),
                          Text(
                            tr('add_bus.bands.rows_clamped_note'),
                            style: UgamText.micro.copyWith(color: c.ink3),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// Open the add/edit sheet for a band. [index] null = adding a new band.
  void _openBandSheet({int? index}) {
    final existing = index != null ? _bands[index] : null;
    final rowCount = _rowCount;
    final maxRow = rowCount == null ? null : rowCount - 1;

    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    // Display rows 1-based to the agent; store 0-based.
    final fromCtrl = TextEditingController(
      text: existing != null ? '${existing.fromRow + 1}' : '',
    );
    final toCtrl = TextEditingController(
      text: existing != null ? '${existing.toRow + 1}' : '',
    );
    final priceCtrl = TextEditingController(
      text: existing != null && existing.price > 0
          ? existing.price.toStringAsFixed(0)
          : '',
    );

    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('add_bus.band_sheet.title_add')
          : tr('add_bus.band_sheet.title_edit'),
      builder: (sheetCtx) {
        final sc = UgamColors.of(sheetCtx);
        return SingleChildScrollView(
          child: StatefulBuilder(
            builder: (innerCtx, setSheetState) {
              int? parseRow(TextEditingController ctl) {
                final raw = int.tryParse(ctl.text.trim());
                if (raw == null) return null;
                return raw - 1; // back to 0-based
              }

              final from = parseRow(fromCtrl);
              // Blank "To row" → a single-row band (just the From row), so
              // pricing one seat/row (e.g. row 5) is "From 5", To left empty.
              final to =
                  toCtrl.text.trim().isEmpty ? from : parseRow(toCtrl);
              final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
              final valid =
                  from != null &&
                  to != null &&
                  from >= 0 &&
                  to >= 0 &&
                  price > 0;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label(c: sc, text: tr('add_bus.band_sheet.label')),
                  const SizedBox(height: UgamSpacing.sm),
                  _Field(
                    c: sc,
                    controller: labelCtrl,
                    hint: tr('add_bus.band_sheet.label_hint'),
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Label(c: sc, text: tr('add_bus.band_sheet.from_row')),
                            const SizedBox(height: UgamSpacing.sm),
                            _Field(
                              c: sc,
                              controller: fromCtrl,
                              hint: '1',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: false,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9]'),
                                ),
                              ],
                              onChanged: (_) => setSheetState(() {}),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Label(c: sc, text: tr('add_bus.band_sheet.to_row')),
                            const SizedBox(height: UgamSpacing.sm),
                            _Field(
                              c: sc,
                              controller: toCtrl,
                              hint: tr('add_bus.band_sheet.to_row_hint'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: false,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9]'),
                                ),
                              ],
                              onChanged: (_) => setSheetState(() {}),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  Text(
                    maxRow == null
                        ? tr('add_bus.band_sheet.rows_help')
                        : tr(
                            'add_bus.band_sheet.rows_help_max',
                            namedArgs: {'max': '${maxRow + 1}'},
                          ),
                    style: UgamText.micro.copyWith(color: sc.ink3),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  _Label(c: sc, text: tr('add_bus.band_sheet.price_per_person')),
                  const SizedBox(height: UgamSpacing.sm),
                  _Field(
                    c: sc,
                    controller: priceCtrl,
                    hint: tr('add_bus.band_sheet.price_hint'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    prefix: '₹',
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  UgamCTA(
                    label: existing == null
                        ? tr('add_bus.band_sheet.cta_add')
                        : tr('add_bus.band_sheet.cta_save'),
                    onPressed: valid
                        ? () {
                            // `valid` promotes both from/to to non-null here.
                            final f = from;
                            final t = to;
                            var lo = f <= t ? f : t;
                            var hi = f <= t ? t : f;
                            if (maxRow != null) {
                              lo = lo.clamp(0, maxRow);
                              hi = hi.clamp(0, maxRow);
                            }
                            final label = labelCtrl.text.trim().isEmpty
                                ? tr('add_bus.band_sheet.default_label')
                                : labelCtrl.text.trim();
                            final band = PriceBand(
                              label: label,
                              fromRow: lo,
                              toRow: hi,
                              price: price,
                            );
                            if (index == null) {
                              _addBand(band);
                            } else {
                              _updateBand(index, band);
                            }
                            Navigator.of(sheetCtx).pop();
                          }
                        : null,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// Collapsible "Per-type overrides (optional)" section housing the three
  /// existing single/double/seater price fields. Collapsed by default to reduce
  /// clutter; their wiring (controllers + onChanged) is unchanged.
  Widget _buildOverridesSection() {
    return Container(
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _overridesOpen = !_overridesOpen);
            },
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(UgamSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('add_bus.section.overrides_title'),
                          style: UgamText.bodyStrong.copyWith(
                            color: c.ink,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('add_bus.section.overrides_body'),
                          style: UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  AnimatedRotation(
                    duration: UgamMotion.tab,
                    curve: UgamMotion.easeOut,
                    turns: _overridesOpen ? 0.5 : 0,
                    child: Icon(Icons.expand_more_rounded, color: c.ink3),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            alignment: Alignment.topCenter,
            child: _overridesOpen
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.lg,
                      0,
                      UgamSpacing.lg,
                      UgamSpacing.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Label(c: c, text: tr('add_bus.overrides.single_price')),
                        const SizedBox(height: UgamSpacing.sm),
                        _Field(
                          c: c,
                          controller: singleSofaPrice,
                          hint: tr('add_bus.overrides.defaults_to_base'),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          prefix: '₹',
                          onChanged: (_) => onChanged(),
                        ),
                        const SizedBox(height: UgamSpacing.lg),
                        _Label(c: c, text: tr('add_bus.overrides.double_price')),
                        const SizedBox(height: UgamSpacing.sm),
                        _Field(
                          c: c,
                          controller: doubleSofaPrice,
                          hint: tr('add_bus.overrides.defaults_to_base'),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          prefix: '₹',
                          onChanged: (_) => onChanged(),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Legend showing which rows fall in the rear zone. When the layout is known
/// (edit mode) it renders a row-strip where each row is marked using
/// [BusLayout.isRearRow] — rear rows get an accent tint/border so the agent sees
/// exactly which seats are affected. In add mode (no layout yet) it falls back
/// to a single caption line.
class _RearZoneLegend extends StatelessWidget {
  final UgamColorSet c;
  final int rearRows;
  final BusLayout? layout;

  const _RearZoneLegend({
    required this.c,
    required this.rearRows,
    required this.layout,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.layers_rounded, size: 16, color: c.accent),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  l == null
                      ? tr(
                          'add_bus.rear_zone.legend_plain',
                          namedArgs: {'rows': '$rearRows'},
                        )
                      : tr(
                          'add_bus.rear_zone.legend',
                          namedArgs: {
                            'rows': '$rearRows',
                            'total': '${l.rows}',
                          },
                        ),
                  style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
                ),
              ),
            ],
          ),
          if (l != null) ...[
            const SizedBox(height: UgamSpacing.sm),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: List.generate(l.rows, (row) {
                final rear = l.isRearRow(row, rearRows);
                return Container(
                  width: 26,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: rear ? c.accent : c.card,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: rear ? c.accent : c.border,
                      width: rear ? 1.4 : 1,
                    ),
                  ),
                  child: Text(
                    '${row + 1}',
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(
                        color: rear ? c.onAccent : c.ink3,
                        fontSize: 9.5,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }
}

/// One row in the "Price bands" list: the band's label, its 1-based row range,
/// and its per-person price, with edit + remove affordances. Tapping the row
/// opens the edit sheet; the trash icon removes it.
class _BandRow extends StatelessWidget {
  final UgamColorSet c;
  final PriceBand band;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _BandRow({
    required this.c,
    required this.band,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final rangeLabel = band.fromRow == band.toRow
        ? tr('add_bus.band_row.single', namedArgs: {'row': '${band.fromRow + 1}'})
        : tr(
            'add_bus.band_row.range',
            namedArgs: {'from': '${band.fromRow + 1}', 'to': '${band.toRow + 1}'},
          );
    return GestureDetector(
      onTap: onEdit,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    band.label.isEmpty
                        ? tr('add_bus.band_sheet.default_label')
                        : band.label,
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    rangeLabel,
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              '₹${band.price.toStringAsFixed(0)}',
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.accent, fontSize: 14),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close_rounded, size: 18, color: c.ink3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Shared form pieces
// ════════════════════════════════════════════════════════════════════════

class _StepIntro extends StatelessWidget {
  final UgamColorSet c;
  final String eyebrow;
  final String title;
  final String body;

  const _StepIntro({
    required this.c,
    required this.eyebrow,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(eyebrow, style: UgamText.micro.copyWith(color: c.accent)),
        const SizedBox(height: UgamSpacing.sm),
        Text(title, style: UgamText.titleXl.copyWith(color: c.ink)),
        const SizedBox(height: UgamSpacing.sm),
        Text(
          body,
          style: UgamText.body.copyWith(
            color: c.ink2,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  final UgamColorSet c;
  final String text;
  const _Label({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: UgamText.micro.copyWith(color: c.ink2),
    );
  }
}

/// Small inline validation caption (danger-tinted) shown beneath a non-input
/// control — used in place of a save-time error toast for layout/stepper
/// validations that can't attach to a UgamInput errorText.
class _InlineError extends StatelessWidget {
  final UgamColorSet c;
  final String text;

  const _InlineError({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 14, color: c.danger),
        const SizedBox(width: UgamSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: UgamText.caption.copyWith(color: c.danger, height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// Read-only positional slot indicator ("Bus N"). The slot is assigned by the
/// bus's order within its tour and is not editable.
class _SlotBadge extends StatelessWidget {
  final UgamColorSet c;
  final String label;

  const _SlotBadge({required this.c, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.tag_rounded, size: 18, color: c.ink3),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            label,
            style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 14),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            tr('add_bus.slot_auto'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }
}

/// Tap target mirroring [_Field] for a time-of-day. Shows a locale-aware
/// period-word time (via [formatHhMm]) once picked, or the hint while unset.
class _TimeField extends StatelessWidget {
  final UgamColorSet c;
  final String hint;
  final TimeOfDay? time;
  final VoidCallback onTap;

  const _TimeField({
    required this.c,
    required this.hint,
    required this.time,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = time;
    final label = t != null ? formatHhMm(hhmmFromTimeOfDay(t)) : null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.lg,
        ),
        child: Row(
          children: [
            Icon(Icons.access_time_rounded, size: 18, color: c.ink2),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                label ?? hint,
                style: UgamText.body.copyWith(
                  color: label != null ? c.ink : c.ink3,
                  fontSize: 15,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController controller;
  final String? hint;
  final String? prefix;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.c,
    required this.controller,
    this.hint,
    this.prefix,
    this.keyboardType,
    this.inputFormatters = const [],
    this.textCapitalization = TextCapitalization.none,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        textCapitalization: textCapitalization,
        onChanged: onChanged,
        style: UgamText.body.copyWith(color: c.ink, fontSize: 15),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.lg,
          ),
          hintText: hint,
          hintStyle: UgamText.body.copyWith(color: c.ink3, fontSize: 15),
          prefixText: prefix == null ? null : '$prefix ',
          prefixStyle: UgamText.body.copyWith(color: c.ink, fontSize: 15),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
        ),
      ),
    );
  }
}
