import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';
import '../services/customer_requests_store.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/phone_normalize.dart';
import '../widgets/booking_capture_form.dart';

/// Customer-side seat request form — image-5 fidelity.
///
/// Two modes:
///   • Create  — [existing] is null. Inserts into booking_requests + upserts
///     into passengers, then opens WhatsApp with the standard request message.
///   • Edit    — [existing] is non-null. Calls booking_request_customer_update
///     RPC (which atomically updates both tables and stamps customer_edited_at),
///     then opens WhatsApp with an "updated request" variant message so the
///     organiser sees this isn't a fresh ping.
///
/// Visual treatment matches admin's create_tour_screen.dart: tour preview
/// card on top + single-column UgamInput fields + sticky bottom UgamCTA
/// with passenger-count chip.
///
/// The input collection (name/phone/trip-type/seat counts/note) is delegated
/// to the shared [BookingCaptureForm] so every booking surface stays in sync.
/// This screen owns only the Scaffold, the tour preview, the submit CTA, and
/// the persistence + WhatsApp handoff.
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
  final _formKey = GlobalKey<BookingCaptureFormState>();

  bool _saving = false;

  // Pre-fill payload for edit mode (and the "Book" deep-link, which may pass an
  // existing entry to resume). Built once in initState from [widget.existing].
  BookingCaptureInitial? _initial;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _initial = BookingCaptureInitial(
        name: e.customerName,
        phone: e.customerPhone,
        tripType: e.tripType,
        doubleSofa: e.doubleSofa,
        singleSofa: e.singleSofa,
        note: e.note,
      );
    }
  }

  // ─── BUSINESS LOGIC — PRESERVED VERBATIM ───────────────────────────

  Future<void> _submit() async {
    // The shared form validates and surfaces inline field errors itself; it
    // returns null when invalid, so we early-return without touching the network.
    final data = _formKey.currentState?.collect();
    if (data == null) return;

    final adminPhone = widget.tour.createdBy;
    final hasOrganiser = adminPhone != null && adminPhone.isNotEmpty;
    final normalisedPhone = data.normalisedPhone;

    // Anti-abuse (no external verification): block a repeat pending request for
    // this trip from the same number, and rate-limit rapid-fire submissions.
    if (!widget.isEditing) {
      final blocked = await _preflightCreate(normalisedPhone);
      if (blocked != null) {
        AppSnackBar.error(blocked);
        return;
      }
    }

    setState(() => _saving = true);
    try {
      if (widget.isEditing) {
        await _submitEdit(
          data: data,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
      } else {
        await _submitCreate(
          data: data,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
        await _markSubmitted();
      }
    } catch (e, st) {
      // Surface the real cause in logs so a failing submit can be diagnosed
      // (the customer still sees the friendly message).
      debugPrint('customer booking submit failed — $e\n$st');
      AppSnackBar.error(tr('customer_booking.err_save_failed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static const _kLastRequestMsKey = 'last_request_ms';
  static const _cooldownMs = 15000;

  /// Returns an error message to block submission, or null to allow it.
  /// Guards (device-local, no server/verification): one pending request per
  /// trip per number, and a short cooldown between submissions.
  Future<String?> _preflightCreate(String normalisedPhone) async {
    final mine = normalisePhone(normalisedPhone);
    final existing = await CustomerRequestsStore().list();
    final duplicate = existing.any(
      (e) =>
          e.tourId == widget.tour.id &&
          normalisePhone(e.customerPhone) == mine &&
          e.status.toLowerCase() == 'pending',
    );
    if (duplicate) return tr('customer_booking.err_duplicate');

    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_kLastRequestMsKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < _cooldownMs) return tr('customer_booking.err_too_fast');
    return null;
  }

  Future<void> _markSubmitted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastRequestMsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _submitCreate({
    required BookingCaptureData data,
    required String? adminPhone,
    required bool hasOrganiser,
  }) async {
    final name = data.name;
    final rawPhone = data.phone;
    final normalisedPhone = data.normalisedPhone;
    final note = data.note ?? '';
    final requestId = const Uuid().v4();
    final requestLines = data.lines;
    final rawForm = <String, dynamic>{
      'double_sofa': data.doubleSofa,
      'single_sofa': data.singleSofa,
      'trip_type': data.tripType.storageKey,
      if (note.isNotEmpty) 'note': note,
    };

    try {
      // Atomic create via a SECURITY DEFINER RPC: inserts the request AND
      // upserts the passenger in ONE transaction. Unlike a raw anon upsert,
      // this correctly handles a returning customer re-submitting the same
      // trip (the ON CONFLICT update runs as the function owner, so it isn't
      // blocked by the missing anon UPDATE policy on passengers).
      await Supabase.instance.client.rpc(
        'submit_booking_request',
        params: {
          'p_request_id': requestId,
          'p_tour_id': widget.tour.id,
          'p_phone': normalisedPhone,
          'p_name': name,
          'p_party_size': data.totalSeats,
          'p_trip_type': data.tripType.storageKey,
          'p_raw_form': rawForm,
          'p_request_lines': requestLines.map((l) => l.toMap()).toList(),
          'p_note': note.isEmpty ? null : note,
        },
      );
    } on PostgrestException catch (e) {
      // RPC not deployed yet (migration 014). Fall back to the legacy two
      // writes so first-time bookings still go through.
      if (e.code != 'PGRST202') rethrow;
      await Supabase.instance.client.from('booking_requests').insert({
        'id': requestId,
        'tour_id': widget.tour.id,
        'customer_phone': normalisedPhone,
        'customer_name': name,
        'party_size': data.totalSeats,
        'trip_type': data.tripType.storageKey,
        'raw_form': rawForm,
      });
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: name,
        phone: normalisedPhone,
        requestLines: requestLines,
        note: note.isEmpty ? null : note,
        tripType: data.tripType,
      );
      await Supabase.instance.client
          .from('passengers')
          .upsert(passenger.toMap(), onConflict: 'tour_id,phone');
    }

    await CustomerRequestsStore().upsert(
      CustomerRequestEntry(
        id: requestId,
        tourId: widget.tour.id,
        tourTitle: widget.tour.title,
        tourFromCity: widget.tour.fromCity,
        tourToCity: widget.tour.toCity,
        tourDepartureDate: widget.tour.departureDate,
        tourPricePerSeat: widget.tour.pricePerSeat,
        customerName: name,
        customerPhone: normalisedPhone,
        partySize: data.totalSeats,
        doubleSofa: data.doubleSofa,
        singleSofa: data.singleSofa,
        note: note.isEmpty ? null : note,
        tripType: data.tripType,
        status: 'pending',
        createdAt: DateTime.now(),
      ),
    );

    if (hasOrganiser && Get.isRegistered<UserController>()) {
      // ignore: unawaited_futures
      Get.find<UserController>().autoGrowFromBooking(
        tourCreatorPhone: adminPhone!,
        passengerPhone: rawPhone,
        passengerName: name,
      );
    }

    // Whether WhatsApp actually opened. Previously this bool was discarded and
    // the customer was told "tap Send in WhatsApp" even when WhatsApp never
    // launched (not installed / link rejected) — so they'd wait for a send they
    // couldn't make and the organiser would seem unreachable. The request is
    // already saved server-side regardless, so we just message honestly.
    var whatsAppOpened = false;
    if (hasOrganiser) {
      whatsAppOpened = await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone!,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: data.singleSofa,
        doubleSofaCount: data.doubleSofa,
        note: note.isEmpty ? null : note,
        tripType: data.tripType,
      );
    }

    if (!mounted) return;
    // Hand off to "My Requests" so the customer SEES their submitted request
    // being tracked (status, seats once assigned) instead of being dropped
    // back on the tour detail with no path to it. `offNamed` replaces this
    // form, so back from My Requests returns to the tour list/detail.
    Get.offNamed(AppRoutes.customerMyRequests);
    final String message;
    if (!hasOrganiser) {
      message = tr('customer_booking.success_sent_no_wa');
    } else if (whatsAppOpened) {
      message = tr('customer_booking.success_sent_wa');
    } else {
      message = tr('customer_booking.success_saved_wa_failed');
    }
    AppSnackBar.success(
      message,
      title: tr('customer_booking.success_title_submitted'),
    );
  }

  Future<void> _submitEdit({
    required BookingCaptureData data,
    required String? adminPhone,
    required bool hasOrganiser,
  }) async {
    final existing = widget.existing!;
    final name = data.name;
    final note = data.note ?? '';
    final requestLinesJson = data.lines.map((rl) => rl.toMap()).toList();

    final ok = await Supabase.instance.client.rpc(
      'booking_request_customer_update',
      params: {
        'p_id': existing.id,
        'p_party_size': data.totalSeats,
        'p_customer_name': name,
        'p_raw_form': {
          'double_sofa': data.doubleSofa,
          'single_sofa': data.singleSofa,
          'trip_type': data.tripType.storageKey,
          if (note.isNotEmpty) 'note': note,
        },
        'p_request_lines': requestLinesJson,
        'p_trip_type': data.tripType.storageKey,
      },
    );

    if (ok != true) {
      if (!mounted) return;
      AppSnackBar.warning(
        tr('customer_booking.warn_edit_blocked'),
        title: tr('customer_booking.warn_title_edit_blocked'),
      );
      // ignore: unawaited_futures
      CustomerRequestsStore().refresh(existing.id);
      return;
    }

    await CustomerRequestsStore().upsert(
      existing.copyWith(
        customerName: name,
        partySize: data.totalSeats,
        doubleSofa: data.doubleSofa,
        singleSofa: data.singleSofa,
        note: note.isEmpty ? null : note,
        tripType: data.tripType,
        customerEditedAt: DateTime.now(),
        lastRefreshedAt: DateTime.now(),
      ),
    );

    if (hasOrganiser) {
      await WhatsAppService().sendBookingRequest(
        adminPhone: adminPhone!,
        tour: widget.tour,
        customerName: name,
        singleSofaCount: data.singleSofa,
        doubleSofaCount: data.doubleSofa,
        note: note.isEmpty ? null : note,
        tripType: data.tripType,
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

  // ─── UI ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final seatCount = _formKey.currentState?.totalSeats ?? 0;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              c: c,
              title: widget.isEditing
                  ? tr('customer_booking.title_edit')
                  : tr('customer_booking.title'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xxl,
                ),
                children: [
                  _TourPreviewCard(tour: widget.tour, c: c),
                  const SizedBox(height: UgamSpacing.xl),
                  _SectionEyebrow(
                    label: tr('customer_booking.section_who_is_booking'),
                    c: c,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  BookingCaptureForm(
                    key: _formKey,
                    fromCity: widget.tour.fromCity,
                    toCity: widget.tour.toCity,
                    initial: _initial,
                    enableContacts: false,
                    // Live-update the CTA's count chip as seats change.
                    onChanged: () => setState(() {}),
                  ),
                ],
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: _saving
                    ? tr('customer_booking.button_saving')
                    : (widget.isEditing
                          ? tr('customer_booking.button_update')
                          : tr('customer_booking.button_submit')),
                leadingIcon: Icons.send_rounded,
                loading: _saving,
                // Live "N seats" tabular value on the right — reads off the
                // shared form's totalSeats getter, refreshed via onChanged.
                trailingValue: seatCount > 0
                    ? (seatCount == 1
                          ? tr('customer_booking.cta_seat_count_one')
                          : tr('customer_booking.cta_seat_count', namedArgs: {
                              'n': '$seatCount',
                            }))
                    : null,
                onPressed: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TOP BAR ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  const _TopBar({required this.c, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              title,
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 22),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── TOUR PREVIEW CARD ────────────────────────────────────────────────

class _TourPreviewCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _TourPreviewCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 88,
              height: 88,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  UgamBusBackdrop(seed: tour.id),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _formatDate(tour.departureDate),
                        style: UgamText.tabular(
                          UgamText.micro.copyWith(
                            color: Colors.white,
                            fontSize: 9.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tour.title,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  '${tour.fromCity} → ${tour.toCity}',
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const keys = [
      'app.month.short.jan',
      'app.month.short.feb',
      'app.month.short.mar',
      'app.month.short.apr',
      'app.month.short.may',
      'app.month.short.jun',
      'app.month.short.jul',
      'app.month.short.aug',
      'app.month.short.sep',
      'app.month.short.oct',
      'app.month.short.nov',
      'app.month.short.dec',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${tr(keys[d.month - 1]).toUpperCase()}';
  }
}

// ─── SECTION EYEBROW ──────────────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
    );
  }
}
