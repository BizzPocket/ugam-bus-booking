import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_type.dart';
import '../models/seat_layout.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';

/// 3-step wizard for adding (or editing) a bus on a tour.
///
/// Add mode:  Step 1 → Step 2 → Step 3 (identity → capacity → price)
/// Edit mode: Step 1 → Step 3            (structural fields are locked
///            because passengers may already hold seat IDs)
///
/// All controller calls (`addBus`, `updateBus`) and the layout-generation
/// math are preserved bit-for-bit from the legacy single-page form — only
/// the presentation is rebuilt.
class AddBusScreen extends StatefulWidget {
  final String tourId;
  final Bus? existing;

  const AddBusScreen({
    super.key,
    required this.tourId,
    this.existing,
  });

  bool get isEditing => existing != null;

  @override
  State<AddBusScreen> createState() => _AddBusScreenState();
}

class _AddBusScreenState extends State<AddBusScreen> {
  // ── Form state (1:1 with the legacy screen) ─────────────────────────
  final _slotLabel = TextEditingController();
  final _busNumber = TextEditingController();
  final _driverName = TextEditingController();
  final _driverPhone = TextEditingController();
  final _price = TextEditingController();
  final _singleSofaPrice = TextEditingController();
  final _doubleSofaPrice = TextEditingController();
  final _seaterPrice = TextEditingController();
  final _rearRows = TextEditingController();
  final _rearPrice = TextEditingController();
  bool _isAC = true;
  int _totalSeats = 40;
  BusType _busType = BusType.sleeper;
  int _seaterCountForMixed = 6;
  int _singleSofaCount = 0;
  bool _hasBalcony = false;
  bool _saving = false;
  bool _priceInitialized = false;

  // ── Wizard state ────────────────────────────────────────────────────
  /// 0 = identity, 1 = capacity (add only), 2 = price.
  /// In edit mode the user moves from 0 → 2 directly (step 1 is skipped).
  int _currentStep = 0;

