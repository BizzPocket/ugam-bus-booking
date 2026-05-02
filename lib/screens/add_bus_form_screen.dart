import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../utils/app_snackbar.dart';

class AddBusFormScreen extends StatefulWidget {
  final String? tourId;
  const AddBusFormScreen({super.key, this.tourId});

  @override
  State<AddBusFormScreen> createState() => _AddBusFormScreenState();
}

class _AddBusFormScreenState extends State<AddBusFormScreen> {
  final _busNumberCtrl = TextEditingController();
  final _driverNameCtrl = TextEditingController();
  final _driverPhoneCtrl = TextEditingController();

  bool _isAc = false;
  int _totalSeats = 45;
  int _selectedTypeIndex = 0; // 0=Sleeper, 1=Seater, 2=Mixed
  final List<String> _busTypes = ['Sleeper', 'Seater', 'Mixed'];

  @override
  void dispose() {
    _busNumberCtrl.dispose();
    _driverNameCtrl.dispose();
    _driverPhoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveBus() async {
    if (_busNumberCtrl.text.trim().isEmpty) {
      AppSnackBar.error('Please enter bus number');
      return;
    }
    if (_driverNameCtrl.text.trim().isEmpty) {
      AppSnackBar.error('Please enter driver name');
      return;
    }

    final tourId = widget.tourId ?? (Get.arguments?['tourId'] as String?);

    final details = BusDetails(
      busNumber: _busNumberCtrl.text.trim(),
      driverName: _driverNameCtrl.text.trim(),
      driverPhone: _driverPhoneCtrl.text.trim(),
      isAC: _isAc,
      busType: _busTypes[_selectedTypeIndex],
      totalSeats: _totalSeats,
    );

    if (tourId != null && tourId.isNotEmpty) {
      final tourCtrl = Get.find<TourController>();
      await tourCtrl.addBusDetails(tourId, details);
      AppSnackBar.success(
        'Bus "${details.busNumber}" added to tour',
        title: 'Bus Saved',
      );
    } else {
      AppSnackBar.success('Bus "${details.busNumber}" saved');
    }

    Get.back();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  _buildBackButton(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Bus',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Kutch Tour · Bus 5 of 5',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Scrollable form content ─────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Info Banner ────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        border: Border.all(
                          color: const Color(0xFFDBEAFE),
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            size: 20,
                            color: AppTheme.brand,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'This tour currently has 4 buses configured. You are adding bus number 5.',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: AppTheme.brand,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── Bus Number ────────────────────────────
                    _buildLabel('Bus Number'),
                    const SizedBox(height: 6),
                    _buildTextField(
                      controller: _busNumberCtrl,
                      hint: 'e.g. GJ-05-AB-1234',
                    ),

                    const SizedBox(height: 20),

                    // ── Driver Name ───────────────────────────
                    _buildLabel('Driver Name'),
                    const SizedBox(height: 6),
                    _buildTextField(
                      controller: _driverNameCtrl,
                      hint: "Enter driver's full name",
                    ),

                    const SizedBox(height: 20),

                    // ── Driver Phone ──────────────────────────
                    _buildLabel('Driver Phone'),
                    const SizedBox(height: 6),
                    _buildPhoneField(),

                    const SizedBox(height: 20),

                    // ── AC Toggle ─────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'AC Bus',
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(() => _isAc = !_isAc),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 48,
                            height: 28,
                            decoration: BoxDecoration(
                              color: _isAc ? AppTheme.brand : AppTheme.borderDefault,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: AnimatedAlign(
                              duration: const Duration(milliseconds: 200),
                              alignment: _isAc
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // ── Total Seats ───────────────────────────
                    _buildLabel('Total Seats'),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildStepperButton(
                          icon: Icons.remove_rounded,
                          onTap: () {
                            if (_totalSeats > 1) {
                              setState(() => _totalSeats--);
                            }
                          },
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              '$_totalSeats',
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        _buildStepperButton(
                          icon: Icons.add_rounded,
                          onTap: () {
                            setState(() => _totalSeats++);
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // ── Bus Type ──────────────────────────────
                    _buildLabel('Bus Type'),
                    const SizedBox(height: 10),
                    Row(
                      children: List.generate(_busTypes.length, (index) {
                        final isSelected = _selectedTypeIndex == index;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                setState(() => _selectedTypeIndex = index),
                            child: Container(
                              height: 44,
                              margin: EdgeInsets.only(
                                right: index < _busTypes.length - 1 ? 8 : 0,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppTheme.brand
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: isSelected
                                    ? null
                                    : Border.all(
                                        color: AppTheme.borderDefault,
                                        width: 1,
                                      ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _busTypes[index],
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? Colors.white
                                      : AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),

                    const SizedBox(height: 32),

                    // ── Save Button ───────────────────────────
                    GestureDetector(
                      onTap: _saveBus,
                      child: Container(
                        width: double.infinity,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppTheme.brand,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: AppTheme.brandShadow,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.add_circle_outline_rounded,
                              size: 20,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Save Bus',
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

                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackButton() {
    return GestureDetector(
      onTap: () => Get.back(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.cardLight,
          shape: BoxShape.circle,
          border: Border.all(color: AppTheme.borderLight, width: 1),
        ),
        child: const Icon(
          Icons.arrow_back_rounded,
          size: 18,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppTheme.textSecondary,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboardType,
  }) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderDefault, width: 1),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: AppTheme.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: AppTheme.textMuted,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildPhoneField() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderDefault, width: 1),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              '+91',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            color: AppTheme.borderDefault,
          ),
          Expanded(
            child: TextField(
              controller: _driverPhoneCtrl,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                color: AppTheme.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: '98765 43210',
                hintStyle: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: AppTheme.textMuted,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepperButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.borderDefault, width: 1),
        ),
        child: Icon(
          icon,
          size: 20,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}
