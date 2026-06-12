import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../config/whatsapp_cloud_config.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../services/whatsapp_cloud_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/time_format.dart';
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
  final _broadcastCtrl = TextEditingController();
  XFile? _broadcastImage;
  DateTime? _departureDate;
  TimeOfDay? _departureTime;
  DateTime? _returnDate;
  TimeOfDay? _returnTime;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  Timer? _previewDebounce;
  String? _dateError;

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
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 90), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_previewListener);
    _fromCtrl.removeListener(_previewListener);
    _toCtrl.removeListener(_previewListener);
    _priceCtrl.removeListener(_previewListener);
    _previewDebounce?.cancel();
    _titleCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    _broadcastCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBroadcastImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 82,
    );
    if (picked != null && mounted) {
      setState(() => _broadcastImage = picked);
    }
  }

  Future<void> _pickDate(bool isReturn) async {
    final initial = isReturn
        ? (_returnDate ?? _departureDate ?? DateTime.now())
        : (_departureDate ?? DateTime.now());
    final first = isReturn
        ? (_departureDate ?? DateTime.now())
        : DateTime.now();

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
          _dateError = null;
        }
      });
    }
  }

  Future<void> _pickTime(bool isReturn) async {
    final current = isReturn ? _returnTime : _departureTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: current ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked != null) {
      setState(() {
        if (isReturn) {
          _returnTime = picked;
        } else {
          _departureTime = picked;
        }
      });
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_departureDate == null) {
      setState(
        () => _dateError = tr('create_tour.validation.select_start_date'),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final tourCtrl = Get.find<TourController>();

      // Upload the optional broadcast image to public Storage first, so the
      // tour row carries a ready-to-send image URL. A failed upload must not
      // block tour creation — we just drop the image and keep going.
      String? broadcastImageUrl;
      if (_broadcastImage != null) {
        try {
          final bytes = await _broadcastImage!.readAsBytes();
          final ext = _broadcastImage!.name.split('.').last.toLowerCase();
          broadcastImageUrl = await WhatsAppCloudService().uploadPublic(
            bucket: WhatsAppCloudConfig.broadcastBucket,
            path:
                'broadcast_${DateTime.now().millisecondsSinceEpoch}.$ext',
            bytes: bytes,
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
          );
        } catch (_) {
          broadcastImageUrl = null;
          if (mounted) {
            AppSnackBar.warning(tr('create_tour.broadcast_image_upload_failed'));
          }
        }
      }

      final broadcastMessage = _broadcastCtrl.text.trim().isEmpty
          ? null
          : _broadcastCtrl.text.trim();

      final newTour = await tourCtrl.createTour(
        title: _titleCtrl.text.trim(),
        fromCity: _fromCtrl.text.trim(),
        toCity: _toCtrl.text.trim(),
        departureDate: _departureDate!,
        departureTime: _departureTime != null
            ? hhmmFromTimeOfDay(_departureTime!)
            : null,
        returnDate: _returnDate,
        returnTime: (_returnDate != null && _returnTime != null)
            ? hhmmFromTimeOfDay(_returnTime!)
            : null,
        pricePerSeat: double.tryParse(_priceCtrl.text) ?? 0,
        description: _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        broadcastMessage: broadcastMessage,
        broadcastImageUrl: broadcastImageUrl,
      );

      if (!mounted) return;
      AppSnackBar.success(
        tr(
          'create_tour.snackbar.created_body',
          namedArgs: {'route': newTour.route},
        ),
        title: tr('create_tour.snackbar.created_title'),
      );
      Get.off(
        () => TourDetailScreen(tourId: newTour.id),
        transition: Transition.cupertino,
      );

      // Fulfil "Create & Broadcast": open WhatsApp's broadcast/group picker
      // with this tour's message pre-filled (also copied to the clipboard),
      // so the agent taps their saved Broadcast List or group to send. Free —
      // no Cloud API, no Meta approval. Fire-and-forget: navigation already
      // happened, so the agent returns to the tour detail after sending.
      unawaited(WhatsAppService().broadcastTour(tour: newTour));
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
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 19,
                        color: c.ink,
                      ),
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
                          child: Icon(
                            Icons.arrow_downward_rounded,
                            size: 14,
                            color: c.accent,
                          ),
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
                              horizontal: UgamSpacing.sm + 2,
                            ),
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 14,
                              color: c.accent,
                            ),
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
                    // Departure date paired with its departure time.
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: _DateField(
                            c: c,
                            hint: tr('create_tour.hint.start_date'),
                            date: _departureDate,
                            onTap: () => _pickDate(false),
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        Expanded(
                          flex: 2,
                          child: _TimeField(
                            c: c,
                            hint: tr('create_tour.hint.departure_time'),
                            time: _departureTime,
                            onTap: () => _pickTime(false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    // Return date paired with its return time.
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: _DateField(
                            c: c,
                            hint: tr('create_tour.hint.end_date'),
                            date: _returnDate,
                            onTap: () => _pickDate(true),
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        Expanded(
                          flex: 2,
                          child: _TimeField(
                            c: c,
                            hint: tr('create_tour.hint.return_time'),
                            time: _returnTime,
                            onTap: () => _pickTime(true),
                          ),
                        ),
                      ],
                    ),
                    if (_dateError != null) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      Text(
                        _dateError!,
                        style: UgamText.caption.copyWith(color: c.danger),
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
                    Text(
                      '${tr('create_tour.label.broadcast').toUpperCase()}  ·  ${tr('create_tour.label.optional').toUpperCase()}',
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    UgamInput(
                      hint: tr('create_tour.hint.broadcast'),
                      controller: _broadcastCtrl,
                      maxLines: 4,
                      maxLength: 600,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    _BroadcastImagePicker(
                      c: c,
                      image: _broadcastImage,
                      onPick: _pickBroadcastImage,
                      onRemove: () => setState(() => _broadcastImage = null),
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 14,
                          color: c.ink3,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            tr('create_tour.broadcast_note'),
                            style: UgamText.caption.copyWith(color: c.ink3),
                            textAlign: TextAlign.center,
                          ),
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
    final shownTitle = title.isNotEmpty
        ? title
        : tr('create_tour.preview.untitled');
    final from = fromCity.isNotEmpty
        ? fromCity
        : tr('create_tour.hint.from_city');
    final to = toCity.isNotEmpty ? toCity : tr('create_tour.hint.to_city');
    final route = '$from → $to';
    final dateText = departureDate != null
        ? DateFormat('MMM d, yyyy').format(departureDate!)
        : tr('create_tour.preview.pick_date');
    final setPriceLabel = tr('create_tour.preview.set_price');
    final priceText = () {
      final n = double.tryParse(price);
      if (n == null || n <= 0) return setPriceLabel;
      return tr(
        'create_tour.preview.per_seat',
        namedArgs: {'price': n.toStringAsFixed(0)},
      );
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
              child: UgamBusBackdrop(seed: 'preview-${fromCity}_$toCity'),
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
                    UgamReqChip(label: tr('create_tour.preview.eyebrow')),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('create_tour.preview.as_customer'),
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
                      muted: priceText == setPriceLabel,
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

/// Optional broadcast hero image: an "add image" tile when empty, or a
/// thumbnail preview with a remove button once picked. The image rides along
/// with the WhatsApp broadcast template's header.
class _BroadcastImagePicker extends StatelessWidget {
  final UgamColorSet c;
  final XFile? image;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _BroadcastImagePicker({
    required this.c,
    required this.image,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (image == null) {
      return GestureDetector(
        onTap: onPick,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
            border: Border.all(color: c.border, width: 1),
          ),
          child: Row(
            children: [
              Icon(Icons.add_photo_alternate_rounded, size: 18, color: c.ink2),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  tr('create_tour.broadcast_add_image'),
                  style: UgamText.body.copyWith(color: c.ink2, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: Image.file(
              File(image!.path),
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('create_tour.broadcast_image_added'),
              style: UgamText.caption.copyWith(color: c.ink),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded, size: 18, color: c.ink3),
            ),
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

/// Tap target mirroring [_DateField] for a time-of-day. Shows a locale-aware
/// time once picked, or the hint while unset.
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Icon(Icons.access_time_rounded, size: 16, color: c.ink2),
            const SizedBox(width: UgamSpacing.xs),
            Expanded(
              child: Text(
                time != null ? time!.format(context) : hint,
                style: UgamText.body.copyWith(
                  color: time != null ? c.ink : c.ink3,
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