  /// Steps the wizard actually walks through, in order.
  List<int> get _stepSequence =>
      widget.isEditing ? const [0, 2] : const [0, 1, 2];

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
      _driverName.text = e.driverName;
      _driverPhone.text = e.driverPhone;
      _price.text = e.pricePerSeat > 0
          ? e.pricePerSeat.toStringAsFixed(0)
          : '';
      if (e.singleSofaPrice != null) {
        _singleSofaPrice.text = e.singleSofaPrice!.toStringAsFixed(0);
      }
      if (e.doubleSofaPrice != null) {
        _doubleSofaPrice.text = e.doubleSofaPrice!.toStringAsFixed(0);
      }
      if (e.seaterPrice != null) {
        _seaterPrice.text = e.seaterPrice!.toStringAsFixed(0);
      }
      if (e.rearRows > 0) {
        _rearRows.text = '${e.rearRows}';
      }
      if (e.rearPrice != null) {
        _rearPrice.text = e.rearPrice!.toStringAsFixed(0);
      }
      _isAC = e.isAC;
      _totalSeats = e.totalSeats;
      _busType = BusType.fromString(e.busType);
      _priceInitialized = true;
    }
  }

  @override
  void dispose() {
    _slotLabel.dispose();
    _busNumber.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    _price.dispose();
    _singleSofaPrice.dispose();
    _doubleSofaPrice.dispose();
    _seaterPrice.dispose();
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
    if (tour == null) return 'Bus 1';
    final e = widget.existing;
    if (e != null) {
      final idx = tour.buses.indexWhere((b) => b.id == e.id);
      return 'Bus ${(idx < 0 ? tour.buses.length : idx) + 1}';
    }
    return 'Bus ${tour.buses.length + 1}';
  }

  int get _sleeperSeats => switch (_busType) {
        BusType.sleeper => _totalSeats,
        BusType.mixed => _totalSeats - _seaterCountForMixed,
        BusType.seater => 0,
      };

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

  String get _mixedSummary {
    final sleeperCount = _totalSeats - _seaterCountForMixed;
    final sleeperKey = sleeperCount == 1
        ? 'add_bus.summary.mixed_one_sleeper'
        : 'add_bus.summary.mixed_many_sleeper';
    final seaterLabel = _seaterCountForMixed == 1
        ? tr('add_bus.summary.seater')
        : tr('add_bus.summary.seaters');
    return tr(sleeperKey, namedArgs: {
      'sleeper': '$sleeperCount',
      'seater': '$_seaterCountForMixed',
      'seater_label': seaterLabel,
    });
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
    return tr(summaryKey, namedArgs: {
      'single': '$_singleSofaCount',
      'double': '$doubleCount',
      'double_label': doubleLabel,
    });
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

  bool get _canAdvance {
    switch (_currentStep) {
      case 0:
        // Identity has no hard-required field — bus number is optional and can
        // be filled in later when the owner confirms the vehicle.
        return true;
      case 1:
        // Capacity step always advances; layout validation happens on save.
        return true;
      case 2:
        return true;
    }
    return false;
  }

  // ── Save ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!widget.isEditing) {
      if (_busType == BusType.mixed && _seaterCountForMixed >= _totalSeats) {
        AppSnackBar.error(tr('add_bus.snackbar.error_seater_count'));
        return;
      }
      if (_singleSofaCount > _sleeperSeats) {
        AppSnackBar.error(tr('add_bus.snackbar.error_single_sofa'));
        return;
      }
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

    double? parseOpt(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : double.tryParse(t);
    }

    final singleSofaPrice = parseOpt(_singleSofaPrice);
    final doubleSofaPrice = parseOpt(_doubleSofaPrice);
    final seaterPrice = parseOpt(_seaterPrice);

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
        final rowCount = source.layout?.rows ?? rearRowsRaw;
        final rearRows = rearRowsRaw.clamp(0, rowCount);
        final updated = source.copyWith(
          name: slotLabel,
          busNumber: _busNumber.text.trim(),
          driverName: _driverName.text.trim(),
          driverPhone: _driverPhone.text.trim(),
          isAC: _isAC,
          pricePerSeat: pricePerSeat,
          singleSofaPrice: singleSofaPrice,
          doubleSofaPrice: doubleSofaPrice,
          seaterPrice: seaterPrice,
          rearRows: rearRows,
          rearPrice: rearRows == 0 ? null : rearPrice,
        );
        await _tourCtrl.updateBus(widget.tourId, updated);
        if (!mounted) return;
        AppSnackBar.success('Updated ${updated.name}.');
        Get.back();
        return;
      }

      final layout = BusLayout.generate(
        busType: _busType,
        totalSeats: _totalSeats,
        seaterCount: _busType == BusType.mixed ? _seaterCountForMixed : 0,
        singleSofaCount: _singleSofaCount,
        hasBalcony: _hasBalcony,
      );

      final rearRows = rearRowsRaw.clamp(0, layout.rows);

      final bus = Bus(
        name: slotLabel,
        busNumber: _busNumber.text.trim(),
        driverName: _driverName.text.trim(),
        driverPhone: _driverPhone.text.trim(),
        isAC: _isAC,
        busType: _busType.displayName,
        totalSeatsLegacy: _totalSeats,
        pricePerSeat: pricePerSeat,
        singleSofaPrice: singleSofaPrice,
        doubleSofaPrice: doubleSofaPrice,
        seaterPrice: seaterPrice,
        rearRows: rearRows,
        rearPrice: rearRows == 0 ? null : rearPrice,
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
              title: widget.isEditing ? 'Edit Bus' : tr('add_bus.title'),
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
          driverName: _driverName,
          driverPhone: _driverPhone,
          isAC: _isAC,
          slotBadge: _slotPositionLabel,
          onToggleAC: (v) => setState(() => _isAC = v),
          onAnyChange: () => setState(() {}),
        );
      case 1:
        return _Step2Capacity(
          c: c,
          busType: _busType,
          totalSeats: _totalSeats,
          seaterCountForMixed: _seaterCountForMixed,
          singleSofaCount: _singleSofaCount,
          sleeperSeats: _sleeperSeats,
          mixedSummary: _mixedSummary,
          singleSofaSummary: _singleSofaSummary,
          hasOddSleeperBerth: _hasOddSleeperBerth,
          hasBalcony: _hasBalcony,
          onBusType: (t) => setState(() {
            _busType = t;
            if (_singleSofaCount > _sleeperSeats) {
              _singleSofaCount = _sleeperSeats;
            }
          }),
          onTotalSeats: (v) => setState(() {
            _totalSeats = v;
            if (_seaterCountForMixed >= v) {
              _seaterCountForMixed = (v - 1).clamp(0, v);
            }
            if (_singleSofaCount > _sleeperSeats) {
              _singleSofaCount = _sleeperSeats;
            }
          }),
          onSeaterCount: (v) => setState(() {
            _seaterCountForMixed = v;
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
          singleSofaPrice: _singleSofaPrice,
          doubleSofaPrice: _doubleSofaPrice,
          seaterPrice: _seaterPrice,
          rearRows: _rearRows,
          rearPrice: _rearPrice,
          layout: widget.existing?.layout,
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
                    Text(title,
                        style: UgamText.titleL.copyWith(color: c.ink)),
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
                'Step ${index + 1} / $steps',
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
            : (isEditing ? 'Save changes' : tr('add_bus.action.save')))
        : 'Next';
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
            Text('Back',
                style: UgamText.titleS.copyWith(color: c.ink)),
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
  final TextEditingController driverName;
  final TextEditingController driverPhone;
  final bool isAC;
  final String slotBadge;
  final ValueChanged<bool> onToggleAC;
  final VoidCallback onAnyChange;

  const _Step1Identity({
    required this.c,
    required this.busName,
    required this.busNumber,
    required this.driverName,
    required this.driverPhone,
    required this.isAC,
    required this.slotBadge,
    required this.onToggleAC,
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
          eyebrow: 'IDENTITY',
          title: 'Who is this bus?',
          body: 'Name the bus, add its registration and driver. The slot '
              '($slotBadge) is assigned automatically by position; driver '
              'fields can stay blank until the owner confirms.',
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: 'Slot'),
        const SizedBox(height: UgamSpacing.sm),
        _SlotBadge(c: c, label: slotBadge),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: 'Bus name'),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: busName,
          hint: 'e.g. Volvo A/C Sleeper',
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: 'Bus number'),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: busNumber,
          hint: 'e.g. GJ-05-AB-1234',
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: 'Driver name'),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: driverName,
          hint: 'Add later when owner confirms',
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: 'Driver phone'),
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
                  Text('AC bus',
                      style:
                          UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 14)),
                  Text(
                    value
                        ? 'Air-conditioned coach'
                        : 'Non-AC / fan-cooled',
                    style:
                        UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: c.accent,
            ),
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
  final BusType busType;
  final int totalSeats;
  final int seaterCountForMixed;
  final int singleSofaCount;
  final int sleeperSeats;
  final String mixedSummary;
  final String singleSofaSummary;
  final bool hasOddSleeperBerth;
  final bool hasBalcony;
  final ValueChanged<BusType> onBusType;
  final ValueChanged<int> onTotalSeats;
  final ValueChanged<int> onSeaterCount;
  final ValueChanged<int> onSingleSofa;
  final ValueChanged<bool> onBalcony;

  const _Step2Capacity({
    required this.c,
    required this.busType,
    required this.totalSeats,
    required this.seaterCountForMixed,
    required this.singleSofaCount,
    required this.sleeperSeats,
    required this.mixedSummary,
    required this.singleSofaSummary,
    required this.hasOddSleeperBerth,
    required this.hasBalcony,
    required this.onBusType,
    required this.onTotalSeats,
    required this.onSeaterCount,
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
          eyebrow: 'CAPACITY',
          title: 'Pick the layout',
          body: 'How many seats — and what kind. Once saved, the layout is '
              'locked because passengers will start holding seat IDs.',
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: 'Bus type'),
        const SizedBox(height: UgamSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _BusTypeCard(
                c: c,
                type: BusType.sleeper,
                active: busType == BusType.sleeper,
                icon: Icons.bed_rounded,
                subline: 'berths',
                onTap: () => onBusType(BusType.sleeper),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _BusTypeCard(
                c: c,
                type: BusType.mixed,
                active: busType == BusType.mixed,
                icon: Icons.view_agenda_rounded,
                subline: 'mix',
                onTap: () => onBusType(BusType.mixed),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _BusTypeCard(
                c: c,
                type: BusType.seater,
                active: busType == BusType.seater,
                icon: Icons.event_seat_rounded,
                subline: 'seats',
                onTap: () => onBusType(BusType.seater),
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: 'Total seats'),
        const SizedBox(height: UgamSpacing.sm),
        _StepperRow(
          c: c,
          value: totalSeats,
          min: 1,
          max: 100,
          onChanged: onTotalSeats,
        ),
        if (busType == BusType.mixed) ...[
          const SizedBox(height: UgamSpacing.xl),
          _Label(c: c, text: 'Seater count (rest are sleeper)'),
          const SizedBox(height: UgamSpacing.sm),
          _StepperRow(
            c: c,
            value: seaterCountForMixed,
            min: 1,
            max: totalSeats - 1,
            onChanged: onSeaterCount,
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(mixedSummary,
              style: UgamText.caption.copyWith(color: c.ink2)),
        ],
        if (sleeperSeats > 0) ...[
          const SizedBox(height: UgamSpacing.xl),
          _Label(c: c, text: 'Single sofa count (rest become double sofa)'),
          const SizedBox(height: UgamSpacing.sm),
          _StepperRow(
            c: c,
            value: singleSofaCount,
            min: 0,
            max: sleeperSeats,
            onChanged: onSingleSofa,
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(singleSofaSummary,
              style: UgamText.caption.copyWith(color: c.ink2)),
          if (hasOddSleeperBerth) ...[
            const SizedBox(height: UgamSpacing.sm),
            _OddBerthWarning(c: c),
          ],
          const SizedBox(height: UgamSpacing.xl),
          _Label(c: c, text: 'Back row (balcony)'),
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
                    'Add a full-width back row with an upper + lower berth in '
                    'the aisle (+2 berths).',
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
              'Odd sleeper count — one berth can’t pair into a double, so '
              'it’s placed as an extra single sofa. Adjust the counts if '
              'that’s not what you want.',
              style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusTypeCard extends StatelessWidget {
  final UgamColorSet c;
  final BusType type;
  final bool active;
  final IconData icon;
  final String subline;
  final VoidCallback onTap;

  const _BusTypeCard({
    required this.c,
    required this.type,
    required this.active,
    required this.icon,
    required this.subline,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.sm,
          vertical: UgamSpacing.lg,
        ),
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(
            color: active ? c.accent : c.border,
            width: active ? 1.6 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: active ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 20,
                color: active ? c.onAccent : c.ink,
              ),
            ),
            const SizedBox(height: UgamSpacing.sm),
            Text(
              type.displayName,
              style: UgamText.titleS.copyWith(
                color: active ? c.accent : c.ink,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subline,
              style: UgamText.micro.copyWith(
                color: active ? c.accent : c.ink3,
                fontSize: 9.5,
              ),
            ),
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
        child: Icon(
          icon,
          size: 20,
          color: enabled ? c.ink : c.ink3,
        ),
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
  final TextEditingController singleSofaPrice;
  final TextEditingController doubleSofaPrice;
  final TextEditingController seaterPrice;
  final TextEditingController rearRows;
  final TextEditingController rearPrice;

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
    required this.singleSofaPrice,
    required this.doubleSofaPrice,
    required this.seaterPrice,
    required this.rearRows,
    required this.rearPrice,
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

  @override
  void initState() {
    super.initState();
    // Auto-expand the per-type overrides if any are already set (edit mode).
    _overridesOpen = widget.singleSofaPrice.text.trim().isNotEmpty ||
        widget.doubleSofaPrice.text.trim().isNotEmpty ||
        widget.seaterPrice.text.trim().isNotEmpty;
  }

  UgamColorSet get c => widget.c;
  Tour? get tour => widget.tour;
  TextEditingController get price => widget.price;
  TextEditingController get singleSofaPrice => widget.singleSofaPrice;
  TextEditingController get doubleSofaPrice => widget.doubleSofaPrice;
  TextEditingController get seaterPrice => widget.seaterPrice;
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
        ? tr('add_bus.hint.price_default', namedArgs: {
            'price': tour!.pricePerSeat.toStringAsFixed(0),
          })
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
          eyebrow: 'PRICE',
          title: 'Set the per-seat price',
          body: 'Defaults to the tour-level price. Overriding here only '
              'affects this bus.',
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: 'Price per seat'),
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
        const SizedBox(height: UgamSpacing.xl),
        _buildRearZone(),
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
              Text('PREVIEW',
                  style: UgamText.micro.copyWith(color: c.ink3)),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                slotLabel,
                style: UgamText.titleM.copyWith(color: c.ink),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (busNumber.isNotEmpty) busNumber,
                  isAC ? 'AC' : 'Non-AC',
                  '$totalSeats seats',
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
                    Icon(Icons.calculate_rounded,
                        size: 18, color: c.accent),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        '$totalSeats seats × ₹${per.toStringAsFixed(0)}',
                        style: UgamText.bodyStrong
                            .copyWith(color: c.ink, fontSize: 13),
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
                'if fully booked',
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
              : tr('add_bus.hint.rear_rows_max', namedArgs: {'max': '$rowCount'}),
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
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      prefix: '₹',
                      onChanged: (_) => onChanged(),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    _RearZoneLegend(c: c, rearRows: rearRows, layout: widget.layout),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
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
                          style: UgamText.bodyStrong
                              .copyWith(color: c.ink, fontSize: 14),
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
                        _Label(c: c, text: 'Single sofa price'),
                        const SizedBox(height: UgamSpacing.sm),
                        _Field(
                          c: c,
                          controller: singleSofaPrice,
                          hint: 'Defaults to base price',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          ],
                          prefix: '₹',
                          onChanged: (_) => onChanged(),
                        ),
                        const SizedBox(height: UgamSpacing.lg),
                        _Label(c: c, text: 'Double sofa price'),
                        const SizedBox(height: UgamSpacing.sm),
                        _Field(
                          c: c,
                          controller: doubleSofaPrice,
                          hint: 'Defaults to base price',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          ],
                          prefix: '₹',
                          onChanged: (_) => onChanged(),
                        ),
                        const SizedBox(height: UgamSpacing.lg),
                        _Label(c: c, text: 'Seater price'),
                        const SizedBox(height: UgamSpacing.sm),
                        _Field(
                          c: c,
                          controller: seaterPrice,
                          hint: 'Defaults to base price',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
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
                      ? tr('add_bus.rear_zone.legend_plain',
                          namedArgs: {'rows': '$rearRows'})
                      : tr('add_bus.rear_zone.legend', namedArgs: {
                          'rows': '$rearRows',
                          'total': '${l.rows}',
                        }),
                  style:
                      UgamText.caption.copyWith(color: c.ink2, height: 1.4),
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
        Text(body,
            style: UgamText.body
                .copyWith(color: c.ink2, fontSize: 13, height: 1.5)),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  final UgamColorSet c;
  final String text;
  const _Label({
    required this.c,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink2));
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
            'auto',
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
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
