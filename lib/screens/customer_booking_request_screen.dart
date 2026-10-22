import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../controllers/tour_controller.dart';
import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';
import '../services/chart_advance_payment.dart';
import '../services/customer_requests_store.dart';
import '../services/error_reporter.dart';
import '../services/seat_chart_booking_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/phone_normalize.dart';
import '../utils/request_payment_gate.dart';
import '../utils/round_trip_combine.dart';
import '../utils/time_format.dart';
import '../utils/tour_public_summary.dart';
import '../widgets/booking_capture_form.dart';
import 'customer_format.dart';

part 'customer_booking_request/brief_and_steps.dart';

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
/// Outcome of the device-local create preflight. `tooFast` hard-blocks;
/// `duplicate` soft-warns (submit-anyway); `ok` proceeds silently.
enum _PreflightResult { ok, tooFast, duplicate }

/// The request id to RE-USE for a submit, or null to mint a fresh one.
///
/// Re-used only when the previous attempt failed AND carried exactly the same
/// content ([signature]); a changed form is a different request.
@visibleForTesting
String? pendingRequestIdFor(
  ({String id, String signature})? pending,
  String signature,
) =>
    (pending != null && pending.signature == signature) ? pending.id : null;

/// True when a RE-SENT submit failed only because the first attempt — which
/// timed out on the phone — had in fact landed: our own request id is already
/// the booking_requests primary key.
@visibleForTesting
bool isSubmitAlreadyLanded(PostgrestException e, {required bool isResend}) =>
    isResend &&
    e.code == '23505' &&
    '${e.message} ${e.details ?? ''}'.contains('booking_requests_pkey');

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

  /// The tour's buses, fetched over the anon RPC.
  ///
  /// `Tour.buses` is ALWAYS empty on the customer side — `buses` has no anon
  /// SELECT policy — so the price bands this form quotes from are unreachable
  /// through the model and have to come from `public_tour_buses` (migration
  /// 057). Until it answers the form simply shows no bands, which degrades to
  /// exactly today's free request rather than to a wrong price.
  TourPublicSummary _summary = TourPublicSummary.pending;

  /// Whether the customer asserted a payment during THIS submit. Drives only
  /// the closing message — the durable record is the claim on the server and
  /// `claimedPaise` on the local ticket.
  bool _paymentRecorded = false;

  /// The request id of a submit that FAILED, kept with the exact content it
  /// carried — see [pendingRequestIdFor].
  ({String id, String signature})? _pendingRequest;

  @override
  void initState() {
    super.initState();
    _loadBuses();
    final e = widget.existing;
    if (e != null) {
      _initial = BookingCaptureInitial(
        name: e.customerName,
        phone: e.customerPhone,
        tripType: e.tripType,
        doubleSofa: e.doubleSofa,
        singleSofa: e.singleSofa,
        note: e.note,
        pickupLocationId: e.pickupLocationId,
        pickupLocationName: e.pickupLocationName,
      );
    }
  }

  /// Never throws: [SeatChartBookingService.publicSummary] answers
  /// [TourPublicSummary.pending] on any failure, so an offline customer — or a
  /// server without migration 057 — sees the form without bands instead of an
  /// error, and the request stays submittable.
  Future<void> _loadBuses() async {
    final summary = await SeatChartBookingService().publicSummary(
      widget.tour.id,
    );
    if (!mounted) return;
    setState(() => _summary = summary);
  }

  // ─── BUSINESS LOGIC — PRESERVED VERBATIM ───────────────────────────

  Future<void> _submit() async {
    // `_saving` is only raised after the preflight awaits and dialogs below, so
    // a second tap in that window would run a second submit.
    if (_saving) return;
    // The shared form validates and surfaces inline field errors itself; it
    // returns null when invalid, so we early-return without touching the network.
    var data = _formKey.currentState?.collect();
    if (data == null) return;

    // A GO-only + RET-only pair of the SAME seat type is physically ONE seat for
    // the WHOLE trip (a round trip) that got split into two one-way lines — it
    // over-counts the party and reads as two seats. Offer to fold each such pair
    // into a single round-trip seat, or keep them as two separate one-way seats.
    if (hasCombinableRoundTripPairs(data.lines)) {
      if (!mounted) return;
      final combine = await UgamDialog.confirm(
        context,
        title: tr('customer_booking.combine_title'),
        message: tr('customer_booking.combine_body'),
        confirmLabel: tr('customer_booking.combine_yes'),
        cancelLabel: tr('customer_booking.combine_no'),
      );
      if (combine) {
        final lines = combineRoundTripPairs(data.lines);
        final counts = unitCountsOf(lines);
        data = BookingCaptureData(
          name: data.name,
          phone: data.phone,
          normalisedPhone: data.normalisedPhone,
          tripType: summaryTripTypeOf(lines),
          lines: lines,
          note: data.note,
          doubleSofa: counts.doubleSofa,
          singleSofa: counts.singleSofa,
          seater: counts.seater,
          pickupLocationId: data.pickupLocationId,
          pickupLocationName: data.pickupLocationName,
        );
      }
    }

    // Bookings close the moment the organiser locks the tour. Re-check against
    // the LIVE tour where we have it (this screen can be opened from a stale
    // cache — e.g. the "My requests" edit path rebuilds a Tour from a local
    // entry), falling back to the tour we were handed. This blocks both a fresh
    // request and an edit once the allocation is final.
    final liveTour = Get.isRegistered<TourController>()
        ? Get.find<TourController>().getTour(widget.tour.id)
        : null;
    if (!(liveTour ?? widget.tour).acceptsBookings) {
      AppSnackBar.error(tr('customer_booking.err_bookings_closed'));
      return;
    }

    final adminPhone = widget.tour.createdBy;
    final hasOrganiser = adminPhone != null && adminPhone.isNotEmpty;
    final normalisedPhone = data.normalisedPhone;

    // Anti-abuse (no external verification): rate-limit rapid-fire submissions
    // (hard block) and SOFT-warn on an exact-duplicate pending request — same
    // phone + tour + name + seats — letting the customer submit anyway.
    if (!widget.isEditing) {
      final preflight = await _preflightCreate(
        normalisedPhone: normalisedPhone,
        name: data.name,
        doubleSofa: data.doubleSofa,
        singleSofa: data.singleSofa,
      );
      if (preflight == _PreflightResult.tooFast) {
        AppSnackBar.error(tr('customer_booking.err_too_fast'));
        return;
      }
      if (preflight == _PreflightResult.duplicate) {
        if (!mounted) return;
        final submitAnyway = await UgamDialog.confirm(
          context,
          title: tr('customer_booking.warn_duplicate_title'),
          message: tr('customer_booking.warn_duplicate_body'),
          confirmLabel: tr('customer_booking.warn_duplicate_submit'),
          cancelLabel: tr('customer_booking.warn_duplicate_cancel'),
        );
        if (!submitAnyway) return;
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
        // Arm the anti-spam cooldown BEFORE the write, not after a successful
        // one. Stamping it only on success meant a failing submit left the
        // cooldown unarmed, so an anxious customer could re-tap immediately and
        // repeat the failure as fast as they could press — which is exactly how
        // one bad submit turned into three identical organiser notifications.
        await _markSubmitted();
        await _submitCreate(
          data: data,
          adminPhone: adminPhone,
          hasOrganiser: hasOrganiser,
        );
      }
    } catch (e, st) {
      // Surface the real cause so a failing submit can be diagnosed — to the
      // error log, not a debugPrint that never leaves the device.
      ErrorReporter.report(
        kind: 'customer_booking_submit',
        error: e,
        stack: st,
      );
      AppSnackBar.error(_submitErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Turns a submit failure into something the customer can act on.
  ///
  /// The gates inside `submit_booking_request` raise `check_violation` with a
  /// specific reason (tour not public / bookings closed / pickup missing).
  /// Collapsing all of those into "try again" told the customer to repeat a
  /// submission that could never succeed, so each reason gets its own line and
  /// only genuine transport failures keep the retry wording.
  String _submitErrorMessage(Object e) {
    if (e is PostgrestException && e.code == '23514') {
      final reason = e.message.toLowerCase();
      if (reason.contains('pickup')) {
        return tr('customer_booking.err_pickup_required');
      }
      if (reason.contains('closed') || reason.contains('not open')) {
        return tr('customer_booking.err_bookings_closed');
      }
    }
    return tr('customer_booking.err_save_failed');
  }

  static const _kLastRequestMsKey = 'last_request_ms';
  static const _cooldownMs = 15000;

  /// Device-local preflight (no server/verification). Returns:
  ///   • [_PreflightResult.tooFast]  — rapid-fire submission; HARD block.
  ///   • [_PreflightResult.duplicate] — an EXACT-content pending request already
  ///     exists (same phone + tour + name + seat counts); caller SOFT-warns and
  ///     may submit anyway. A different name or seat mix is NOT a duplicate.
  ///   • [_PreflightResult.ok]        — nothing in the way.
  /// Cooldown is checked first so spam can't slip through behind a duplicate.
  Future<_PreflightResult> _preflightCreate({
    required String normalisedPhone,
    required String name,
    required int doubleSofa,
    required int singleSofa,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_kLastRequestMsKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < _cooldownMs) return _PreflightResult.tooFast;

    final mine = normalisePhone(normalisedPhone);
    final myName = name.trim().toLowerCase();
    final existing = await CustomerRequestsStore().list();
    final duplicate = existing.any(
      (e) =>
          e.tourId == widget.tour.id &&
          normalisePhone(e.customerPhone) == mine &&
          e.status.toLowerCase() == 'pending' &&
          e.customerName.trim().toLowerCase() == myName &&
          e.doubleSofa == doubleSofa &&
          e.singleSofa == singleSofa,
    );
    if (duplicate) return _PreflightResult.duplicate;
    return _PreflightResult.ok;
  }

  Future<void> _markSubmitted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastRequestMsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// PostgREST's "function not found in the schema cache" code. It does NOT
  /// only mean "migration 014 was never applied" — PostgREST also answers this
  /// for a few seconds after ANY DDL, while it rebuilds its schema cache. A
  /// customer who taps Submit inside that window used to be dropped onto the
  /// (broken) legacy fallback; now we simply wait for the cache and re-issue.
  static const _kSchemaCacheMiss = 'PGRST202';

  /// Calls `submit_booking_request`, retrying ONCE on a schema-cache miss.
  ///
  /// Safe to retry: the RPC is keyed by the client-generated `p_request_id`
  /// (booking_requests PK), so a retry after a genuine miss cannot duplicate —
  /// and a miss means PostgREST never reached Postgres, so nothing was written.
  Future<void> _callSubmitRpc({
    required Map<String, dynamic> params,
    bool isResend = false,
  }) async {
    try {
      try {
        await Supabase.instance.client.rpc(
          'submit_booking_request',
          params: params,
        );
      } on PostgrestException catch (e) {
        if (e.code != _kSchemaCacheMiss) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await Supabase.instance.client.rpc(
          'submit_booking_request',
          params: params,
        );
      }
    } on PostgrestException catch (e) {
      // A re-send of a submit that timed out: the first one DID land, and the
      // request id (booking_requests PK, minted by us) now exists. The RPC is
      // one transaction, so nothing was duplicated — this is the success the
      // customer never heard about, not a failure to show them.
      if (isSubmitAlreadyLanded(e, isResend: isResend)) return;
      rethrow;
    }
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
    final requestLines = data.lines;
    final rawForm = <String, dynamic>{
      'double_sofa': data.doubleSofa,
      'single_sofa': data.singleSofa,
      'trip_type': data.tripType.storageKey,
      if (note.isNotEmpty) 'note': note,
    };
    // On a 2G link a submit can LAND and still time out on the phone. A fresh
    // id per tap turned the customer's retry into a second request — and a
    // second "New booking request" push to the organiser. Re-sending the SAME
    // content re-uses the id instead, which the RPC's primary key makes
    // idempotent (see [_callSubmitRpc]).
    final signature = jsonEncode({
      'tour': widget.tour.id,
      'phone': normalisedPhone,
      'name': name,
      'lines': requestLines.map((l) => l.toMap()).toList(),
      'note': note,
      'pickup': data.pickupLocationId,
    });
    final pending = pendingRequestIdFor(_pendingRequest, signature);
    final isResend = pending != null;
    final requestId = pending ?? const Uuid().v4();
    _pendingRequest = (id: requestId, signature: signature);

    // Atomic create via a SECURITY DEFINER RPC: inserts a fresh passenger AND
    // its booking_requests audit row in ONE transaction, linking them by
    // passenger_id. Every submission creates its own pair, so one phone can
    // hold multiple distinct requests on the same tour (migration 030). Runs as
    // the function owner, so the insert isn't blocked by anon RLS.
    //
    // There is DELIBERATELY no non-RPC fallback. The legacy one (two loose
    // writes) could not succeed as anon and silently corrupted the roster:
    // anon RLS ACCEPTS a booking_requests insert unconditionally but REFUSES
    // the passengers insert, so the fallback always landed a booking_requests
    // row — whose AFTER INSERT trigger pushed "New booking request" to the
    // organiser — and then threw on the passenger. The admin app only ever
    // reads passengers (sync_service.dart), so the organiser got a notification
    // for a request that existed nowhere, while the customer was told the save
    // had failed and re-tapped, minting one more orphan + push per tap.
    // If the RPC is unreachable we now write NOTHING and fail honestly.
    await _callSubmitRpc(
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
        'p_pickup_location_id': data.pickupLocationId,
        'p_pickup_location_name': data.pickupLocationName,
      },
      isResend: isResend,
    );
    // Landed: the next submit is a NEW request and gets a new id.
    _pendingRequest = null;

    // What this request costs, decided from the bands the customer actually
    // chose. `cannotCollect` (the organiser set no VPA) deliberately behaves
    // like a free request rather than blocking the booking.
    final plan = planRequestPayment(tour: widget.tour, lines: requestLines);

    final entry = CustomerRequestEntry(
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
      pickupLocationId: data.pickupLocationId,
      pickupLocationName: data.pickupLocationName,
      tripType: data.tripType,
      status: 'pending',
      organiserPhone: widget.tour.createdBy,
      createdAt: DateTime.now(),
      // Everything "Pay now" needs later, captured NOW so the retry works
      // offline and cannot be re-quoted if the agent re-prices the bus.
      advancePaise: plan.amountPaise,
      collectVpa: widget.tour.collectVpa,
      collectPayeeName: widget.tour.collectPayeeName,
    );
    // Written BEFORE the payment sheet opens. If the customer fumbles their UPI
    // app, closes it, or the phone dies, the request still exists and My
    // Requests carries a Pay button — the alternative is a booking that is
    // unrecoverable from the customer's side, which is the exact dead end
    // ChartAdvancePayment was extracted to fix.
    await CustomerRequestsStore().upsert(entry);

    if (plan.needsPayment && mounted) {
      final recorded = await ChartAdvancePayment.collect(
        context: context,
        requestId: requestId,
        payeeVpa: widget.tour.collectVpa!,
        payeeName:
            (widget.tour.collectPayeeName?.trim().isNotEmpty ?? false)
                ? widget.tour.collectPayeeName!
                : widget.tour.title,
        amountPaise: plan.amountPaise,
        note: '${widget.tour.fromCity}-${widget.tour.toCity} · $name',
      );
      if (recorded) {
        await CustomerRequestsStore()
            .upsert(entry.copyWith(claimedPaise: plan.amountPaise));
      }
      _paymentRecorded = recorded;
    }

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
        pickupLocation: data.pickupLocationName,
      );
    }

    if (!mounted) return;
    // Hand off to "My Requests" so the customer SEES their submitted request
    // being tracked (status, seats once assigned) instead of being dropped
    // back on the tour detail with no path to it. `offNamed` replaces this
    // form, so back from My Requests returns to the tour list/detail.
    Get.offNamed(AppRoutes.customerMyRequests);
    final String message;
    // A request that owed money and did NOT get paid must say so plainly, and
    // name where to finish it. Reporting the cheerful "sent" line would leave
    // the customer believing they were done.
    if (plan.needsPayment && !_paymentRecorded) {
      AppSnackBar.warning(
        tr('customer_booking.saved_unpaid_body'),
        title: tr('customer_booking.saved_unpaid_title'),
      );
      return;
    }
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
        'p_pickup_location_id': data.pickupLocationId,
        'p_pickup_location_name': data.pickupLocationName,
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
        pickupLocationId: data.pickupLocationId,
        pickupLocationName: data.pickupLocationName,
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
        pickupLocation: data.pickupLocationName,
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
    final form = _formKey.currentState;
    final seatCount = form?.totalSeats ?? 0;
    // What this request costs UP FRONT, summed from the bands the customer
    // actually chose. Zero when nothing here is chargeable — a request made
    // entirely of one-leg seats, or a tour whose buses carry no bands — in
    // which case the older leg-weighted estimate is still the honest preview.
    final chargePaise = form?.chargePaise ?? 0;
    // Only promise a payment step when there is somewhere for the money to go.
    // On a tour whose organiser set no VPA the charge is real but uncollectable
    // online, so the button must not say "Pay".
    final payNow = chargePaise > 0 && widget.tour.canCollectOnline;
    // Leg-weighted estimate: a one-way (Go-only / Return-only) berth is charged
    // at 0.5 of a round-trip berth, so the preview must apply the same factor —
    // otherwise a Go-only booking reads at the full round-trip price. Rounded to
    // whole rupees by Formatters.formatMoneyInr.
    final estTotal =
        (form?.legWeightedSeats ?? 0) * widget.tour.pricePerSeat;
    final showEstimate =
        !payNow && seatCount > 0 && widget.tour.pricePerSeat > 0;

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              showBack: true,
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
                  UgamSpacing.lg,
                ),
                children: [
                  _TripBriefCard(tour: widget.tour, c: c),
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
                    // Price bands for the full-trip tab. Empty until the anon
                    // RPC answers, and empty forever on an unpriced tour —
                    // both of which keep today's free-request behaviour.
                    buses: _summary.buses,
                    availability: _summary.availability,
                    enableContacts: false,
                    // Pickup is mandatory here as on every capture surface —
                    // it's the form's default now, no per-surface opt-in.
                    // Live-update the CTA's count chip as seats change.
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  // Closes the page instead of letting it stop mid-scroll: the
                  // request flow is NOT an instant booking, and nothing else in
                  // the app ever says so.
                  _NextStepsBlock(isEditing: widget.isEditing, c: c),
                ],
              ),
            ),
          ],
        ),
      ),
      // Primary submit CTA lives in the scaffold's bottom slot (like
      // CustomerTourDetailScreen) so the sticky zone stays anchored and
      // consistent across the customer flow — not inline in the Column.
      bottomNavigationBar: UgamStickyCTA(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (payNow) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      tr('customer_booking.pay_now_label'),
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                    Text(
                      Formatters.formatMoneyInr(chargePaise / 100),
                      // The one number on this screen that is about to leave
                      // the customer's bank account — it gets the accent.
                      style: UgamText.tabular(
                        UgamText.titleS.copyWith(color: c.accent),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (showEstimate) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      tr('customer_booking.estimated_total_label'),
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                    Text(
                      Formatters.formatMoneyInr(estTotal),
                      style: UgamText.tabular(
                        UgamText.bodyStrong.copyWith(color: c.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            UgamCTA(
              label: _saving
                  ? tr('customer_booking.button_saving')
                  : (widget.isEditing
                        ? tr('customer_booking.button_update')
                        : payNow
                            ? tr('customer_booking.button_pay_submit')
                            : tr('customer_booking.button_submit')),
              leadingIcon:
                  payNow ? Icons.account_balance_wallet_outlined : Icons.send_rounded,
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
          ],
        ),
      ),
    );
  }
}
