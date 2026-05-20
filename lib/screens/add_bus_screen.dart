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
  bool _isAC = true;
  int _totalSeats = 40;
  BusType _busType = BusType.sleeper;
  int _seaterCountForMixed = 6;
  int _singleSofaCount = 0;
  bool _saving = false;
  bool _priceInitialized = false;
  bool _slotLabelInitialized = false;

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
      _isAC = e.isAC;
      _totalSeats = e.totalSeats;
      _busType = BusType.fromString(e.busType);
      _priceInitialized = true;
      _slotLabelInitialized = true;
    }
  }

  @override
  void dispose() {
    _slotLabel.dispose();
    _busNumber.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    _price.dispose();
    super.dispose();
  }

  TourController get _tourCtrl => Get.find<TourController>();
  Tour? get _tour => _tourCtrl.getTour(widget.tourId);

  String get _defaultSlotLabel {
    final tour = _tour;
    if (tour == null) return 'Bus 1';
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
        ? _defaultSlotLabel
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

  void _maybeSeedSlotLabel() {
    if (_slotLabelInitialized) return;
    final tour = _tour;
    if (tour == null) return;
    _slotLabel.text = _defaultSlotLabel;
    _slotLabelInitialized = true;
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

  String get _singleSofaSummary {
    final doubleCount = _sleeperSeats - _singleSofaCount;
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
        // Bus number required to move past identity.
        return _busNumber.text.trim().isNotEmpty;
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

    final slotLabel = _slotLabel.text.trim().isEmpty
        ? _defaultSlotLabel
        : _slotLabel.text.trim();

    setState(() => _saving = true);
    try {
      if (widget.isEditing) {
        final source = widget.existing!;
        final updated = source.copyWith(
          name: slotLabel,
          busNumber: _busNumber.text.trim(),
          driverName: _driverName.text.trim(),
          driverPhone: _driverPhone.text.trim(),
          isAC: _isAC,
          pricePerSeat: pricePerSeat,
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
      );

      final bus = Bus(
        name: slotLabel,
        busNumber: _busNumber.text.trim(),
        driverName: _driverName.text.trim(),
        driverPhone: _driverPhone.text.trim(),
        isAC: _isAC,
        busType: _busType.displayName,
        totalSeatsLegacy: _totalSeats,
        pricePerSeat: pricePerSeat,
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
    _maybeSeedSlotLabel();
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
          slotLabel: _slotLabel,
          busNumber: _busNumber,
          driverName: _driverName,
          driverPhone: _driverPhone,
          isAC: _isAC,
          slotHint: _defaultSlotLabel,
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
        );
      case 2:
      default:
        return _Step3Price(
          c: c,
          price: _price,
          tour: _tour,
          slotLabel: _slotLabel.text.trim().isEmpty
              ? _defaultSlotLabel
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
  final TextEditingController slotLabel;
  final TextEditingController busNumber;
  final TextEditingController driverName;
  final TextEditingController driverPhone;
  final bool isAC;
  final String slotHint;
  final ValueChanged<bool> onToggleAC;
  final VoidCallback onAnyChange;

  const _Step1Identity({
    required this.c,
    required this.slotLabel,
    required this.busNumber,
    required this.driverName,
    required this.driverPhone,
    required this.isAC,
    required this.slotHint,
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
          body: 'Slot label, registration, and driver contact. '
              'Driver fields can stay blank until the owner confirms.',
        ),
        const SizedBox(height: UgamSpacing.xl),
        _Label(c: c, text: 'Slot label'),
        const SizedBox(height: UgamSpacing.sm),
        _Field(
          c: c,
          controller: slotLabel,
          hint: slotHint,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => onAnyChange(),
        ),
        const SizedBox(height: UgamSpacing.lg),
        _Label(c: c, text: 'Bus number', required: true),
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
  final ValueChanged<BusType> onBusType;
  final ValueChanged<int> onTotalSeats;
  final ValueChanged<int> onSeaterCount;
  final ValueChanged<int> onSingleSofa;

  const _Step2Capacity({
    required this.c,
    required this.busType,
    required this.totalSeats,
    required this.seaterCountForMixed,
    required this.singleSofaCount,
    required this.sleeperSeats,
    required this.mixedSummary,
    required this.singleSofaSummary,
    required this.onBusType,
    required this.onTotalSeats,
    required this.onSeaterCount,
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
        ],
        const SizedBox(height: UgamSpacing.xl),
      ],
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

class _Step3Price extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController price;
  final Tour? tour;
  final String slotLabel;
  final String busNumber;
  final bool isAC;
  final int totalSeats;
  final VoidCallback onChanged;

  const _Step3Price({
    required this.c,
    required this.price,
    required this.tour,
    required this.slotLabel,
    required this.busNumber,
    required this.isAC,
    required this.totalSeats,
    required this.onChanged,
  });

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
  final bool required;

  const _Label({
    required this.c,
    required this.text,
    this.required = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(text.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink2)),
        if (required) ...[
          const SizedBox(width: 4),
          Text('*', style: UgamText.micro.copyWith(color: c.danger)),
        ],
      ],
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
