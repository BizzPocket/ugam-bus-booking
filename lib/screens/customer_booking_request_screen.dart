import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config/theme.dart';
import '../controllers/user_controller.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../services/customer_requests_store.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/phone_normalize.dart';

/// Customer-side seat request form.
///
/// Two modes:
///   • Create  — [existing] is null. Inserts into booking_requests + upserts
///     into passengers, then opens WhatsApp with the standard request message.
///   • Edit    — [existing] is non-null. Calls booking_request_customer_update
///     RPC (which atomically updates both tables and stamps customer_edited_at),
///     then opens WhatsApp with an "updated request" variant message so the
///     organiser sees this isn't a fresh ping.
///
/// Edit mode is only entered for entries where the server says the request
/// is still pending and no seats have been assigned — the My Requests screen
/// enforces that gate, and the RPC enforces it again server-side.
///
/// Seat choices are intentionally limited to Double Sofa and Single Sofa.
/// The agent decides upper/lower berth assignment later, so the customer
/// doesn't have to think about it.
class CustomerBookingRequestScreen extends StatefulWidget {
  final Tour tour;
  final CustomerRequestEntry? existing;

  const CustomerBookingRequestScreen({
    super.key,
    required this.tour,
    this.existing,
  });

  bool get isEditing => existing != null;

  @override
  State<CustomerBookingRequestScreen> createState() =>
      _CustomerBookingRequestScreenState();
}

