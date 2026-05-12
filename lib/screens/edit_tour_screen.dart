import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/tour_controller.dart';
import '../config/theme.dart';
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
        ? (_departureDate ?? DateTime.now().subtract(const Duration(days: 365)))
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
    } catch (e) {
      AppSnackBar.error(tr('edit_tour.snack_save_failed'));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : AppTheme.bgLight,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.surfaceDark : Colors.white,
                border: const Border(
                  bottom: BorderSide(color: AppTheme.borderLight, width: 1),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.arrow_back,
                      color: isDark ? Colors.white : AppTheme.textPrimary,
                    ),
                    onPressed: () => Get.back(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    tr('edit_tour.title'),
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabel(tr('edit_tour.label_tour_name')),
                      const SizedBox(height: 8),
                      _buildInput(
                        controller: _titleCtrl,
                        hint: tr('edit_tour.hint_tour_name'),
                        isDark: isDark,
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? tr('app.error.required') : null,
                      ),
                      const SizedBox(height: 20),
                      _buildLabel(tr('edit_tour.label_route')),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _buildInput(
                              controller: _fromCtrl,
                              hint: tr('edit_tour.hint_from_city'),
                              isDark: isDark,
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
                              color: AppTheme.textMuted,
                            ),
                          ),
                          Expanded(
                            child: _buildInput(
                              controller: _toCtrl,
                              hint: tr('edit_tour.hint_to_city'),
                              isDark: isDark,
                              prefixIcon: Icons.location_on_outlined,
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? tr('app.error.required')
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildLabel(tr('edit_tour.label_date_range')),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _DatePickerField(
                              hint: tr('edit_tour.hint_start_date'),
                              date: _departureDate,
                              onTap: () => _pickDate(false),
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DatePickerField(
                              hint: tr('edit_tour.hint_end_date'),
                              date: _returnDate,
                              onTap: () => _pickDate(true),
                              onClear: _returnDate != null
                                  ? () => setState(() => _returnDate = null)
                                  : null,
                              isDark: isDark,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildLabel(tr('edit_tour.label_price_per_seat')),
                      const SizedBox(height: 8),
                      _buildInput(
                        controller: _priceCtrl,
                        hint: '0.00',
                        isDark: isDark,
                        prefixText: '₹ ',
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return tr('app.error.required');
                          if (double.tryParse(v) == null) {
                            return tr('edit_tour.error_invalid_amount');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),
                      _buildLabel(tr('edit_tour.label_description')),
                      const SizedBox(height: 8),
                      _buildInput(
                        controller: _descCtrl,
                        hint: tr('edit_tour.hint_description'),
                        isDark: isDark,
                        maxLines: 4,
                        minHeight: 100,
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppTheme.brand,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: AppTheme.brandShadow,
                          ),
                          child: MaterialButton(
                            onPressed: _saving ? null : _save,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.check_rounded,
                                        size: 18,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        tr('edit_tour.btn_save_changes'),
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

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: AppTheme.textPrimary,
      ),
    );
  }

  Widget _buildInput({
    required TextEditingController controller,
    required String hint,
    required bool isDark,
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
          color: isDark ? Colors.white : AppTheme.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.inter(
            fontSize: 15,
            color: AppTheme.textMuted,
          ),
          prefixIcon: prefixIcon != null
              ? Icon(prefixIcon, size: 18, color: AppTheme.textMuted)
              : null,
          prefixText: prefixText,
          prefixStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : AppTheme.textPrimary,
          ),
          filled: true,
          fillColor: isDark ? AppTheme.cardDark : Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: AppTheme.borderDefault),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: isDark ? AppTheme.borderDark : AppTheme.borderDefault,
            ),
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

class _DatePickerField extends StatelessWidget {
  final String hint;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final bool isDark;

  const _DatePickerField({
    required this.hint,
    required this.date,
    required this.onTap,
    required this.isDark,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardDark : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark ? AppTheme.borderDark : AppTheme.borderDefault,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 16,
              color: AppTheme.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                date != null ? DateFormat('MMM d, yyyy').format(date!) : hint,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: date != null
                      ? (isDark ? Colors.white : AppTheme.textPrimary)
                      : AppTheme.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onClear != null)
              GestureDetector(
                onTap: onClear,
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: AppTheme.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
