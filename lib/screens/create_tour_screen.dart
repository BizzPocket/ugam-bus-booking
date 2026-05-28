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
  void initState() {
    super.initState();
    // Live preview rebuilds on every keystroke.
    _titleCtrl.addListener(_previewListener);
    _fromCtrl.addListener(_previewListener);
    _toCtrl.addListener(_previewListener);
    _priceCtrl.addListener(_previewListener);
  }

  void _previewListener() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_previewListener);
    _fromCtrl.removeListener(_previewListener);
    _toCtrl.removeListener(_previewListener);
    _priceCtrl.removeListener(_previewListener);
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
                      hint: tr('create_tour.hint.tour_name'),
                      controller: _titleCtrl,
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    Text(
                      tr('create_tour.label.route').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (MediaQuery.of(context).size.width < 400) ...[
                      UgamInput(
                        hint: tr('create_tour.hint.from_city'),
                        controller: _fromCtrl,
                      ),
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
                      UgamInput(
                        hint: tr('create_tour.hint.to_city'),
                        controller: _toCtrl,
                      ),
                    ] else ...[
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

/// Compact live-preview card that mirrors a tour list row. Updates as
/// the agent types so they see what the customer will see.
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
