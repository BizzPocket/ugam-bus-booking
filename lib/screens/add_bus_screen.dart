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
  bool _saving = false;
  bool _priceInitialized = false;

  /// The "all-double last row" toggle the agent sets when creating a bus. When
  /// true the seat engine builds the LAST row as 4 double sofas; when false
  /// (default) it builds 3 single + 2 double sofas. Not persisted on the model
  /// — inferred from the saved layout when editing (see [_seedCapacityFromLayout]).
  bool _allDoubleBackRow = false;

  /// Capacity values as first shown when EDITING an existing bus (derived from
  /// its saved layout in [initState]). Used to detect whether the admin actually
  /// touched the capacity, so a plain field edit (driver, price, …) never
  /// regenerates the layout or threatens existing seat assignments.
  int _initTotalSeats = 40;
  int _initSingleSofaCount = 0;
  bool _initAllDoubleBackRow = false;

  /// Edit-mode only. Set by the "Regenerate layout" button to force a rebuild of
  /// the seat layout from the current form settings even when no capacity field
  /// was touched — used to re-apply the current seat engine to a bus whose layout
  /// was saved under the old engine. Always reset back to false after a save
  /// attempt (cancel, error, or success) so a later plain edit never regenerates.
  bool _forceRegenerate = false;

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
  /// bus's current size. The back bench is now generated automatically from the
  /// seat-count parity, so `totalSeats` for the stepper is simply the layout's
  /// total seats. The derived values are snapshotted so [_save] can tell whether
  /// the admin actually changed the capacity.
  void _seedCapacityFromLayout(Bus e) {
    final layout = e.layout;
    if (layout != null) {
      _singleSofaCount = layout.grid
          .where((cl) =>
              cl.hasSeat &&
              cl.seatType == SeatType.singleSofa &&
              (cl.col == SeatGridCols.singleUpper ||
                  cl.col == SeatGridCols.singleLower))
          .length;
      _totalSeats = layout.totalSeats.clamp(1, 100);
      // The toggle isn't persisted, so infer it from the existing layout: look
      // at the last row — if it still carries any single sofa the bus was built
      // with the default mixed back row (toggle OFF); otherwise the back row was
      // all-double (toggle ON).
      final lastRow = layout.rows - 1;
      final lastRowHasSingle = layout.grid.any((cl) =>
          cl.row == lastRow &&
          cl.hasSeat &&
          cl.seatType == SeatType.singleSofa);
      _allDoubleBackRow = !lastRowHasSingle;
    } else {
      _totalSeats = e.totalSeats;
    }
    _initTotalSeats = _totalSeats;
    _initSingleSofaCount = _singleSofaCount;
    _initAllDoubleBackRow = _allDoubleBackRow;
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
          _allDoubleBackRow != _initAllDoubleBackRow);

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
      allDoubleBackRow: _allDoubleBackRow,
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

  // ── Regenerate layout (edit only) ───────────────────────────────────

  /// Force-rebuild this bus's seat layout from the current form settings
  /// (capacity + single count + the all-double-back-row toggle). Used to migrate
  /// a bus whose layout was saved under the OLD seat engine onto the current one.
  ///
  /// Renumbers every berth, so any passenger currently seated on THIS bus is
  /// freed and must be re-assigned. Shows its own destructive confirm; on accept
  /// it sets [_forceRegenerate] and runs the normal [_save] (which then skips its
  /// own resize prompt because the warning was already shown here).
  Future<void> _regenerateLayout() async {
    final seated = _seatedOnThisBus;
    final ok = await UgamDialog.confirm(
      context,
      title: tr('add_bus.regenerate_confirm_title'),
      message: seated > 0
          ? tr(
              'add_bus.regenerate_confirm_msg',
              namedArgs: {'count': '$seated'},
            )
          : tr('add_bus.regenerate_confirm_msg_empty'),
      confirmLabel: tr('add_bus.regenerate_confirm_cta'),
      destructive: true,
    );
    if (ok != true) return;
    setState(() => _forceRegenerate = true);
    await _save();
  }

  // ── Save ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!widget.isEditing) {
      // Layout-buildability is enforced inline on Step 2 (see _canAdvance);
      // these guards are a final safety net and surface no toast.
      if (_singleSofaInvalid) {
        _forceRegenerate = false;
        return;
      }
    }

    final tour = _tour;
    if (tour == null) {
      _forceRegenerate = false;
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

        // The layout is rebuilt when the admin either touched a capacity field
        // (_capacityChanged) OR tapped "Regenerate layout" (_forceRegenerate) —
        // the latter forces a fresh build from the current settings so a bus
        // saved under the old seat engine adopts the current one. Otherwise the
        // saved layout is reused untouched, so seat IDs — and every existing
        // seat assignment — stay exactly as they were.
        final regenerate = _capacityChanged || _forceRegenerate;
        final newLayout = regenerate
            ? BusLayout.generate(
                busType: _busType,
                totalSeats: _totalSeats,
                seaterCount: 0,
                singleSofaCount: _singleSofaCount,
                allDoubleBackRow: _allDoubleBackRow,
              )
            : source.layout;

        // A real resize/regenerate renumbers the seat IDs, so anyone seated on
        // this bus would be orphaned. Confirm-then-clear those assignments first.
        final oldIds = source.layout?.allSeatIds.toSet() ?? <String>{};
        final newIds = newLayout?.allSeatIds.toSet() ?? <String>{};
        final structuralChange = regenerate &&
            (oldIds.length != newIds.length || !oldIds.containsAll(newIds));

        final seated = _seatedOnThisBus;
        if (structuralChange && seated > 0) {
          // The "Regenerate layout" button shows its own destructive warning
          // before calling _save, so don't double-prompt here when the rebuild
          // was forced from that button — only the in-flow resize path prompts.
          if (!_forceRegenerate) {
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
              _forceRegenerate = false;
              return;
            }
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
        allDoubleBackRow: _allDoubleBackRow,
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
      // Always clear the forced-regenerate intent so a later normal save (e.g.
      // a plain field edit after an error) never regenerates unexpectedly.
      _forceRegenerate = false;
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
            UgamAppBar(
              title: widget.isEditing
                  ? tr('add_bus.title_edit')
                  : tr('add_bus.title'),
              subtitle: _subtitle.isEmpty ? null : _subtitle,
              onBack: _goBack,
            ),
            _WizardProgress(
              c: c,
              steps: _stepSequence.length,
              index: _indexInSequence,
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
          allDoubleBackRow: _allDoubleBackRow,
          onAllDoubleBackRow: (v) => setState(() => _allDoubleBackRow = v),
          // Edit mode only: re-apply the current seat engine to a bus whose
          // layout was saved under the old engine. Null in add mode (hides it).
          onRegenerate: widget.isEditing ? _regenerateLayout : null,
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
        );
      case 2:
      default:
        return _Step3Price(
          c: c,
          price: _price,
          busPrice: _busPrice,
          singleSofaPrice: _singleSofaPrice,
          doubleSofaPrice: _doubleSofaPrice,
          priceBands: _priceBands,
          onBandsChanged: (bands) => setState(() => _priceBands = bands),
          layout: _previewLayout,
          tour: _tour,
          totalSeats: _totalSeats,
          onChanged: () => setState(() {}),
        );
    }
  }
}