class _CustomerBookingRequestScreenState
    extends State<CustomerBookingRequestScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();

  int _doubleSofa = 0;
  int _singleSofa = 0;

  bool _saving = false;
  bool _showNote = false;

  int get _totalSeats => _doubleSofa + _singleSofa;
  double get _estTotal => widget.tour.pricePerSeat * _totalSeats;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.customerName;
      // Stored as '+91XXXXXXXXXX' — show just the 10-digit local part.
      _phone.text = normalisePhone(e.customerPhone);
      _doubleSofa = e.doubleSofa;
      _singleSofa = e.singleSofa;
      if (e.note != null && e.note!.isNotEmpty) {
        _note.text = e.note!;
        _showNote = true;
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty) {
      AppSnackBar.error(tr('customer_booking.err_name_required'));
      return;
    }
    if (phone.length != 10) {
      AppSnackBar.error(tr('customer_booking.err_phone_invalid'));
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error(tr('customer_booking.err_no_seats'));
      return;
    }
    // Organiser phone is best-effort: old tours may have null `createdBy`.
    // We still save the request — the agent sees it in the Requests tab —
    // and only skip the WhatsApp handoff when we don't know who to message.
    final adminPhone = widget.tour.createdBy;
    final hasOrganiser = adminPhone != null && adminPhone.isNotEmpty;

    setState(() => _saving = true);

    try {
      final note = _note.text.trim();
      final normalisedPhone = '+91${normalisePhone(phone)}';

      if (widget.isEditing) {
        await _submitEdit(
          name: name,
          normalisedPhone: normalisedPhone,
          note: note,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
      } else {
        await _submitCreate(
          name: name,
          rawPhone: phone,
          normalisedPhone: normalisedPhone,
          note: note,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
      }
    } catch (_) {
      AppSnackBar.error(tr('customer_booking.err_save_failed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitCreate({
    required String name,
    required String rawPhone,
    required String normalisedPhone,
    required String note,
    required String? adminPhone,
    required bool hasOrganiser,
  }) async {
    final requestId = const Uuid().v4();

    // 1. Audit row in booking_requests (raw form snapshot).
    await Supabase.instance.client.from('booking_requests').insert({
      'id': requestId,
      'tour_id': widget.tour.id,
      'customer_phone': normalisedPhone,
      'customer_name': name,
      'party_size': _totalSeats,
      'raw_form': {
        'double_sofa': _doubleSofa,
        'single_sofa': _singleSofa,
        if (note.isNotEmpty) 'note': note,
      },
    });

    // 2. Live row in passengers — this is the table the admin's Requests
    //    screen actually reads. The unique (tour_id, phone) index makes
    //    the upsert idempotent for re-submissions.
    final requestLines = _buildRequestLines();
    final passenger = Passenger(
      tourId: widget.tour.id,
      name: name,
      phone: normalisedPhone,
      requestLines: requestLines,
      note: note.isEmpty ? null : note,
    );
    await Supabase.instance.client
        .from('passengers')
        .upsert(passenger.toMap(), onConflict: 'tour_id,phone');

    // 3. Device-local journal so the customer can find this request again
    //    on their My Requests screen.
    await CustomerRequestsStore().upsert(CustomerRequestEntry(
      id: requestId,
      tourId: widget.tour.id,
      tourTitle: widget.tour.title,
      tourFromCity: widget.tour.fromCity,
      tourToCity: widget.tour.toCity,
      tourDepartureDate: widget.tour.departureDate,
      tourPricePerSeat: widget.tour.pricePerSeat,
      customerName: name,
      customerPhone: normalisedPhone,
      partySize: _totalSeats,
      doubleSofa: _doubleSofa,
      singleSofa: _singleSofa,
      note: note.isEmpty ? null : note,
      status: 'pending',
      createdAt: DateTime.now(),
    ));

    // Auto-grow the tour creator admin's contact directory. Best-effort:
    // if it fails (network, permissions), the booking still went through.
    if (hasOrganiser && Get.isRegistered<UserController>()) {
      // ignore: unawaited_futures
      Get.find<UserController>().autoGrowFromBooking(
        tourCreatorPhone: adminPhone!,
        passengerPhone: rawPhone,
        passengerName: name,
      );
    }

    // Hand off to WhatsApp when we know the organiser. Old tours with
    // no `createdBy` skip this step — the agent still sees the request
    // in the Requests tab.
    if (hasOrganiser) {
      await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone!,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: _singleSofa,
        doubleSofaCount: _doubleSofa,
        note: note.isEmpty ? null : note,
      );
    }

    if (!mounted) return;
    Get.back();
    AppSnackBar.success(
      hasOrganiser
          ? tr('customer_booking.success_sent_wa')
          : tr('customer_booking.success_sent_no_wa'),
      title: tr('customer_booking.success_title_submitted'),
    );
  }

  Future<void> _submitEdit({
    required String name,
    required String normalisedPhone,
    required String note,
    required String? adminPhone,
    required bool hasOrganiser,
  }) async {
    final existing = widget.existing!;
    final requestLines = _buildRequestLines();
    final requestLinesJson =
        requestLines.map((rl) => rl.toMap()).toList();

    // The RPC enforces server-side that status is still 'pending' AND no
    // seats have been assigned yet. Returns false if either gate fails.
    final ok = await Supabase.instance.client.rpc(
      'booking_request_customer_update',
      params: {
        'p_id': existing.id,
        'p_party_size': _totalSeats,
        'p_customer_name': name,
        'p_raw_form': {
          'double_sofa': _doubleSofa,
          'single_sofa': _singleSofa,
          if (note.isNotEmpty) 'note': note,
        },
        'p_request_lines': requestLinesJson,
      },
    );

    if (ok != true) {
      if (!mounted) return;
      AppSnackBar.warning(
        tr('customer_booking.warn_edit_blocked'),
        title: tr('customer_booking.warn_title_edit_blocked'),
      );
      // Pull the latest server state into the local store so the My Requests
      // screen shows the new status the next time it's opened.
      // ignore: unawaited_futures
      CustomerRequestsStore().refresh(existing.id);
      return;
    }

    // Mirror the edit into the device-local journal.
    await CustomerRequestsStore().upsert(existing.copyWith(
      customerName: name,
      partySize: _totalSeats,
      doubleSofa: _doubleSofa,
      singleSofa: _singleSofa,
      note: note.isEmpty ? null : note,
      customerEditedAt: DateTime.now(),
      lastRefreshedAt: DateTime.now(),
    ));

    if (hasOrganiser) {
      await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone!,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: _singleSofa,
        doubleSofaCount: _doubleSofa,
        note: note.isEmpty ? null : note,
        isUpdate: true,
      );
    }

    if (!mounted) return;
    Get.back();
    AppSnackBar.success(
      hasOrganiser
          ? tr('customer_booking.success_updated_wa')
          : tr('customer_booking.success_updated_no_wa'),
      title: tr('customer_booking.success_title_updated'),
    );
  }

  List<RequestLine> _buildRequestLines() => <RequestLine>[
        if (_doubleSofa > 0)
          RequestLine(seatType: SeatType.doubleSofa, qty: _doubleSofa),
        if (_singleSofa > 0)
          RequestLine(seatType: SeatType.singleSofa, qty: _singleSofa),
      ];

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
          tr('customer_booking.title'),
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

                  _Label(tr('customer_booking.label_your_name')),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      hintText: tr('customer_booking.hint_your_name'),
                    ),
                  ),
                  const SizedBox(height: 18),

                  _Label(tr('customer_booking.label_phone')),
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

                  _Label(tr('customer_booking.label_seat_count')),
                  const SizedBox(height: 6),
                  _SeatTile(
                    icon: Icons.king_bed_rounded,
                    label: tr('customer_booking.seat_double_sofa_label'),
                    sublabel: tr('customer_booking.seat_double_sofa_sub'),
                    value: _doubleSofa,
                    onChanged: (v) => setState(() => _doubleSofa = v),
                  ),
                  const SizedBox(height: 10),
                  _SeatTile(
                    icon: Icons.single_bed_rounded,
                    label: tr('customer_booking.seat_single_sofa_label'),
                    sublabel: tr('customer_booking.seat_single_sofa_sub'),
                    value: _singleSofa,
                    onChanged: (v) => setState(() => _singleSofa = v),
                  ),

                  const SizedBox(height: 18),

                  // Collapsible note — fewer fields on first sight.
                  if (!_showNote)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            setState(() => _showNote = true),
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: Text(tr('customer_booking.add_note_button')),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.textSecondary,
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    )
                  else ...[
                    _Label(tr('customer_booking.label_note')),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _note,
                      maxLines: 3,
                      maxLength: 200,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: tr('customer_booking.hint_note'),
                      ),
                    ),
                  ],

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
                    tr('customer_booking.cta_hint'),
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
                            ? tr('customer_booking.button_saving')
                            : tr('customer_booking.button_confirm'),
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
            tr('customer_booking.route_price', namedArgs: {
              'from': tour.fromCity,
              'to': tour.toCity,
              'price': tour.pricePerSeat.toStringAsFixed(0),
            }),
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

class _SeatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final int value;
  final ValueChanged<int> onChanged;

  const _SeatTile({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = value > 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.brandLight
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? AppTheme.brand : theme.colorScheme.outline,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          // Icon chip
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.brand.withValues(alpha: 0.15)
                  : AppTheme.bgLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 22,
              color: selected ? AppTheme.brand : AppTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    height: 1.3,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _StepperButton(
            icon: Icons.remove_rounded,
            enabled: value > 0,
            onTap: () => onChanged(value - 1),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: selected
                    ? AppTheme.brand
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          _StepperButton(
            icon: Icons.add_rounded,
            enabled: value < 8,
            onTap: () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: enabled ? AppTheme.brand : AppTheme.bgLight,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? Colors.white : AppTheme.textMuted,
        ),
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
            plural('customer_booking.totals_seat', seatCount),
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
          const Spacer(),
          if (estTotal > 0)
            Text(
              tr('customer_booking.totals_estimated', namedArgs: {
                'amount': estTotal.toStringAsFixed(0),
              }),
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
