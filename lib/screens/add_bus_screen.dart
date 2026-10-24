import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_type.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../utils/app_nav.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/time_format.dart';

part 'add_bus/add_bus_save.dart';
part 'add_bus/add_bus_chrome.dart';
part 'add_bus/add_bus_identity_step.dart';
part 'add_bus/add_bus_capacity_step.dart';
part 'add_bus/add_bus_price_step.dart';
part 'add_bus/add_bus_price_bands.dart';
part 'add_bus/add_bus_form_pieces.dart';

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

  /// When set (and [existing] is null) the wizard opens in ADD mode but seeds
  /// every field from this bus as a TEMPLATE — the "Duplicate bus" path. The
  /// per-vehicle identity (slot name + registration plate + driver) is
  /// deliberately NOT copied, so the clone auto-numbers into the next slot and
  /// never collides with the source's unique registration. Saving then creates
  /// a brand-new bus exactly like a normal add.
  final Bus? templateBus;

  /// Which wizard step to open on (0 = identity, 1 = capacity, 2 = price).
  ///
  /// Defaults to the start. Deep-links that already know what the agent came to
  /// fix — the Board's `BoardEmptyAction.setFares`, which means "this bus has no
  /// fares", or `createSeatPlan`, which means "this bus has no layout" — pass
  /// the step that actually holds those fields instead of making the agent walk
  /// the whole wizard to reach it. Out-of-range values fall back to 0, and the
  /// Back pill still walks the full sequence, so nothing entered earlier is
  /// skipped over silently.
  final int initialStep;

  const AddBusScreen({
    super.key,
    required this.tourId,
    this.existing,
    this.templateBus,
    this.initialStep = 0,
  });

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

  /// Focus on the registration-plate field. Owned here (rather than left to
  /// [UgamInput]'s internal node) so the duplicate check can run **on blur**
  /// instead of on every keystroke: typing "GJ-05" through a plate that is
  /// already taken would otherwise flash an error at almost every character.
  final _busNumberFocus = FocusNode();

  /// Set by [_validateBusNumber] when this plate is already on another bus of
  /// the SAME tour. Rendered in the field's own `errorText` slot and blocks
  /// both Next and Save — the plate carries a unique index, so saving it would
  /// come back as an unattributable "could not save bus".
  String? _busNumberError;

  /// Per-bus departure time. Stored as a [TimeOfDay] while editing the form and
  /// serialized to canonical 'HH:mm' (via [hhmmFromTimeOfDay]) on save.
  TimeOfDay? _departureTime;

  /// Flexible, named price bands for this bus (front premium, back discount,
  /// or any explicit row range). Edited via the Step 3 "Price bands"
  /// sub-section; serialized onto the Bus at save time.
  List<PriceBand> _priceBands = const [];

  /// Whether Step 3 is showing uniform pricing or explicit per-row bands, and
  /// the bands stashed when the agent switches back to "Same for all".
  ///
  /// Both live HERE, not inside `_Step3PriceState`. The wizard swaps steps
  /// through an [AnimatedSwitcher] keyed on [_currentStep], so stepping back to
  /// Capacity DISPOSES the price step's State — which used to drop the chosen
  /// mode (silently reverting a bands-mode bus to "Same for all" on return) and
  /// throw the stash away with it. Owning them at wizard level is what makes
  /// "Back preserves what I entered" true for this step too.
  _PriceMode _priceMode = _PriceMode.fixed;
  List<PriceBand> _stashedBands = const [];

  bool _isAC = true;

  /// Pakku bhadu: agreed rent includes diesel; trip diesel/advances deduct from
  /// Malik payout. Defaults true for Indian tour-bus contracts.
  bool _rentIncludesFuel = true;
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

  /// Set the moment the agent changes anything on the form. Drives the
  /// unsaved-work guard on the app-bar exit.
  ///
  /// Deliberately a flag set by the change callbacks rather than a diff of the
  /// controllers: Step 3 auto-seeds the single/double sofa price fields on its
  /// first build (see [_Step3PriceState.initState]), so a value-diff would
  /// report "unsaved changes" before the agent had touched anything.
  bool _dirty = false;

  /// Every user-driven change on every step funnels through here.
  void _markDirty() => setState(() => _dirty = true);

  /// `setState` for the `part`-file extensions (it is protected on [State]).
  void _update(VoidCallback fn) => setState(fn);

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

  /// Name of the step being shown, used by the progress bar so "where am I"
  /// is a word and not three anonymous bars.
  String get _stepLabel => switch (_currentStep) {
    0 => tr('add_bus.step1.eyebrow'),
    1 => tr('add_bus.step2.eyebrow'),
    _ => tr('add_bus.step3.eyebrow'),
  };

  @override
  void initState() {
    super.initState();
    if (_stepSequence.contains(widget.initialStep)) {
      _currentStep = widget.initialStep;
    }
    _busNumberFocus.addListener(_onBusNumberFocusChanged);
    final e = widget.existing;
    if (e != null) {
      // Editing: seed every field from the bus, identity included.
      _seedFromBus(e, asTemplate: false);
      _priceInitialized = true;
    } else if (widget.templateBus != null) {
      // Duplicating: same seeding, but the per-vehicle identity is skipped so
      // the clone auto-numbers into the next slot and starts with a blank plate.
      _seedFromBus(widget.templateBus!, asTemplate: true);
      _priceInitialized = true;
    }
    // Seeded bands mean the bus is priced by row, so Step 3 opens on that tab.
    _priceMode = _priceBands.isNotEmpty ? _PriceMode.bands : _PriceMode.fixed;
  }

  // ── Registration-plate validation (on blur, not per keystroke) ──────

  /// Comparable form of a registration plate: case- and separator-insensitive,
  /// so `gj 05 ab 1234` and `GJ-05-AB-1234` are recognised as the same vehicle.
  static String _plateKey(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  void _onBusNumberFocusChanged() {
    if (_busNumberFocus.hasFocus) return;
    _validateBusNumber();
  }

  /// Flag a plate already carried by another bus on this tour. Runs on blur and
  /// again just before saving; returns true when the field is usable.
  ///
  /// Blank is always valid — the plate is deliberately optional here (the owner
  /// often confirms the vehicle days later), and a NULL plate does not collide.
  bool _validateBusNumber() {
    final key = _plateKey(_busNumber.text.trim());
    String? error;
    if (key.isNotEmpty) {
      final tour = _tour;
      final clash = tour?.buses.where(
        (b) => b.id != widget.existing?.id && _plateKey(b.busNumber) == key,
      );
      if (clash != null && clash.isNotEmpty) {
        error = tr(
          'add_bus.error.duplicate_bus_number',
          namedArgs: {'name': clash.first.name},
        );
      }
    }
    if (error != _busNumberError && mounted) {
      setState(() => _busNumberError = error);
    }
    return error == null;
  }

  /// Copy a source bus's fields into the form controllers. Shared by EDIT mode
  /// (identity included) and the DUPLICATE template path ([asTemplate] true),
  /// which skips the per-vehicle identity — slot name, registration plate and
  /// driver — so the clone auto-numbers into the next slot, keeps an empty
  /// (NULL) registration (the plate carries a partial unique index) and lets the
  /// agent enter the new vehicle's driver. Everything reusable — boarding,
  /// departure, AC, capacity/layout and all pricing — carries over.
  void _seedFromBus(Bus e, {required bool asTemplate}) {
    if (!asTemplate) {
      _slotLabel.text = e.name;
      _busNumber.text = e.busNumber;
      _driverName.text = e.driverName;
      _driverPhone.text = e.driverPhone;
    }
    _boardingPoint.text = e.boardingPoint;
    _departureTime = timeOfDayFromHhmm(e.departureTime);
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
    _rentIncludesFuel = e.rentIncludesFuel;
    _seedCapacityFromLayout(e);
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
          .where(
            (cl) =>
                cl.hasSeat &&
                cl.seatType == SeatType.singleSofa &&
                (cl.col == SeatGridCols.singleUpper ||
                    cl.col == SeatGridCols.singleLower),
          )
          .length;
      _totalSeats = layout.totalSeats.clamp(1, 100);
      // The toggle isn't persisted, so infer it from the existing layout: look
      // at the last row — if it still carries any single sofa the bus was built
      // with the default mixed back row (toggle OFF); otherwise the back row was
      // all-double (toggle ON).
      final lastRow = layout.rows - 1;
      final lastRowHasSingle = layout.grid.any(
        (cl) =>
            cl.row == lastRow &&
            cl.hasSeat &&
            cl.seatType == SeatType.singleSofa,
      );
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
    _busNumberFocus.removeListener(_onBusNumberFocusChanged);
    _busNumberFocus.dispose();
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
    final idx = e == null ? -1 : tour.buses.indexWhere((b) => b.id == e.id);
    return tr(
      'add_bus.slot_position',
      namedArgs: {'n': '${(idx < 0 ? tour.buses.length : idx) + 1}'},
    );
  }

  /// The name the bus is saved under: what the agent typed, else the
  /// positional [_slotPositionLabel].
  String get _effectiveSlotLabel => _slotLabel.text.trim().isEmpty
      ? _slotPositionLabel
      : _slotLabel.text.trim();

  /// [_departureTime] serialized to canonical 'HH:mm', or null when unset.
  String? get _departureHhmm =>
      _departureTime != null ? hhmmFromTimeOfDay(_departureTime!) : null;

  /// A fresh layout from the current Step 2 inputs — the one argument set both
  /// [_previewLayout] and [_save] build with.
  BusLayout _generateLayout() => BusLayout.generate(
    busType: _busType,
    totalSeats: _totalSeats,
    seaterCount: 0,
    singleSofaCount: _singleSofaCount,
    allDoubleBackRow: _allDoubleBackRow,
  );

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

  /// True when this bus's seat plan may no longer be rebuilt — an EDIT of a bus
  /// on a locked or completed tour.
  ///
  /// The bus record itself stays editable there (that is the whole point of
  /// reaching this screen on departure day: a driver changes, a number is
  /// wrong, a pickup moves), and `TourController.updateBus` gates on
  /// `layoutChanged` rather than on status so those edits land. But it still
  /// refuses a re-layout, and an agent who changed a capacity field on the way
  /// past would have had the ENTIRE save refused for it. So Step 2 freezes
  /// instead: the refusal becomes something the screen states up front rather
  /// than something the agent discovers by losing their other edits.
  ///
  /// Add mode is never frozen — [addBus] has its own status gate, and a bus
  /// that cannot be added never reaches this wizard.
  bool get _layoutFrozen =>
      widget.isEditing && !(_tour?.status.allowsLayoutEdit ?? true);

  /// True when the admin has changed any capacity value from what the edited bus
  /// started with — so the layout (and seat IDs) will be regenerated on save.
  bool get _capacityChanged =>
      widget.isEditing &&
      (_totalSeats != _initTotalSeats ||
          _singleSofaCount != _initSingleSofaCount ||
          _allDoubleBackRow != _initAllDoubleBackRow);

  /// The layout the price step previews its rear-zone / price-band rows against:
  /// the bus's saved layout when editing and the capacity was NOT touched,
  /// otherwise a layout built from the current Step 2 inputs. Keeps the band
  /// editor's row range in sync with a just-changed seat count.
  ///
  /// ADD mode used to bail to null here, which left the band sheet with no
  /// `maxRow` — it accepted "row 12 to 20" on a bus that would only ever have
  /// 7 rows, then [_sanitizedBands] silently clamped it at save time and the
  /// range appeared to change by itself. The capacity inputs are all known by
  /// Step 3, and these are the exact arguments [_save] already builds the real
  /// layout with, so previewing against them costs nothing and lets the sheet
  /// clamp at entry instead.
  BusLayout? get _previewLayout {
    if (widget.isEditing && !_capacityChanged) return widget.existing?.layout;
    return _generateLayout();
  }

  String get _subtitle {
    final tour = _tour;
    if (tour == null) return '';
    return '${tour.title} · $_effectiveSlotLabel';
  }

  /// Seed the common-path fields on the FIRST build in plain add mode. Edit and
  /// duplicate both set [_priceInitialized] in [initState], so this whole block
  /// is skipped for them (their fields are already seeded from the source bus).
  ///
  /// Price follows the tour's per-seat rate (existing behaviour); departure
  /// follows the tour's departure time; boarding follows the tour's most
  /// recently added bus (buses on one tour usually share a boarding point).
  /// All three stay fully editable — this only removes the retype/re-open cost
  /// on the common path.
  void _maybeSeedFromTour() {
    if (_priceInitialized) return;
    final tour = _tour;
    if (tour == null) return;
    if (tour.pricePerSeat > 0) {
      _price.text = tour.pricePerSeat.toStringAsFixed(0);
    }
    _departureTime = timeOfDayFromHhmm(tour.departureTime);
    final lastBoarding = tour.buses.isNotEmpty
        ? tour.buses.last.boardingPoint.trim()
        : '';
    if (lastBoarding.isNotEmpty) {
      _boardingPoint.text = lastBoarding;
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
    // Leaving Identity is a blur for the whole step, so run the plate check
    // here too: tapping Next straight off the keyboard never blurs the field,
    // and the collision would otherwise only surface two steps later on Save.
    if (_currentStep == 0 && !_validateBusNumber()) return;
    HapticFeedback.selectionClick();
    final idx = _indexInSequence;
    if (idx < _stepSequence.length - 1) {
      setState(() => _currentStep = _stepSequence[idx + 1]);
    }
  }

  /// Step BACKWARDS through the wizard — the bottom Back pill's job. On the
  /// first step there is nowhere left to go, so it leaves (guarded, same as
  /// the app-bar chevron).
  void _goBack() {
    HapticFeedback.selectionClick();
    final idx = _indexInSequence;
    if (idx > 0) {
      setState(() => _currentStep = _stepSequence[idx - 1]);
    } else {
      _confirmExit();
    }
  }

  /// LEAVE the wizard. The app-bar chevron is the app's universal "close this
  /// screen" affordance on every other screen, so here it closes too instead
  /// of silently walking back a step — walking back is the bottom Back pill.
  ///
  /// Guarded when there is unsaved work, so the chevron can no longer discard
  /// a half-filled form without a word.
  Future<void> _confirmExit() async {
    if (_dirty) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('add_bus.exit_confirm_title'),
        message: tr('add_bus.exit_confirm_msg'),
        confirmLabel: tr('add_bus.exit_confirm_cta'),
        destructive: true,
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    AppNav.pop(context);
  }

  /// True when more single sofas were requested than there are sleeper berths.
  /// Surfaced inline under the single-sofa stepper and blocks advancing.
  bool get _singleSofaInvalid => _singleSofaCount > _sleeperSeats;

  bool get _canAdvance => switch (_currentStep) {
    // Identity has no hard-required field — bus number is optional and can
    // be filled in later when the owner confirms the vehicle. It must not
    // COLLIDE, though: a duplicate plate fails at the database with an
    // error no one can act on, so the blur check gates Next.
    0 => _busNumberError == null,
    // Capacity advances only when the layout is buildable. The invalid
    // state is shown inline under the single-sofa stepper.
    1 => !_singleSofaInvalid,
    2 => _bandsCoverEveryRow,
    _ => false,
  };

  /// A bus is priced EITHER uniformly OR by bands, never a mix (owner,
  /// 2026-10-25). In bands mode every row must sit in a band — a gap would
  /// otherwise be priced from a leftover per-seat value (₹0.14 on one live
  /// bus). Unknown layout (editing a bus whose grid has not loaded) can't be
  /// checked here; [_save] re-checks once it has the real row count.
  bool get _bandsCoverEveryRow {
    if (_priceMode != _PriceMode.bands) return true;
    if (_priceBands.isEmpty) return false;
    final rows = _previewLayout?.rows;
    if (rows == null) return true;
    return PriceBand.uncoveredRows(_priceBands, rows).isEmpty;
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
      setState(() {
        _departureTime = picked;
        _dirty = true;
      });
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _maybeSeedFromTour();
    final c = UgamColors.of(context);

    // The tour is the wizard's whole context: its title, the slot number, the
    // per-seat default, and the row every save writes into. Without it the form
    // used to render as if fine and only fail at Save with "Tour not found" —
    // after the agent had typed the entire bus in. State it up front, and offer
    // the retry, because the usual cause is a list that has not finished
    // loading rather than a tour that is genuinely gone.
    if (_tour == null) return _missingTour(c);

    return PopScope(
      // Android's back gesture and iOS's edge-swipe are the SAME intent as the
      // Back pill and the chevron, and they used to bypass both: a system back
      // popped the whole wizard, discarding every step, without a word. Held
      // whenever there is somewhere to walk back to OR anything to lose.
      canPop: _isFirstStep && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Mid-wizard, back means "previous step" — never "throw this away".
        if (!_isFirstStep) {
          _goBack();
          return;
        }
        _confirmExit();
      },
      child: _wizard(c),
    );
  }

  Widget _wizard(UgamColorSet c) {
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              title: widget.isEditing
                  ? tr('add_bus.title_edit')
                  : tr('add_bus.title'),
              subtitle: _subtitle.isEmpty ? null : _subtitle,
              // Closes the wizard (guarded), matching every other screen's
              // chevron. Stepping back is the bottom Back pill's job.
              onBack: _confirmExit,
            ),
            _WizardProgress(
              c: c,
              steps: _stepSequence.length,
              index: _indexInSequence,
              label: _stepLabel,
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: UgamMotion.sheet,
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

  /// Shown instead of the form when [_tour] cannot be resolved. Retry simply
  /// re-reads the controller — the tour list is in memory, so a tour that
  /// arrives a beat after the push resolves on the first tap.
  Widget _missingTour(UgamColorSet c) {
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              title: widget.isEditing
                  ? tr('add_bus.title_edit')
                  : tr('add_bus.title'),
            ),
            Expanded(
              child: UgamEmpty(
                icon: Icons.directions_bus_filled_outlined,
                title: tr('add_bus.not_found.title'),
                body: tr('add_bus.not_found.body'),
                cta: UgamButton(
                  label: tr('app.action.retry'),
                  icon: Icons.refresh_rounded,
                  kind: UgamButtonKind.neutral,
                  onPressed: () => setState(() {}),
                ),
              ),
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
          busNumberFocus: _busNumberFocus,
          busNumberError: _busNumberError,
          onToggleAC: (v) => setState(() {
            _isAC = v;
            _dirty = true;
          }),
          onPickDepartureTime: _pickDepartureTime,
          onAnyChange: _markDirty,
          // Typing clears a stale collision immediately (the check itself only
          // re-runs on blur) so the agent is not left staring at an error that
          // no longer describes what is in the field.
          onBusNumberChanged: () {
            _markDirty();
            if (_busNumberError != null) {
              setState(() => _busNumberError = null);
            }
          },
        );
      case 1:
        return _Step2Capacity(
          c: c,
          totalSeats: _totalSeats,
          singleSofaCount: _singleSofaCount,
          sleeperSeats: _sleeperSeats,
          singleSofaSummary: _singleSofaSummary,
          allDoubleBackRow: _allDoubleBackRow,
          onAllDoubleBackRow: (v) => setState(() {
            _allDoubleBackRow = v;
            _dirty = true;
          }),
          // Edit mode only: re-apply the current seat engine to a bus whose
          // layout was saved under the old engine. Null in add mode (hides it),
          // and null once the chart is locked — the write would be refused.
          onRegenerate: (widget.isEditing && !_layoutFrozen)
              ? _regenerateLayout
              : null,
          // Locked/completed tour: the seat plan is frozen, the rest of the bus
          // is not. Stated here so the agent does not change a capacity field
          // and lose their driver/pricing edits to the refusal it would trigger.
          frozenNotice: _layoutFrozen ? tr('add_bus.layout_frozen') : null,
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
            _dirty = true;
          }),
          onSingleSofa: (v) => setState(() {
            _singleSofaCount = v;
            _dirty = true;
          }),
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
          onBandsChanged: (bands) => setState(() {
            _priceBands = bands;
            _dirty = true;
          }),
          layout: _previewLayout,
          tour: _tour,
          totalSeats: _totalSeats,
          onChanged: _markDirty,
          // Mode + stash are wizard-level so stepping back to Capacity and
          // returning does not silently reset the pricing tab.
          mode: _priceMode,
          onModeChanged: (m) => setState(() => _priceMode = m),
          stashedBands: _stashedBands,
          onStashBands: (b) => _stashedBands = b,
          rentIncludesFuel: _rentIncludesFuel,
          onRentIncludesFuelChanged: (v) => setState(() {
            _rentIncludesFuel = v;
            _dirty = true;
          }),
        );
    }
  }
}
