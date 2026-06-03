import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../utils/app_snackbar.dart';

class EditTourScreen extends StatefulWidget {
  final String tourId;
  const EditTourScreen({super.key, required this.tourId});

  @override
  State<EditTourScreen> createState() => _EditTourScreenState();
}

class _EditTourScreenState extends State<EditTourScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _fromCtrl;
  late final TextEditingController _toCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _descCtrl;
  DateTime? _departureDate;
  DateTime? _returnDate;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  Timer? _fieldDebounce;

  // Originals captured at initState — used to detect dirty state and
  // to power the "Cancel changes" action.
  late final String _origTitle;
  late final String _origFrom;
  late final String _origTo;
  late final String _origPrice;
  late final String _origDesc;
  DateTime? _origDeparture;
  DateTime? _origReturn;

  @override
  void initState() {
    super.initState();
    final tour = Get.find<TourController>().getTour(widget.tourId);
    _origTitle = tour?.title ?? '';
    _origFrom = tour?.fromCity ?? '';
    _origTo = tour?.toCity ?? '';
    _origPrice = tour != null ? tour.pricePerSeat.toStringAsFixed(0) : '';
    _origDesc = tour?.description ?? '';
    _origDeparture = tour?.departureDate;
    _origReturn = tour?.returnDate;

    _titleCtrl = TextEditingController(text: _origTitle);
    _fromCtrl = TextEditingController(text: _origFrom);
    _toCtrl = TextEditingController(text: _origTo);
    _priceCtrl = TextEditingController(text: _origPrice);
    _descCtrl = TextEditingController(text: _origDesc);
    _departureDate = _origDeparture;
    _returnDate = _origReturn;

    _titleCtrl.addListener(_onFieldChanged);
    _fromCtrl.addListener(_onFieldChanged);
    _toCtrl.addListener(_onFieldChanged);
    _priceCtrl.addListener(_onFieldChanged);
    _descCtrl.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    _fieldDebounce?.cancel();
    _fieldDebounce = Timer(const Duration(milliseconds: 90), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_onFieldChanged);
    _fromCtrl.removeListener(_onFieldChanged);
    _toCtrl.removeListener(_onFieldChanged);
    _priceCtrl.removeListener(_onFieldChanged);
    _descCtrl.removeListener(_onFieldChanged);
    _fieldDebounce?.cancel();
    _titleCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  bool get _isDirty {
    if (_titleCtrl.text != _origTitle) return true;
    if (_fromCtrl.text != _origFrom) return true;
    if (_toCtrl.text != _origTo) return true;
    if (_priceCtrl.text != _origPrice) return true;
    if (_descCtrl.text != _origDesc) return true;
    if (_departureDate != _origDeparture) return true;
    if (_returnDate != _origReturn) return true;
    return false;
  }

  void _cancelChanges() {
    setState(() {
      _titleCtrl.text = _origTitle;
      _fromCtrl.text = _origFrom;
      _toCtrl.text = _origTo;
      _priceCtrl.text = _origPrice;
      _descCtrl.text = _origDesc;
      _departureDate = _origDeparture;
      _returnDate = _origReturn;
    });
  }

  Future<void> _pickDate(bool isReturn) async {
    final initial = isReturn
        ? (_returnDate ?? _departureDate ?? DateTime.now())
        : (_departureDate ?? DateTime.now());
    final first = isReturn
        ? (_departureDate ??
            DateTime.now().subtract(const Duration(days: 365)))
        : DateTime.now().subtract(const Duration(days: 365));

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) {
      setState(() {
        if (isReturn) {
          _returnDate = picked;
        } else {
          _departureDate = picked;
          if (_returnDate != null && _returnDate!.isBefore(picked)) {
            _returnDate = null;
          }
        }
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_departureDate == null) {
      AppSnackBar.warning(tr('edit_tour.error_select_start_date'));
      return;
    }

    setState(() => _saving = true);
    try {
      await Get.find<TourController>().editTour(
        tourId: widget.tourId,
        title: _titleCtrl.text.trim(),
        fromCity: _fromCtrl.text.trim(),
        toCity: _toCtrl.text.trim(),
        departureDate: _departureDate!,
        returnDate: _returnDate,
        pricePerSeat: double.tryParse(_priceCtrl.text) ?? 0,
        description:
            _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      );
      AppSnackBar.success(tr('edit_tour.snack_updated'));
      Get.back();
    } catch (_) {
      AppSnackBar.error(tr('edit_tour.snack_save_failed'));
      setState(() => _saving = false);
    }
  }

  /// One-tap "apply this price sheet to all buses". Lets the agent pick a
  /// source bus, then copies its pricing — base price, the three per-type
  /// overrides, the rear zone, and the flexible price bands — onto every OTHER
  /// bus on this tour. Per-bus edits stay possible afterwards; this is just a
  /// fast way to make one bus the template for the rest.
  Future<void> _applyPriceSheet() async {
    final ctrl = Get.find<TourController>();
    final tour = ctrl.getTour(widget.tourId);
    if (tour == null) return;
    final buses = tour.buses;
    if (buses.length < 2) {
      AppSnackBar.warning(
        'Add at least two buses to copy a price sheet between them.',
      );
      return;
    }

    final c = UgamColors.of(context);
    final source = await UgamSheet.show<Bus>(
      context,
      title: 'Apply price sheet',
      builder: (sheetCtx) {
        final sc = UgamColors.of(sheetCtx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pick the bus whose prices become the template. Its base price, '
              'per-type overrides, rear zone, and price bands copy to every '
              'other bus on this tour.',
              style: UgamText.body
                  .copyWith(color: sc.ink2, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: UgamSpacing.lg),
            for (final b in buses) ...[
              GestureDetector(
                onTap: () => Navigator.of(sheetCtx).pop(b),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  decoration: BoxDecoration(
                    color: sc.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
                    border: Border.all(color: sc.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              b.name,
                              style: UgamText.bodyStrong
                                  .copyWith(color: sc.ink, fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _priceSummary(b),
                              style:
                                  UgamText.caption.copyWith(color: sc.ink2),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: sc.ink3),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
            ],
          ],
        );
      },
    );

    if (source == null || !mounted) return;

    final targets = buses.where((b) => b.id != source.id).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.card,
        title: const Text('Copy price sheet?'),
        content: Text(
          'Copy ${source.name}\'s prices to ${targets.length} other '
          'bus${targets.length == 1 ? '' : 'es'}? This overwrites their '
          'current pricing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      for (final t in targets) {
        final updated = t.copyWith(
          pricePerSeat: source.pricePerSeat,
          singleSofaPrice: source.singleSofaPrice,
          doubleSofaPrice: source.doubleSofaPrice,
          seaterPrice: source.seaterPrice,
          rearRows: source.rearRows,
          rearPrice: source.rearPrice,
          priceBands: List<PriceBand>.from(source.priceBands),
        );
        await ctrl.updateBus(widget.tourId, updated);
      }
      if (!mounted) return;
      AppSnackBar.success(
        'Copied ${source.name}\'s price sheet to ${targets.length} '
        'bus${targets.length == 1 ? '' : 'es'}.',
      );
    } catch (_) {
      if (mounted) AppSnackBar.error('Could not copy the price sheet.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Short price summary for a bus row in the source picker.
  String _priceSummary(Bus b) {
    final parts = <String>['₹${b.pricePerSeat.toStringAsFixed(0)}/seat'];
    final bands = b.priceBands.length + (b.rearRows > 0 ? 1 : 0);
    if (bands > 0) parts.add('$bands band${bands == 1 ? '' : 's'}');
    return parts.join(' · ');
  }

  Future<void> _confirmAndDelete() async {
    final tour = Get.find<TourController>().getTour(widget.tourId);
    if (tour == null) return;

    final pCount = tour.passengers.length;
    final bCount = tour.buses.length;
    final detailParts = <String>[
      '"${tour.title}"',
      if (pCount > 0) '$pCount passenger${pCount == 1 ? '' : 's'}',
      if (bCount > 0)
        '$bCount bus${bCount == 1 ? '' : 'es'} will be unlinked',
    ];
    final detail = detailParts.join(' · ');

    final c = UgamColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.card,
        title: const Text('Delete this tour?'),
        content: Text(
          'This will permanently delete $detail and every booking '
          'request tied to it. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: c.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await Get.find<TourController>().deleteTour(widget.tourId);
      if (!mounted) return;
      AppSnackBar.success('Tour "${tour.title}" deleted.');
      Get.until((route) => route.isFirst);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final dirty = _isDirty;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.md,
                UgamSpacing.sm,
                UgamSpacing.md,
                UgamSpacing.md,
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Get.back(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.arrow_back_rounded,
                          size: 19, color: c.ink),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Text(
                      tr('edit_tour.title'),
                      style: UgamText.titleL.copyWith(color: c.ink),
                    ),
                  ),
                  GestureDetector(
                    onTap: _saving ? null : _confirmAndDelete,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: c.danger.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.delete_outline_rounded,
                          size: 19, color: c.danger),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xl,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _TourPreviewCard(
                      c: c,
                      title: _titleCtrl.text.trim(),
                      fromCity: _fromCtrl.text.trim(),
                      toCity: _toCtrl.text.trim(),
                      departureDate: _departureDate,
                      price: _priceCtrl.text.trim(),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamInput(
                      label: tr('create_tour.label.tour_name'),
                      controller: _titleCtrl,
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    Text(
                      tr('create_tour.label.route').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (MediaQuery.of(context).size.width < 400) ...[
                      UgamInput(controller: _fromCtrl),
                      const SizedBox(height: UgamSpacing.xs),
                      Center(
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: c.accentFill,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Icon(Icons.arrow_downward_rounded,
                              size: 14, color: c.accent),
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.xs),
                      UgamInput(controller: _toCtrl),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(child: UgamInput(controller: _fromCtrl)),
                          Container(
                            margin: const EdgeInsets.symmetric(
                                horizontal: UgamSpacing.sm + 2),
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(Icons.arrow_forward_rounded,
                                size: 14, color: c.accent),
                          ),
                          Expanded(child: UgamInput(controller: _toCtrl)),
                        ],
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    Text(
                      tr('create_tour.label.date_range').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (MediaQuery.of(context).size.width < 400) ...[
                      _DateField(
                        c: c,
                        hint: tr('create_tour.hint.start_date'),
                        date: _departureDate,
                        onTap: () => _pickDate(false),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      _DateField(
                        c: c,
                        hint: tr('create_tour.hint.end_date'),
                        date: _returnDate,
                        onTap: () => _pickDate(true),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: _DateField(
                              c: c,
                              hint: tr('create_tour.hint.start_date'),
                              date: _departureDate,
                              onTap: () => _pickDate(false),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.md),
                          Expanded(
                            child: _DateField(
                              c: c,
                              hint: tr('create_tour.hint.end_date'),
                              date: _returnDate,
                              onTap: () => _pickDate(true),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('create_tour.label.price_per_seat'),
                      controller: _priceCtrl,
                      keyboardType: TextInputType.number,
                    ),
                    if ((Get.find<TourController>()
                                .getTour(widget.tourId)
                                ?.buses
                                .length ??
                            0) >=
                        2) ...[
                      const SizedBox(height: UgamSpacing.lg),
                      _ApplyPriceSheetCard(
                        c: c,
                        onTap: _saving ? null : _applyPriceSheet,
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('create_tour.label.tour_description'),
                      controller: _descCtrl,
                      maxLength: 300,
                    ),
                  ],
                ),
              ),
            ),
            UgamStickyCTA(
              child: Row(
                children: [
                  if (dirty) ...[
                    _CancelChangesPill(
                      c: c,
                      onPressed: _saving ? null : _cancelChanges,
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                  ],
                  Expanded(
                    child: UgamCTA(
                      label: _saving ? 'Saving…' : tr('edit_tour.btn_save'),
                      leadingIcon: Icons.save_rounded,
                      loading: _saving,
                      onPressed: _save,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelChangesPill extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback? onPressed;

  const _CancelChangesPill({required this.c, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.close_rounded,
              size: 16,
              color: enabled ? c.ink : c.ink3,
            ),
            const SizedBox(width: 6),
            Text(
              'Cancel changes',
              style: UgamText.titleS.copyWith(
                color: enabled ? c.ink : c.ink3,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-tap entry into the "apply this price sheet to all buses" flow. Only
/// shown when the tour has two or more buses (nothing to copy with one).
class _ApplyPriceSheetCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback? onTap;

  const _ApplyPriceSheetCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.stat),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.content_copy_rounded,
                  size: 18, color: enabled ? c.accent : c.ink3),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Apply price sheet to all buses',
                    style: UgamText.bodyStrong
                        .copyWith(color: c.ink, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Copy one bus\'s prices + bands to the rest',
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

class _TourPreviewCard extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String fromCity;
  final String toCity;
  final DateTime? departureDate;
  final String price;

  const _TourPreviewCard({
    required this.c,
    required this.title,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    required this.price,
  });

  @override
  Widget build(BuildContext context) {
    final shownTitle = title.isNotEmpty ? title : 'Untitled tour';
    final from = fromCity.isNotEmpty ? fromCity : 'From city';
    final to = toCity.isNotEmpty ? toCity : 'To city';
    final route = '$from → $to';
    final dateText = departureDate != null
        ? DateFormat('MMM d, yyyy').format(departureDate!)
        : 'Pick date';
    final priceText = () {
      final n = double.tryParse(price);
      if (n == null || n <= 0) return 'Set price';
      return '₹${n.toStringAsFixed(0)}/seat';
    }();

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: SizedBox(
              width: 64,
              height: 64,
              child: UgamBusBackdrop(
                seed: 'preview-${fromCity}_$toCity',
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const UgamReqChip(label: 'PREVIEW'),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'as customer sees it',
                        style: UgamText.caption.copyWith(color: c.ink3),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  shownTitle,
                  style: UgamText.titleM.copyWith(
                    color: title.isNotEmpty ? c.ink : c.ink3,
                    fontSize: 16,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  route,
                  style: UgamText.caption.copyWith(
                    color: (fromCity.isNotEmpty && toCity.isNotEmpty)
                        ? c.ink2
                        : c.ink3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _PreviewPill(
                      c: c,
                      icon: Icons.calendar_today_rounded,
                      label: dateText,
                      muted: departureDate == null,
                    ),
                    _PreviewPill(
                      c: c,
                      icon: Icons.currency_rupee_rounded,
                      label: priceText,
                      muted: priceText == 'Set price',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewPill extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool muted;

  const _PreviewPill({
    required this.c,
    required this.icon,
    required this.label,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: muted ? c.cardElev : c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: muted ? c.ink3 : c.accent),
          const SizedBox(width: 4),
          Text(
            label,
            style: UgamText.tabular(
              UgamText.caption.copyWith(
                color: muted ? c.ink3 : c.accent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  final UgamColorSet c;
  final String hint;
  final DateTime? date;
  final VoidCallback onTap;

  const _DateField({
    required this.c,
    required this.hint,
    required this.date,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today_rounded, size: 16, color: c.ink2),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                date != null ? DateFormat('MMM d, yyyy').format(date!) : hint,
                style: UgamText.body.copyWith(
                  color: date != null ? c.ink : c.ink3,
                  fontSize: 14,
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
