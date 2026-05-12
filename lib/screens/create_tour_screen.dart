import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/tour_controller.dart';
import '../config/theme.dart';
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
      // Await the insert so by the time we navigate, the row is committed
      // to Supabase (when online) and present in the local list. Otherwise
      // a background refetch can clobber the local-only tour before the
      // detail screen reads it.
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
        tr('create_tour.snackbar.created_body', namedArgs: {'route': newTour.route}),
        title: tr('create_tour.snackbar.created_title'),
      );
      Get.off(
        () => TourDetailScreen(tourId: newTour.id),
        transition: Transition.cupertino,
      );
    } catch (_) {
      if (mounted) {
        AppSnackBar.error(tr('create_tour.snackbar.error'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: SafeArea(
        child: Column(
          children: [
            // ── Custom Header ────────────────────────────────────
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                border: Border(
                  bottom: BorderSide(color: AppColors.border(context), width: 1),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.arrow_back,
                      color: AppColors.text(context),
                    ),
                    onPressed: () => Get.back(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    tr('create_tour.title'),
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text(context),
                    ),
                  ),
                ],
              ),
            ),

            // ── Form Body ────────────────────────────────────────
            Expanded(
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Tour Name
                      _buildLabel(context, tr('create_tour.label.tour_name')),
                      const SizedBox(height: 8),
                      _buildInput(
                        context: context,
                        controller: _titleCtrl,
                        hint: tr('create_tour.hint.tour_name'),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? tr('app.error.required')
                            : null,
                      ),

                      const SizedBox(height: 20),

                      // Route
                      _buildLabel(context, tr('create_tour.label.route')),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _buildInput(
                              context: context,
                              controller: _fromCtrl,
                              hint: tr('create_tour.hint.from_city'),
                              prefixIcon: Icons.location_on_outlined,
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? tr('app.error.required')
                                  : null,
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 18,
                              color: AppColors.textMuted(context),
                            ),
                          ),
                          Expanded(
                            child: _buildInput(
                              context: context,
                              controller: _toCtrl,
                              hint: tr('create_tour.hint.to_city'),
                              prefixIcon: Icons.location_on_outlined,
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? tr('app.error.required')
                                  : null,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // Date Range
                      _buildLabel(context, tr('create_tour.label.date_range')),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _DatePickerField(
                              hint: tr('create_tour.hint.start_date'),
                              date: _departureDate,
                              onTap: () => _pickDate(false),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DatePickerField(
                              hint: tr('create_tour.hint.end_date'),
                              date: _returnDate,
                              onTap: () => _pickDate(true),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // Price Per Seat (optional — can be set per bus later)
                      Row(
                        children: [
                          _buildLabel(context, tr('create_tour.label.price_per_seat')),
                          const SizedBox(width: 6),
                          Text(
                            tr('create_tour.label.optional'),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: AppColors.textMuted(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildInput(
                        context: context,
                        controller: _priceCtrl,
                        hint: tr('create_tour.hint.price'),
                        prefixText: '₹ ',
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          if (double.tryParse(v) == null) {
                            return tr('create_tour.validation.invalid_amount');
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 20),

                      // Tour Description
                      _buildLabel(context, tr('create_tour.label.tour_description')),
                      const SizedBox(height: 8),
                      _buildInput(
                        context: context,
                        controller: _descCtrl,
                        hint: tr('create_tour.hint.description'),
                        maxLines: 4,
                        minHeight: 100,
                      ),

                      const SizedBox(height: 32),

                      // ── CTA Button ─────────────────────────────
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _saving
                                ? AppTheme.brand.withValues(alpha: 0.7)
                                : AppTheme.brand,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow:
                                _saving ? null : AppTheme.brandShadow,
                          ),
                          child: MaterialButton(
                            onPressed: _saving ? null : _submit,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_saving)
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.send_rounded,
                                    size: 18,
                                    color: Colors.white,
                                  ),
                                const SizedBox(width: 10),
                                Text(
                                  _saving
                                      ? tr('create_tour.action.creating')
                                      : tr('create_tour.action.create_broadcast'),
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // ── WhatsApp Note ──────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 14,
                            color: AppColors.textMuted(context),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            tr('create_tour.broadcast_note'),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: AppColors.textMuted(context),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────

  Widget _buildLabel(BuildContext context, String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: AppColors.text(context),
      ),
    );
  }

  Widget _buildInput({
    required BuildContext context,
    required TextEditingController controller,
    required String hint,
    IconData? prefixIcon,
    String? prefixText,
    int maxLines = 1,
    double? minHeight,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return SizedBox(
      height: minHeight,
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: validator,
        style: GoogleFonts.inter(
          fontSize: 15,
          color: AppColors.text(context),
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.inter(
            fontSize: 15,
            color: AppColors.textMuted(context),
          ),
          prefixIcon: prefixIcon != null
              ? Icon(prefixIcon, size: 18, color: AppColors.textMuted(context))
              : null,
          prefixText: prefixText,
          prefixStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.text(context),
          ),
          filled: true,
          fillColor: AppColors.surface(context),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: AppColors.border(context)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: AppColors.border(context)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: AppTheme.brand, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: AppTheme.danger, width: 1.5),
          ),
        ),
      ),
    );
  }
}

// ── Date Picker Field ──────────────────────────────────────────────

class _DatePickerField extends StatelessWidget {
  final String hint;
  final DateTime? date;
  final VoidCallback onTap;

  const _DatePickerField({
    required this.hint,
    required this.date,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 16,
              color: AppColors.textMuted(context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                date != null ? DateFormat('MMM d, yyyy').format(date!) : hint,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: date != null
                      ? AppColors.text(context)
                      : AppColors.textMuted(context),
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
