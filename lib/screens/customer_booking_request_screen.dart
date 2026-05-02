import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../models/tour.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';

/// The "Request seats" form opened from the customer tour-detail screen.
/// Composes a standardized booking-request message and hands off to the
/// customer's own WhatsApp app via a `wa.me` deep link addressed to the
/// tour creator's phone (admin). The customer just edits if needed and
/// taps send — no app install needed on the admin side.
class CustomerBookingRequestScreen extends StatefulWidget {
  final Tour tour;

  const CustomerBookingRequestScreen({super.key, required this.tour});

  @override
  State<CustomerBookingRequestScreen> createState() =>
      _CustomerBookingRequestScreenState();
}

class _CustomerBookingRequestScreenState
    extends State<CustomerBookingRequestScreen> {
  final _name = TextEditingController();
  final _note = TextEditingController();
  int _singleSofa = 0;
  int _doubleSofa = 0;
  bool _sending = false;

  int get _totalSeats => _singleSofa + _doubleSofa;
  double get _estTotal => widget.tour.pricePerSeat * _totalSeats;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppSnackBar.error('Please enter your name');
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error('Pick at least one seat');
      return;
    }
    final adminPhone = widget.tour.createdBy;
    if (adminPhone == null || adminPhone.isEmpty) {
      AppSnackBar.error(
        'This tour is missing the contact number — please reach out to '
        'the organiser directly.',
      );
      return;
    }

    setState(() => _sending = true);
    try {
      final ok = await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: _singleSofa,
        doubleSofaCount: _doubleSofa,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (!ok) {
        AppSnackBar.error('Could not open WhatsApp on your device.');
        return;
      }
      if (!mounted) return;
      Get.back();
      AppSnackBar.success(
        'Tap "Send" in WhatsApp to deliver the request.',
        title: 'WhatsApp opened',
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(),
        ),
        title: Text(
          'Request seats',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  _SummaryCard(tour: widget.tour, colorScheme: colorScheme),
                  const SizedBox(height: 24),
                  _label('YOUR NAME'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: 'How should we list you?',
                    ),
                  ),
                  const SizedBox(height: 24),
                  _label('SEAT TYPE'),
                  const SizedBox(height: 8),
                  _SeatStepper(
                    label: 'Double Sofa',
                    sublabel:
                        'Wider berth — best for couples or extra comfort',
                    value: _doubleSofa,
                    onChanged: (v) => setState(() => _doubleSofa = v),
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 12),
                  _SeatStepper(
                    label: 'Single Sofa',
                    sublabel: 'Standard single berth',
                    value: _singleSofa,
                    onChanged: (v) => setState(() => _singleSofa = v),
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 24),
                  _label('NOTE (OPTIONAL)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _note,
                    maxLines: 3,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      hintText: 'Anything the organiser should know? '
                          '(special requests, group members, etc.)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Totals(
                    seatCount: _totalSeats,
                    estTotal: _estTotal,
                    colorScheme: colorScheme,
                  ),
                ],
              ),
            ),
            // Sticky bottom CTA
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(top: BorderSide(color: colorScheme.outline)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Tapping below opens WhatsApp on your phone with the '
                    'request pre-filled. You just hit "Send" inside WhatsApp.',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded),
                      label: Text(
                        _sending
                            ? 'Opening WhatsApp…'
                            : 'Send via WhatsApp',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
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

  Widget _label(String s) => Text(
        s,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMuted,
          letterSpacing: 1.5,
        ),
      );
}

class _SummaryCard extends StatelessWidget {
  final Tour tour;
  final ColorScheme colorScheme;
  const _SummaryCard({required this.tour, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.brandAccent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tour.title,
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.brandDark,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${tour.fromCity} → ${tour.toCity}  ·  '
            '₹${tour.pricePerSeat.toStringAsFixed(0)} / seat',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppTheme.brandDark.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatStepper extends StatelessWidget {
  final String label;
  final String sublabel;
  final int value;
  final ValueChanged<int> onChanged;
  final ColorScheme colorScheme;

  const _SeatStepper({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton.outlined(
            visualDensity: VisualDensity.compact,
            onPressed: value > 0 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          IconButton.outlined(
            visualDensity: VisualDensity.compact,
            onPressed: value < 8 ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  final int seatCount;
  final double estTotal;
  final ColorScheme colorScheme;

  const _Totals({
    required this.seatCount,
    required this.estTotal,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Text(
            '$seatCount ${seatCount == 1 ? "seat" : "seats"}',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (estTotal > 0)
            Text(
              'Estimated total: ₹${estTotal.toStringAsFixed(0)}',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}
