import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/appwrite_config.dart';
import '../config/theme.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../services/sync_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';

/// Customer-side seat request form.
///
/// On submit:
///   1. Writes a Passenger record to the DB (idempotent on tourId+phone).
///   2. Opens WhatsApp via deep link with a pre-filled message addressed
///      to the agent's number; the customer taps Send to give the agent
///      a familiar courtesy ping. The DB write is the source of truth —
///      the agent's Requests screen reads from there.
///
/// Customer-facing seat types are simplified to Sleeper Lower / Sleeper
/// Upper / Seater. They map to the data model's doubleSofa+position and
/// seater types so the agent's assignment screen can match them up.
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
  final _phone = TextEditingController();
  final _note = TextEditingController();

  int _sleeperLower = 0;
  int _sleeperUpper = 0;
  int _seater = 0;

  bool _saving = false;

  int get _totalSeats => _sleeperLower + _sleeperUpper + _seater;
  double get _estTotal => widget.tour.pricePerSeat * _totalSeats;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  List<RequestLine> _buildRequestLines() {
    final lines = <RequestLine>[];
    if (_sleeperLower > 0) {
      lines.add(RequestLine(
        seatType: SeatType.doubleSofa,
        position: SeatPosition.lower,
        qty: _sleeperLower,
      ));
    }
    if (_sleeperUpper > 0) {
      lines.add(RequestLine(
        seatType: SeatType.doubleSofa,
        position: SeatPosition.upper,
        qty: _sleeperUpper,
      ));
    }
    if (_seater > 0) {
      lines.add(RequestLine(
        seatType: SeatType.seater,
        qty: _seater,
      ));
    }
    return lines;
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty) {
      AppSnackBar.error('Please enter your name');
      return;
    }
    if (phone.length != 10) {
      AppSnackBar.error('Please enter a 10-digit phone number');
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error('Pick at least one seat');
      return;
    }
    final adminPhone = widget.tour.createdBy;
    if (adminPhone == null || adminPhone.isEmpty) {
      AppSnackBar.error(
        'This tour is missing the organiser contact — please reach '
        'out directly via WhatsApp.',
      );
      return;
    }

    setState(() => _saving = true);
    final sync = Get.find<SyncService>();

    try {
      // Write/update Passenger in DB. Idempotency: same tourId + phone
      // updates the existing record instead of creating a duplicate.
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: name,
        phone: '+91$phone',
        requestLines: _buildRequestLines(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );

      await sync.smartInsert(
        table: AppwriteConfig.passengersCollection,
        entityId: passenger.id,
        data: passenger.toAppwrite(),
      );

      // Hand off to WhatsApp. Failure here is recoverable — the DB
      // already has the request, agent will see it on their side.
      await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: 0,
        doubleSofaCount: _sleeperLower + _sleeperUpper,
        note: _note.text.trim().isEmpty
            ? 'Sleeper L:$_sleeperLower U:$_sleeperUpper · Seater $_seater'
            : '${_note.text.trim()} (Sleeper L:$_sleeperLower '
                'U:$_sleeperUpper · Seater $_seater)',
      );

      if (!mounted) return;
      Get.back();
      AppSnackBar.success(
        'Request sent. Tap Send in WhatsApp to confirm.',
        title: 'Submitted',
      );
    } catch (e) {
      AppSnackBar.error('Could not save your request — try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
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
                  _SummaryCard(tour: widget.tour),
                  const SizedBox(height: 22),

                  _Label('YOUR NAME'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: 'How should we list you?',
                    ),
                  ),
                  const SizedBox(height: 18),

                  _Label('PHONE (we will WhatsApp you here)'),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.bgLight,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppTheme.borderLight),
                        ),
                        child: Text(
                          '+91',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: const InputDecoration(
                            hintText: '98765 43210',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  _Label('SEATS NEEDED'),
                  const SizedBox(height: 6),
                  _SeatStepper(
                    label: 'Sleeper — Lower berth',
                    sublabel: 'Easier to access; popular with elders',
                    value: _sleeperLower,
                    onChanged: (v) => setState(() => _sleeperLower = v),
                  ),
                  const SizedBox(height: 10),
                  _SeatStepper(
                    label: 'Sleeper — Upper berth',
                    sublabel: 'Above the lower berth',
                    value: _sleeperUpper,
                    onChanged: (v) => setState(() => _sleeperUpper = v),
                  ),
                  const SizedBox(height: 10),
                  _SeatStepper(
                    label: 'Seater',
                    sublabel: 'Standard sit-up seat',
                    value: _seater,
                    onChanged: (v) => setState(() => _seater = v),
                  ),

                  const SizedBox(height: 22),

                  _Label('NOTE (OPTIONAL)'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _note,
                    maxLines: 3,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      hintText: 'Special requests, group members, etc.',
                    ),
                  ),

                  const SizedBox(height: 6),
                  _Totals(
                    seatCount: _totalSeats,
                    estTotal: _estTotal,
                  ),
                ],
              ),
            ),

            // Sticky bottom CTA.
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
                    'Tapping below saves your request and opens WhatsApp '
                    'with a pre-filled message — just hit Send.',
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
                      onPressed: _saving ? null : _submit,
                      icon: _saving
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
                        _saving
                            ? 'Saving…'
                            : 'Confirm & open WhatsApp',
                        style: GoogleFonts.inter(
                          fontSize: 15,
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
}

class _SummaryCard extends StatelessWidget {
  final Tour tour;
  const _SummaryCard({required this.tour});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.brandAccent.withValues(alpha: 0.4),
        ),
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

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: AppTheme.textMuted,
        letterSpacing: 1.4,
      ),
    );
  }
}

class _SeatStepper extends StatelessWidget {
  final String label;
  final String sublabel;
  final int value;
  final ValueChanged<int> onChanged;

  const _SeatStepper({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
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
                color: theme.colorScheme.onSurface,
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

  const _Totals({required this.seatCount, required this.estTotal});

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
              color: AppTheme.textSecondary,
            ),
          ),
          const Spacer(),
          if (estTotal > 0)
            Text(
              'Estimated total: ₹${estTotal.toStringAsFixed(0)}',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
        ],
      ),
    );
  }
}
