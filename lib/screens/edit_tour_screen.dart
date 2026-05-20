import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
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

  @override
  void initState() {
    super.initState();
    final tour = Get.find<TourController>().getTour(widget.tourId);
    _titleCtrl = TextEditingController(text: tour?.title ?? '');
    _fromCtrl = TextEditingController(text: tour?.fromCity ?? '');
    _toCtrl = TextEditingController(text: tour?.toCity ?? '');
    _priceCtrl = TextEditingController(
      text: tour != null ? tour.pricePerSeat.toStringAsFixed(0) : '',
    );
    _descCtrl = TextEditingController(text: tour?.description ?? '');
    _departureDate = tour?.departureDate;
    _returnDate = tour?.returnDate;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
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
                    const SizedBox(height: UgamSpacing.lg),
                    Text(
                      tr('create_tour.label.date_range').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
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
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('create_tour.label.price_per_seat'),
                      controller: _priceCtrl,
                      keyboardType: TextInputType.number,
                    ),
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
