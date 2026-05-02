import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/booking_controller.dart';
import '../models/booking_input.dart';
import '../services/booking_input_parser.dart';
import '../utils/app_snackbar.dart';
import '../models/seat_type.dart';
import '../models/age_group.dart';
import '../config/theme.dart';

class BookingForm extends StatelessWidget {
  final TextEditingController textController = TextEditingController();
  final BookingInputParser parser = BookingInputParser();
  final RxString errorMessage = ''.obs;
  final Rx<ParsedBookingInput?> parsedInput = Rx<ParsedBookingInput?>(null);

  BookingForm({super.key});

  void _parseInput(String value) {
    try {
      final input = parser.parse(value);
      parsedInput.value = input;
      errorMessage.value = '';
    } catch (e) {
      parsedInput.value = null;
      errorMessage.value = e.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookingCtrl = Get.find<BookingController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withAlpha(6),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withAlpha(isDark ? 30 : 15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.edit_note_rounded,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Text('Quick Booking', style: theme.textTheme.headlineSmall),
            ],
          ),
          const SizedBox(height: 20),

          // ── Input field ──
          TextField(
            controller: textController,
            onChanged: _parseInput,
            style: theme.textTheme.bodyLarge,
            decoration: InputDecoration(
              labelText: 'Booking details',
              hintText: 'e.g., Ramesh 2 singleSofa doubleSofa elder',
              prefixIcon: Icon(
                Icons.person_outline_rounded,
                color: theme.colorScheme.onSurface.withAlpha(100),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Error message ──
          Obx(() => AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withAlpha(12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.danger.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: AppTheme.danger, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          errorMessage.value,
                          style: const TextStyle(
                            color: AppTheme.danger,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                crossFadeState: errorMessage.value.isEmpty
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                duration: const Duration(milliseconds: 250),
              )),

          // ── Preview card ──
          Obx(() {
            final input = parsedInput.value;
            if (input == null) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(top: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.success.withAlpha(10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.success.withAlpha(40)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: AppTheme.success, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Booking Preview',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: AppTheme.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Divider(
                    color: AppTheme.success.withAlpha(30),
                    height: 24,
                  ),
                  _DetailRow(
                    icon: Icons.person_outline_rounded,
                    label: 'Customer',
                    value: input.customerName,
                    theme: theme,
                  ),
                  const SizedBox(height: 8),
                  _DetailRow(
                    icon: Icons.event_seat_rounded,
                    label: 'Seats',
                    value:
                        '${input.seatCount} (${input.seatTypes.map((e) => e.displayName).join(', ')})',
                    theme: theme,
                  ),
                  if (input.ageGroup != null) ...[
                    const SizedBox(height: 8),
                    _DetailRow(
                      icon: Icons.group_rounded,
                      label: 'Age Group',
                      value: input.ageGroup!.displayName,
                      theme: theme,
                    ),
                  ],
                ],
              ),
            );
          }),

          const SizedBox(height: 20),

          // ── Submit button ──
          Obx(() => SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: parsedInput.value != null
                      ? () {
                          bookingCtrl.createBooking(parsedInput.value!);
                          textController.clear();
                          parsedInput.value = null;
                          errorMessage.value = '';
                          AppSnackBar.success('Successfully added to the system', title: 'Booking Created');
                        }
                      : null,
                  child: const Text('Confirm Booking'),
                ),
              )),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ThemeData theme;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: theme.colorScheme.onSurface.withAlpha(120)),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withAlpha(120),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