// ════════════════════════════════════════════════════════════════════════
// Wizard progress — slim step-dot bar under the app bar
// ════════════════════════════════════════════════════════════════════════

class _WizardProgress extends StatelessWidget {
  final UgamColorSet c;
  final int steps;
  final int index;

  const _WizardProgress({
    required this.c,
    required this.steps,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
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
          hint: tr('add_bus.hint.bus_number_plain'),
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('add_bus.label.boarding_point'),
          controller: boardingPoint,
          hint: tr('add_bus.hint.boarding_point'),
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamPickerField(
          label: tr('add_bus.label.departure_time'),
          value: departureTime != null
              ? (formatHhMm(hhmmFromTimeOfDay(departureTime!)) ?? '')
              : '',
          placeholder: tr('add_bus.hint.departure_time'),
          icon: Icons.access_time_rounded,
          onTap: onPickDepartureTime,
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('add_bus.label.driver_name'),
          controller: driverName,
          hint: tr('add_bus.hint.driver_name_plain'),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamPhoneInput(
          label: tr('add_bus.label.driver_phone'),
          controller: driverPhone,
        ),
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

  /// Current state of the "all-double last row" toggle, and the callback that
  /// flips it. When on, the seat engine builds the last row as 4 double sofas;
  /// when off (default) it builds 3 single + 2 double sofas.
  final bool allDoubleBackRow;
  final ValueChanged<bool> onAllDoubleBackRow;

  /// Inline validation caption shown under the single-sofa stepper, or null
  /// when the value is valid. Replaces the legacy save-time toast.
  final String? singleSofaError;

  /// Edit-mode resize warning shown above the controls when the bus already has
  /// passengers seated — changing the size will unassign them. Null hides it.
  final String? seatedWarning;

  /// Edit-mode only: force-rebuild the saved layout from the current settings
  /// (re-applies the current seat engine to a bus saved under the old one).
  /// Null in add mode, which hides the "Regenerate layout" button.
  final VoidCallback? onRegenerate;
  final ValueChanged<int> onTotalSeats;
  final ValueChanged<int> onSingleSofa;

  const _Step2Capacity({
    required this.c,
    required this.totalSeats,
    required this.singleSofaCount,
    required this.sleeperSeats,
    required this.singleSofaSummary,
    required this.allDoubleBackRow,
    required this.onAllDoubleBackRow,
    this.singleSofaError,
    this.seatedWarning,
    this.onRegenerate,
    required this.onTotalSeats,
    required this.onSingleSofa,
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
          const SizedBox(height: UgamSpacing.sm),
          _BackRowToggle(
            c: c,
            value: allDoubleBackRow,
            onChanged: onAllDoubleBackRow,
          ),
          if (onRegenerate != null) ...[
            const SizedBox(height: UgamSpacing.lg),
            _RegenerateLayoutButton(c: c, onTap: onRegenerate!),
          ],
        ],
        const SizedBox(height: UgamSpacing.xl),
      ],
    );
  }
}

/// Edit-mode action that re-applies the current seat-layout engine to a bus
/// whose layout was saved under an older engine. Styled as a secondary, slightly
/// cautionary row (not the primary save CTA) so it stays discoverable without
/// competing with the wizard's Next/Save button. Tapping it shows a destructive
/// confirm before any layout is rebuilt.
class _RegenerateLayoutButton extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _RegenerateLayoutButton({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
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
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(Icons.refresh_rounded, size: 18, color: c.ink2),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('add_bus.regenerate_label'),
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    tr('add_bus.regenerate_subtitle'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
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

/// Interactive control for the "all-double last row" seat-engine toggle. When
/// ON, the bus's LAST row is built as 4 double sofas; when OFF (default) it's
/// 3 single + 2 double sofas. The subtitle reflects the current state. No total
/// seats are added either way — the count is conserved by the engine.
class _BackRowToggle extends StatelessWidget {
  final UgamColorSet c;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _BackRowToggle({
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
                Icons.weekend_rounded,
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
                    tr('add_bus.back_row_toggle.label'),
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    value
                        ? tr('add_bus.back_row_toggle.on')
                        : tr('add_bus.back_row_toggle.off'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
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

  /// The saved layout (edit mode). Null in add mode — the layout is only built
  /// at save time there, so the band row range can't be clamped against a
  /// concrete grid until then.
  final BusLayout? layout;
  final Tour? tour;
  final int totalSeats;
  final VoidCallback onChanged;

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
  });

  @override
  State<_Step3Price> createState() => _Step3PriceState();
}

class _Step3PriceState extends State<_Step3Price> {
  /// Whether this bus uses one uniform price ([_PriceMode.fixed]) or explicit
  /// per-row price bands ([_PriceMode.bands]). Seeded from whether the bus
  /// already carries bands.
  late _PriceMode _mode;

  /// Bands stashed when the agent switches back to "Same for all" — keeping them
  /// here lets a same-session toggle to "Price bands" restore the work, while
  /// the parent state (and thus _save) sees an empty band list meaning uniform.
  List<PriceBand> _stashedBands = const [];

  @override
  void initState() {
    super.initState();
    _mode = widget.priceBands.isNotEmpty ? _PriceMode.bands : _PriceMode.fixed;
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

  /// Row count of the bus, when known (edit mode). Used to clamp the band row
  /// range. Null in add mode.
  int? get _rowCount => widget.layout?.rows;

  /// When the agent edits the full bus price, auto-fill the per-seat field by
  /// dividing across the total seats. Setting the controller text directly does
  /// NOT fire the per-seat field's own onChanged, so this stays a soft default
  /// the agent can freely type over.
  void _onBusPriceChanged() {
    final parsed = double.tryParse(busPrice.text.trim());
    if (parsed != null && parsed > 0 && totalSeats > 0) {
      final v = parsed / totalSeats;
      price.text =
          v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    }
    onChanged();
  }

  /// Switch between uniform pricing and explicit price bands. Switching to
  /// "Same for all" stashes any current bands and clears them from the parent
  /// (so _save persists priceBands=[]); switching back restores the stash.
  void _onModeChanged(int i) {
    final next = _PriceMode.values[i];
    if (next == _PriceMode.fixed && widget.priceBands.isNotEmpty) {
      _stashedBands = List<PriceBand>.of(widget.priceBands);
      widget.onBandsChanged(const []);
    } else if (next == _PriceMode.bands &&
        widget.priceBands.isEmpty &&
        _stashedBands.isNotEmpty) {
      widget.onBandsChanged(List<PriceBand>.of(_stashedBands));
    }
    HapticFeedback.selectionClick();
    setState(() => _mode = next);
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
          eyebrow: tr('add_bus.step3.eyebrow'),
          title: tr('add_bus.step3.title'),
          body: tr('add_bus.step3.body'),
        ),
        const SizedBox(height: UgamSpacing.xl),
        UgamInput(
          label: tr('add_bus.label.bus_price'),
          controller: busPrice,
          hint: tr('add_bus.hint.bus_price'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: _RupeePrefix(c: c),
          onChanged: (_) => _onBusPriceChanged(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('add_bus.label.price_per_seat'),
          controller: price,
          hint: hint,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: _RupeePrefix(c: c),
          onChanged: (_) => onChanged(),
        ),
        if (busPriceParsed > 0 && totalSeats > 0) ...[
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('add_bus.per_seat.auto_note', namedArgs: {'seats': '$totalSeats'}),
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
        UgamInput(
          label: tr('add_bus.overrides.single_price'),
          controller: singleSofaPrice,
          hint: tr('add_bus.overrides.defaults_to_base'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: _RupeePrefix(c: c),
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          label: tr('add_bus.overrides.double_price'),
          controller: doubleSofaPrice,
          hint: tr('add_bus.overrides.defaults_to_base'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          prefix: _RupeePrefix(c: c),
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }

  /// Price-bands body: the editable list of named row-range bands.
  Widget _buildBandsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('add_bus.price_mode.bands_body'),
          style: UgamText.caption.copyWith(color: c.ink3, height: 1.4),
        ),
        const SizedBox(height: UgamSpacing.lg),
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
        UgamButton(
          label: tr('add_bus.bands.add'),
          kind: UgamButtonKind.tonal,
          icon: Icons.add_rounded,
          expand: true,
          onPressed: () => _openBandSheet(),
        ),
        if (_rowCount == null) ...[
          const SizedBox(height: UgamSpacing.sm),
          Text(
            tr('add_bus.bands.rows_clamped_note'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
      ],
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
                  UgamInput(
                    label: tr('add_bus.band_sheet.label'),
                    controller: labelCtrl,
                    hint: tr('add_bus.band_sheet.label_hint'),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: UgamInput(
                          label: tr('add_bus.band_sheet.from_row'),
                          controller: fromCtrl,
                          hint: '1',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: false,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                          ],
                          onChanged: (_) => setSheetState(() {}),
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: UgamInput(
                          label: tr('add_bus.band_sheet.to_row'),
                          controller: toCtrl,
                          hint: tr('add_bus.band_sheet.to_row_hint'),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: false,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                          ],
                          onChanged: (_) => setSheetState(() {}),
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
                  UgamInput(
                    label: tr('add_bus.band_sheet.price_per_person'),
                    controller: priceCtrl,
                    hint: tr('add_bus.band_sheet.price_hint'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    prefix: _RupeePrefix(c: sc),
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

/// Rupee glyph for the `prefix` (prefixIcon) slot of a [UgamInput] money field.
/// Sized down so it reads as an adornment, not a leading icon.
class _RupeePrefix extends StatelessWidget {
  final UgamColorSet c;
  const _RupeePrefix({required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      child: Center(
        widthFactor: 1,
        child: Text(
          '₹',
          style: UgamText.body.copyWith(color: c.ink2, fontSize: 15),
        ),
      ),
    );
  }
}
