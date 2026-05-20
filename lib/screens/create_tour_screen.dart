import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../utils/app_snackbar.dart';
import 'tour_detail_screen.dart';

class CreateTourScreen extends StatefulWidget {
  const CreateTourScreen({super.key});

  @override
  State<CreateTourScreen> createState() => _CreateTourScreenState();
}

class _CreateTourScreenState extends State<CreateTourScreen> {
  final _titleCtrl = TextEditingController();
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  DateTime? _departureDate;
  DateTime? _returnDate;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

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
    final first =
        isReturn ? (_departureDate ?? DateTime.now()) : DateTime.now();

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        if (isReturn) {
          _returnDate = picked;
        } else {
          _departureDate = picked;
        }
      });
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_departureDate == null) {
      AppSnackBar.warning(tr('create_tour.validation.select_start_date'));
      return;
    }

    setState(() => _saving = true);
    try {
      final tourCtrl = Get.find<TourController>();
      final newTour = await tourCtrl.createTour(
        title: _titleCtrl.text.trim(),
        fromCity: _fromCtrl.text.trim(),
        toCity: _toCtrl.text.trim(),
        departureDate: _departureDate!,
        returnDate: _returnDate,
        pricePerSeat: double.tryParse(_priceCtrl.text) ?? 0,
        description:
            _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      );

      if (!mounted) return;
      AppSnackBar.success(
        tr('create_tour.snackbar.created_body',
            namedArgs: {'route': newTour.route}),
        title: tr('create_tour.snackbar.created_title'),
      );
      Get.off(
        () => TourDetailScreen(tourId: newTour.id),
        transition: Transition.cupertino,
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('create_tour.snackbar.error'));
    } finally {
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
                      tr('create_tour.title'),
                      style: UgamText.titleL.copyWith(color: c.ink),
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
                      hint: tr('create_tour.hint.tour_name'),
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
                        Expanded(
                          child: UgamInput(
                            hint: tr('create_tour.hint.from_city'),
                            controller: _fromCtrl,
                          ),
                        ),
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
                        Expanded(
                          child: UgamInput(
                            hint: tr('create_tour.hint.to_city'),
                            controller: _toCtrl,
                          ),
                        ),
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
                      label:
                          '${tr('create_tour.label.price_per_seat')} (${tr('create_tour.label.optional')})',
                      hint: tr('create_tour.hint.price'),
                      controller: _priceCtrl,
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('create_tour.label.tour_description'),
                      hint: tr('create_tour.hint.description'),
                      controller: _descCtrl,
                      maxLength: 300,
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline_rounded,
                            size: 14, color: c.ink3),
                        const SizedBox(width: 6),
                        Text(
                          tr('create_tour.broadcast_note'),
                          style: UgamText.caption.copyWith(color: c.ink3),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: _saving
                    ? tr('create_tour.action.creating')
                    : tr('create_tour.action.create_broadcast'),
                leadingIcon: Icons.send_rounded,
                loading: _saving,
                onPressed: _submit,
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
