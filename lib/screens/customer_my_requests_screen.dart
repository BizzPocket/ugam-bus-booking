import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/tour_controller.dart';
import '../components/content_block_view.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/chart_advance_payment.dart';
import '../services/customer_requests_store.dart';
import '../widgets/hold_countdown_strip.dart';
import '../services/sync_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../widgets/customer_seat_layout_sheet.dart';
import 'customer_booking_request_screen.dart';
import 'handler_bus_chart_screen.dart';

/// Customer-facing list of every booking request submitted from this
/// device — image-5 fidelity.
///
/// Layout:
///   [Title row + circle refresh]
///   [Status pills row (All / Pending / Confirmed / Cancelled)]
///   [Photo-anchored request rows]
///
/// Tap a row → opens the seat-layout sheet when seats are assigned,
/// otherwise routes to edit when editable. The data layer is preserved:
/// `CustomerRequestsStore` bootstraps from cache and refreshes per-row
/// via RPC.
class CustomerMyRequestsScreen extends StatefulWidget {
  const CustomerMyRequestsScreen({super.key});

  @override
  State<CustomerMyRequestsScreen> createState() =>
      _CustomerMyRequestsScreenState();
}

enum _StatusFilter { all, pending, confirmed, cancelled }

class _CustomerMyRequestsScreenState extends State<CustomerMyRequestsScreen> {
  final _store = CustomerRequestsStore();
  bool _loading = true;
  bool _refreshing = false;

  /// True when we have nothing to show AND the device is offline — i.e. a fresh
  /// device that can't reach the server. Distinguishes a real load failure from
  /// a genuinely-empty journal so we surface a retry instead of a false "no
  /// requests yet" blank. The journal is device-local (SharedPreferences), so
  /// once there ARE cached tickets a network hiccup never blanks them — this
  /// only ever fires while [_entries] is empty.
  bool _loadFailed = false;
  List<CustomerRequestEntry> _entries = const [];
  _StatusFilter _filter = _StatusFilter.all;

  /// Connectivity signal for the load-failure surface. The requests store talks
  /// to Supabase directly (not via SyncService), so it never gets a smartFetch
  /// read-failure result; [SyncService.isOnline] is the honest "definitely offline"
  /// signal available here. Nullable/guarded so the screen never hard-depends on
  /// the service being registered.
  SyncService? get _sync =>
      Get.isRegistered<SyncService>() ? Get.find<SyncService>() : null;

  /// Cached handler status per request id. Populated once per entry set so the
  /// `isRequestHandler` RPC is not re-fired on every rebuild.
  final Map<String, bool> _handlerStatus = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Resolves handler status for any entries we haven't checked yet and caches
  /// the result. Safe to call repeatedly — already-resolved ids are skipped.
  Future<void> _resolveHandlers(List<CustomerRequestEntry> entries) async {
    final pending = entries
        .where((e) => !_handlerStatus.containsKey(e.id))
        .toList();
    if (pending.isEmpty) return;
    for (final e in pending) {
      try {
        final isHandler = await _store.isRequestHandler(e.id);
        if (!mounted) return;
        _handlerStatus[e.id] = isHandler;
      } catch (_) {
        if (!mounted) return;
        _handlerStatus[e.id] = false;
      }
    }
    if (mounted) setState(() {});
  }

  // ─── DATA LAYER — PRESERVED ────────────────────────────────────────

  Future<void> _bootstrap() async {
    final cached = await _store.list();
    if (!mounted) return;
    setState(() {
      _entries = cached;
      _loading = false;
    });
    _resolveHandlers(cached);
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final fresh = await _store.refreshAll();
      if (!mounted) return;
      // Only a genuine can't-reach-the-server state with nothing to show should
      // read as a failure; a populated (even if stale) list stays on screen and
      // an empty journal on a live connection is the normal "no requests" empty.
      final offline = _sync?.isOnline.value == false;
      setState(() {
        _entries = fresh;
        _loadFailed = fresh.isEmpty && offline;
      });
      _resolveHandlers(fresh);
    } catch (_) {
      // Cached list is still usable; only flag a failure when there is nothing
      // already on screen to keep.
      if (mounted) setState(() => _loadFailed = _entries.isEmpty);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Re-open the advance sheet for a booking whose seats are still held.
  ///
  /// This is the recovery path that did not exist: dismissing the UPI sheet at
  /// checkout used to leave the hold alive with no way back to paying it, so
  /// the booking simply died when the hold lapsed. Everything the sheet needs
  /// was captured on the ticket when the hold was created, so this works
  /// without re-reading the tour.
  Future<void> _payAdvance(CustomerRequestEntry entry) async {
    if (!entry.canPayAdvance) return;
    await ChartAdvancePayment.retry(context: context, entry: entry);
    // Refresh either way: a recorded claim moves the booking forward, and a
    // dismissal may still have burned enough of the clock to matter.
    await _refresh();
  }

  Future<void> _openEdit(CustomerRequestEntry entry) async {
    Tour? tour;
    if (Get.isRegistered<TourController>()) {
      tour = Get.find<TourController>().getTour(entry.tourId);
    }
    tour ??= _tourFromEntry(entry);
    await Get.to<void>(
      () => CustomerBookingRequestScreen(tour: tour!, existing: entry),
    );
    _refresh();
  }

  /// Opens a BLANK create form for [entry]'s tour, so a customer can lodge a
  /// SECOND distinct request from the same number (a different traveller / seat
  /// mix). `existing` is null → the form is in create mode and inserts a fresh
  /// passenger + request (migration 030 lets one phone hold many per tour).
  Future<void> _openAddAnother(CustomerRequestEntry entry) async {
    HapticFeedback.selectionClick();
    Tour? tour;
    if (Get.isRegistered<TourController>()) {
      tour = Get.find<TourController>().getTour(entry.tourId);
    }
    tour ??= _tourFromEntry(entry);
    await Get.to<void>(
      () => CustomerBookingRequestScreen(tour: tour!),
    );
    _refresh();
  }

  Tour _tourFromEntry(CustomerRequestEntry e) => Tour(
    id: e.tourId,
    title: e.tourTitle,
    fromCity: e.tourFromCity,
    toCity: e.tourToCity,
    departureDate: e.tourDepartureDate,
    pricePerSeat: e.tourPricePerSeat,
  );

  // ─── UI ────────────────────────────────────────────────────────────

  /// Active tickets only — trips whose date has passed (completed/past) are
  /// hidden; they're history, not live bookings. Tickets for tours the
  /// organiser deleted are flagged `rejected` on refresh, so they surface
  /// under the "Cancelled" tab rather than as live tickets.
  List<CustomerRequestEntry> get _live =>
      _entries.where((e) => !e.isPast).toList();

  List<CustomerRequestEntry> get _visible {
    final live = _live;
    switch (_filter) {
      case _StatusFilter.pending:
        return live.where(_isPending).toList();
      case _StatusFilter.confirmed:
        return live.where(_isConfirmedish).toList();
      case _StatusFilter.cancelled:
        // An expired hold sits here rather than under Pending — it is no longer
        // live — but it keeps its own label and a "Book again" action, because
        // unlike a cancellation it can simply be redone.
        return live.where((e) => e.isCancelled || e.holdExpired).toList();
      case _StatusFilter.all:
        return live;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final live = _live;

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              showBack: true,
              title: tr('customer_my_requests.title'),
              actions: [
                _RefreshAction(
                  c: c,
                  refreshing: _refreshing,
                  onRefresh: _refreshing ? null : _refresh,
                ),
              ],
            ),
            if (!_loading && live.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  0,
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                ),
                child: UgamTabPills(
                  currentIndex: _filter.index,
                  onChanged: (i) =>
                      setState(() => _filter = _StatusFilter.values[i]),
                  // Count badges intentionally omitted: the badge stole width
                  // and truncated the longer gu/hi status words (પુષ્ટિ થયેલ /
                  // रद्द). The label must always be fully readable, so the tab
                  // shows the word alone and the list itself conveys the count.
                  items: [
                    UgamTabItem(label: tr('customer_my_requests.tab_all')),
                    UgamTabItem(label: tr('customer_my_requests.tab_pending')),
                    UgamTabItem(
                      label: tr('customer_my_requests.tab_confirmed'),
                    ),
                    UgamTabItem(
                      label: tr('customer_my_requests.tab_cancelled'),
                    ),
                  ],
                ),
              ),
            ],
            Expanded(
              child: _loading
                  ? _LoadingShimmer()
                  : (_loadFailed && live.isEmpty)
                  ? UgamEmpty.error(onRetry: _refresh)
                  : live.isEmpty
                  // Expanded keeps UgamEmpty vertically centred exactly as it
                  // was; the slot sits beneath it and is zero-height unless
                  // something is published. A customer with no bookings is the
                  // single best audience in the app — this is the one screen
                  // where remote content earns its place outright.
                  ? Column(
                      children: [
                        Expanded(
                          child: UgamEmpty(
                            icon: Icons.inbox_outlined,
                            title: tr('customer_my_requests.empty_title'),
                            body: tr('customer_my_requests.empty_body'),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            UgamSpacing.gutter,
                            0,
                            UgamSpacing.gutter,
                            UgamSpacing.dockClearance,
                          ),
                          child: const ContentSlot(
                            ContentSlots.customerMyRequestsEmpty,
                          ),
                        ),
                      ],
                    )
                  : _visible.isEmpty
                  ? UgamEmpty(
                      icon: Icons.filter_alt_off_rounded,
                      title: tr('customer_my_requests.empty_filter_title'),
                      body: tr('customer_my_requests.empty_filter_body'),
                    )
                  : RefreshIndicator(
                      color: c.accent,
                      onRefresh: _refresh,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          UgamSpacing.sm,
                          UgamSpacing.gutter,
                          UgamSpacing.dockClearance,
                        ),
                        // +1 for the slot at the head of the list. It renders
                        // zero-height when nothing is published, so the list
                        // is unchanged by default.
                        itemCount: _visible.length + 1,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UgamSpacing.md),
                        itemBuilder: (_, index) {
                          if (index == 0) {
                            return const ContentSlot(
                              ContentSlots.customerMyRequestsTop,
                            );
                          }
                          final i = index - 1;
                          return _RequestRow(
                            entry: _visible[i],
                            isHandler:
                                _handlerStatus[_visible[i].id] ?? false,
                            onTap: () => _onRowTap(_visible[i]),
                            onEdit: () => _openEdit(_visible[i]),
                            onViewChart: () => _openFullChart(_visible[i]),
                            onAddAnother: () => _openAddAnother(_visible[i]),
                            onPayAdvance: _payAdvance,
                            onCancel: () => _cancel(_visible[i]),
                            onRequestCancel: () => _requestCancel(_visible[i]),
                            onContact: () => _contactOrganiser(_visible[i]),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _onRowTap(CustomerRequestEntry entry) {
    HapticFeedback.selectionClick();
    // Seats are only viewable once the tour is locked — until then assignments
    // are provisional, so we neither open the layout sheet nor reveal numbers.
    if (entry.seatsVisible) {
      showCustomerSeatLayoutSheet(context, entry: entry);
    } else if (entry.hasSeatsAssigned) {
      // Assigned but not yet locked: explain why seats stay hidden for now.
      AppSnackBar.info(tr('customer_my_requests.seats_pending_toast'));
    } else if (entry.canEdit) {
      _openEdit(entry);
    }
    // Otherwise: read-only, tap is a no-op (status chip + lock copy explain).
  }

  void _openFullChart(CustomerRequestEntry entry) {
    HapticFeedback.selectionClick();
    Get.to(
      () => HandlerBusChartScreen(requestId: entry.id),
      transition: Transition.cupertino,
    );
  }

  /// Customer self-cancel — only offered while [CustomerRequestEntry.canCancel].
  /// Confirms, calls the server RPC (which re-checks the gate), then refreshes.
  /// A server refusal (the request was just confirmed) degrades to the
  /// contact-organiser message instead of a silent no-op.
  Future<void> _cancel(CustomerRequestEntry entry) async {
    HapticFeedback.selectionClick();
    final ok = await UgamDialog.confirm(
      context,
      title: tr('customer_my_requests.cancel_title'),
      message: tr('customer_my_requests.cancel_body'),
      confirmLabel: tr('customer_my_requests.cancel_confirm'),
      cancelLabel: tr('customer_my_requests.cancel_keep'),
      confirmIcon: Icons.close_rounded,
      destructive: true,
    );
    if (ok != true) return;
    final result = await _store.cancel(entry.id);
    if (!mounted) return;
    if (result == null) {
      AppSnackBar.warning(tr('customer_my_requests.cancel_blocked'));
      _refresh();
      return;
    }
    AppSnackBar.success(tr('customer_my_requests.cancel_done'));
    _refresh();
  }

  /// Customer REQUESTS cancellation of a CONFIRMED / seat-assigned booking. This
  /// does NOT free the seat — it raises a request the organiser approves later
  /// (the purely-pending instant self-cancel stays a separate path). On success
  /// it also hands the ask to the organiser over WhatsApp (the in-app flag drives
  /// the organiser push; this puts the request in their chat too), then refreshes.
  /// A server refusal degrades to a warning instead of a silent no-op.
  Future<void> _requestCancel(CustomerRequestEntry entry) async {
    HapticFeedback.selectionClick();
    final ok = await UgamDialog.confirm(
      context,
      title: tr('customer_my_requests.request_cancel_title'),
      message: tr('customer_my_requests.request_cancel_body'),
      confirmLabel: tr('customer_my_requests.request_cancel_confirm'),
      cancelLabel: tr('customer_my_requests.cancel_keep'),
      confirmIcon: Icons.event_seat_outlined,
      destructive: true,
    );
    if (ok != true) return;
    final result = await _store.requestCancellation(entry.id);
    if (!mounted) return;
    if (result == null) {
      AppSnackBar.warning(tr('customer_my_requests.request_cancel_blocked'));
      _refresh();
      return;
    }
    // Hand the request off to the organiser over WhatsApp too. Prefer the phone
    // captured on the entry, falling back to the live tour's createdBy — the
    // same resolution _contactOrganiser uses.
    Tour? tour;
    if (Get.isRegistered<TourController>()) {
      tour = Get.find<TourController>().getTour(entry.tourId);
    }
    tour ??= _tourFromEntry(entry);
    final phone = (entry.organiserPhone != null &&
            entry.organiserPhone!.isNotEmpty)
        ? entry.organiserPhone
        : tour.createdBy;
    if (phone != null && phone.isNotEmpty) {
      await WhatsAppService().sendCancellationRequest(
        adminPhone: phone,
        tour: tour,
        customerName: entry.customerName,
        singleSofaCount: entry.singleSofa,
        doubleSofaCount: entry.doubleSofa,
        tripType: entry.tripType,
        note: entry.note,
        pickupLocation: entry.pickupLocationName,
        // Seat numbers are only shown to the customer once the tour is locked,
        // so only forward them when they're actually visible.
        seatIds: entry.seatsVisible
            ? entry.assignedSeats.map((s) => s.seatId).toList()
            : const [],
      );
    }
    if (!mounted) return;
    AppSnackBar.success(tr('customer_my_requests.request_cancel_done'));
    _refresh();
  }

  /// Call the organiser — the only way to cancel once a booking is confirmed.
  /// Prefers the phone captured on the entry, falling back to the live tour.
  Future<void> _contactOrganiser(CustomerRequestEntry entry) async {
    HapticFeedback.selectionClick();
    var phone = entry.organiserPhone;
    if ((phone == null || phone.isEmpty) && Get.isRegistered<TourController>()) {
      phone = Get.find<TourController>().getTour(entry.tourId)?.createdBy;
    }
    final digits = (phone ?? '').replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.isEmpty) {
      AppSnackBar.info(tr('customer_my_requests.contact_no_number'));
      return;
    }
    final uri = Uri(scheme: 'tel', path: digits);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      AppSnackBar.info(tr('customer_my_requests.contact_no_number'));
    }
  }
}

// ─── REFRESH ACTION (UgamAppBar trailing slot) ────────────────────────

/// Trailing refresh affordance for the shared [UgamAppBar]. Matches the
/// [UgamAppBarAction] circle styling, but swaps the glyph for a spinner while
/// a refresh is in flight (so the customer sees the pull is working).
class _RefreshAction extends StatelessWidget {
  final UgamColorSet c;
  final bool refreshing;
  final VoidCallback? onRefresh;

  const _RefreshAction({
    required this.c,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (!refreshing) {
      return UgamAppBarAction(
        icon: Icons.refresh_rounded,
        onTap: onRefresh ?? () {},
      );
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2),
      ),
    );
  }
}

// ─── REQUEST ROW (photo-anchored) ─────────────────────────────────────

class _RequestRow extends StatelessWidget {
  final CustomerRequestEntry entry;
  final bool isHandler;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onViewChart;
  final VoidCallback onAddAnother;
  final VoidCallback onCancel;
  final VoidCallback onRequestCancel;
  final VoidCallback onContact;

  /// Re-opens the advance UPI sheet for a booking sitting on a live hold.
  final Future<void> Function(CustomerRequestEntry entry) onPayAdvance;

  const _RequestRow({
    required this.entry,
    required this.isHandler,
    required this.onTap,
    required this.onEdit,
    required this.onViewChart,
    required this.onAddAnother,
    required this.onCancel,
    required this.onRequestCancel,
    required this.onContact,
    required this.onPayAdvance,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (statusLabel, statusTone) = _statusFor(entry);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Small backdrop + date pill.
                ClipRRect(
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                  child: SizedBox(
                    width: 76,
                    height: 88,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        UgamBusBackdrop(
                          seed: entry.tourId,
                          label: _routeInitials(
                            entry.tourFromCity,
                            entry.tourToCity,
                          ),
                        ),
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.cardElev,
                              borderRadius: BorderRadius.circular(UgamRadius.chip),
                            ),
                            child: Text(
                              _formatDate(entry.tourDepartureDate),
                              style: UgamText.tabular(
                                UgamText.micro.copyWith(
                                  color: c.ink,
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
                        entry.tourTitle,
                        style: UgamText.titleS.copyWith(
                          color: c.ink,
                          fontSize: 14.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.south_east_rounded,
                            size: 12,
                            color: c.ink2,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${entry.tourFromCity} → ${entry.tourToCity}',
                              style: UgamText.caption.copyWith(
                                color: c.ink2,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (entry.pickupLocationName != null &&
                          entry.pickupLocationName!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              Icons.place_rounded,
                              size: 12,
                              color: c.ink2,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${tr('pickup.reflect_label')}: ${entry.pickupLocationName!}',
                                style: UgamText.caption.copyWith(
                                  color: c.ink2,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: UgamSpacing.sm + 2),
                      Row(
                        children: [
                          UgamStatusDot(label: statusLabel, tone: statusTone),
                          const SizedBox(width: UgamSpacing.sm),
                          Flexible(
                            child: Text(
                              _seatsLabel(entry),
                              style: UgamText.caption.copyWith(
                                color: c.ink,
                                fontSize: 11.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Seat-hold recovery. Sits ABOVE the informational chips because a
            // ticking deadline with money attached outranks anything else on
            // the card. Renders nothing unless this booking is on a hold.
            if (entry.isHeld || entry.holdExpired) ...[
              const SizedBox(height: UgamSpacing.sm + 2),
              HoldCountdownStrip(
                entry: entry,
                onPay: () => onPayAdvance(entry),
                onRebook: onAddAnother,
              ),
            ],
            // Chip strip is informational only (edited / one-way / seats /
            // cancel-requested / note). Actions live in the single action bar
            // below, so we never stack more than two strips under the header.
            if (entry.wasEdited ||
                entry.tripType.isOneWay ||
                entry.hasSeatsAssigned ||
                entry.cancellationRequested ||
                (entry.note?.isNotEmpty ?? false)) ...[
              const SizedBox(height: UgamSpacing.sm + 2),
              _RowFooter(entry: entry, c: c),
            ],
            // ONE action strip: the single most relevant CTA inline (the card's
            // only accent element) plus a ⋮ overflow holding the rest. This
            // demotes Edit / Add-another / Cancel behind one affordance instead
            // of stacking a full-width section per action.
            const SizedBox(height: UgamSpacing.sm + 2),
            _ActionBar(
              entry: entry,
              c: c,
              isHandler: isHandler,
              onEdit: onEdit,
              onViewChart: onViewChart,
              onAddAnother: onAddAnother,
              onCancel: onCancel,
              onRequestCancel: onRequestCancel,
              onContact: onContact,
            ),
          ],
        ),
      ),
    );
  }

  (String, UgamStatusTone) _statusFor(CustomerRequestEntry e) {
    // Reveal "Seats assigned" (with numbers) only once the tour is locked.
    if (e.seatsVisible) {
      return (
        tr('customer_my_requests.chip_seats_assigned'),
        UgamStatusTone.good,
      );
    }
    // A cancelled/rejected ticket reads as cancelled regardless of stale seats.
    if (e.isCancelled) {
      return (tr('customer_my_requests.chip_cancelled'), UgamStatusTone.warm);
    }
    // Seats are HELD pending an advance. This is a live booking — the berths
    // are blocked on the chart for everyone else — so it must never fall
    // through to "Pending", and certainly not to "Cancelled", which is what it
    // used to do (there is no booking_requests row until the advance clears).
    if (e.isHeld) {
      return (tr('customer_my_requests.chip_held'), UgamStatusTone.warm);
    }
    // The hold lapsed unpaid. The seats went back on sale, so this is
    // re-bookable — which is why it is not folded into "Cancelled".
    if (e.holdExpired) {
      return (
        tr('customer_my_requests.chip_hold_expired'),
        UgamStatusTone.warm,
      );
    }
    // A booking reads "Confirmed" the moment it is organiser-confirmed OR holds
    // a provisionally-assigned seat — even before the tour is locked. The seat
    // NUMBER still stays hidden until lock (via seatsVisible above and the footer
    // chip), but the headline must not read "still being booked" for a rider who
    // already has a seat. `hasSeatsAssigned` is included so this pill AGREES with
    // the Confirmed tab's `_isConfirmedish` bucket — a seated rider was otherwise
    // mis-labelled "being finalized" while sitting inside the Confirmed tab.
    if (e.status == 'accepted' || e.isConfirmed || e.hasSeatsAssigned) {
      return (tr('customer_my_requests.chip_confirmed'), UgamStatusTone.good);
    }
    return (tr('customer_my_requests.chip_pending'), UgamStatusTone.warm);
  }

  String _seatsLabel(CustomerRequestEntry e) {
    final parts = <String>[];
    if (e.doubleSofa > 0) {
      parts.add(
        tr(
          'customer_my_requests.seats_double',
          namedArgs: {'count': e.doubleSofa.toString()},
        ),
      );
    }
    if (e.singleSofa > 0) {
      parts.add(
        tr(
          'customer_my_requests.seats_single',
          namedArgs: {'count': e.singleSofa.toString()},
        ),
      );
    }
    if (parts.isEmpty) {
      return tr(
        'customer_my_requests.seats_fallback',
        namedArgs: {'count': e.partySize.toString()},
      );
    }
    return parts.join(' + ');
  }

  static String _formatDate(DateTime d) {
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
  }
}

class _RowFooter extends StatelessWidget {
  final CustomerRequestEntry entry;
  final UgamColorSet c;

  const _RowFooter({
    required this.entry,
    required this.c,
  });

  /// Assigned seat numbers, truncated so a large group booking can't bloat the
  /// chip past one line. UgamReqChip has no maxLines of its own, so we cap the
  /// list at source and append "…" (with a leading count) once it overflows.
  static String _seatsChipLabel(CustomerRequestEntry e) {
    final ids = e.assignedSeats.map((s) => s.seatId).toList();
    const maxShown = 4;
    if (ids.length <= maxShown) return ids.join(', ');
    return tr(
      'customer_my_requests.seats_more',
      namedArgs: {
        'shown': ids.take(maxShown).join(', '),
        'count': ids.length.toString(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];

    if (entry.wasEdited) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_edited'),
          variant: UgamChipVariant.neutral,
        ),
      );
    }
    if (entry.cancellationRequested) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_cancel_requested'),
          variant: UgamChipVariant.warm,
        ),
      );
    }
    if (entry.tripType == TripType.outboundOnly) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_oneway_out'),
          variant: UgamChipVariant.warm,
        ),
      );
    } else if (entry.tripType == TripType.returnOnly) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_oneway_return'),
          variant: UgamChipVariant.warm,
        ),
      );
    }
    // Seat NUMBERS are revealed only after the tour locks. Before that, show a
    // neutral "number coming soon" chip so the customer knows their seat is
    // secured but never sees a provisional number that may still change.
    if (entry.seatsVisible) {
      widgets.add(
        UgamReqChip(
          label: tr(
            'customer_my_requests.chip_seats',
            namedArgs: {'seats': _seatsChipLabel(entry)},
          ),
          variant: UgamChipVariant.good,
        ),
      );
    } else if (entry.hasSeatsAssigned) {
      // Seated but the tour isn't locked yet, so the NUMBER stays hidden. The
      // seat is secured (headline reads "Confirmed") — tell the rider the number
      // is coming, never that it's "still being finalized".
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_seat_after_lock'),
          variant: UgamChipVariant.neutral,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Expanded(child: Wrap(spacing: 5, runSpacing: 5, children: widgets)),
          // Edit moved into the action bar below; the footer now only flags a
          // note the customer attached to the request.
          if (entry.note != null && entry.note!.isNotEmpty) ...[
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.sticky_note_2_outlined, size: 14, color: c.ink3),
          ],
        ],
      ),
    );
  }
}

/// One selectable action for the row's action bar / overflow menu.
class _RowAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Destructive (self-cancel) — tinted danger in the menu, and never chosen as
  /// the accent primary CTA (that stays reserved for a positive action).
  final bool destructive;

  const _RowAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });
}

/// Single action strip for a request card: the ONE most relevant CTA inline
/// (the card's only accent element) plus a ⋮ overflow that holds every other
/// action. Replaces the old stack of full-width Edit / Handler-chart / Cancel /
/// Add-another sections so no card ever shows more than two strips or more than
/// one accent affordance.
///
/// Primary CTA priority: Edit → View chart → Add another. The cancel family is
/// always demoted to the overflow (and never accent). The non-actionable
/// "cancellation requested — awaiting organiser" state is surfaced as a footer
/// chip, so no cancel action is offered once one has been raised.
class _ActionBar extends StatelessWidget {
  final CustomerRequestEntry entry;
  final UgamColorSet c;
  final bool isHandler;
  final VoidCallback onEdit;
  final VoidCallback onViewChart;
  final VoidCallback onAddAnother;
  final VoidCallback onCancel;
  final VoidCallback onRequestCancel;
  final VoidCallback onContact;

  const _ActionBar({
    required this.entry,
    required this.c,
    required this.isHandler,
    required this.onEdit,
    required this.onViewChart,
    required this.onAddAnother,
    required this.onCancel,
    required this.onRequestCancel,
    required this.onContact,
  });

  List<_RowAction> _actions() {
    final actions = <_RowAction>[];
    if (entry.canEdit) {
      actions.add(
        _RowAction(
          icon: Icons.edit_rounded,
          label: tr('customer_my_requests.edit_request_btn'),
          onTap: onEdit,
        ),
      );
    }
    if (isHandler) {
      actions.add(
        _RowAction(
          icon: Icons.grid_view_rounded,
          label: tr('customer_my_requests.view_full_chart'),
          onTap: onViewChart,
        ),
      );
    }
    // Always available — a second distinct request from the same number.
    actions.add(
      _RowAction(
        icon: Icons.add_rounded,
        label: tr('customer_my_requests.add_another'),
        onTap: onAddAnother,
      ),
    );
    // Cancel family — only when not already cancelled and no request pending
    // (the requested state shows as a footer chip instead).
    if (!entry.isCancelled && !entry.cancellationRequested) {
      if (entry.canCancel) {
        actions.add(
          _RowAction(
            icon: Icons.close_rounded,
            label: tr('customer_my_requests.cancel_action'),
            onTap: onCancel,
            destructive: true,
          ),
        );
      } else if (entry.canRequestCancel) {
        actions.add(
          _RowAction(
            icon: Icons.event_seat_outlined,
            label: tr('customer_my_requests.request_cancel_action'),
            onTap: onRequestCancel,
          ),
        );
      } else {
        actions.add(
          _RowAction(
            icon: Icons.call_rounded,
            label: tr('customer_my_requests.contact_to_cancel'),
            onTap: onContact,
          ),
        );
      }
    }
    return actions;
  }

  Future<void> _openOverflow(
    BuildContext context,
    List<_RowAction> actions,
  ) async {
    HapticFeedback.selectionClick();
    await UgamSheet.show<void>(
      context,
      title: tr('customer_my_requests.actions_title'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions)
            _OverflowMenuRow(
              action: a,
              c: c,
              onTap: () {
                Navigator.of(sheetCtx).maybePop();
                a.onTap();
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions();
    // addAnother is always present, so `actions` is never empty and the
    // primary is never the destructive cancel.
    final primary = actions.first;
    final overflow = actions.skip(1).toList();

    return Row(
      children: [
        Expanded(child: _PrimaryCta(action: primary, c: c)),
        if (overflow.isNotEmpty) ...[
          const SizedBox(width: UgamSpacing.sm),
          GestureDetector(
            onTap: () => _openOverflow(context, overflow),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm + 2),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.more_vert_rounded, size: 18, color: c.ink2),
            ),
          ),
        ],
      ],
    );
  }
}

/// The single accent CTA for a request card. Filled with the accent so it reads
/// as the row's one primary affordance.
class _PrimaryCta extends StatelessWidget {
  final _RowAction action;
  final UgamColorSet c;

  const _PrimaryCta({required this.action, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: action.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, size: 16, color: c.onAccent),
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: Text(
                action.label,
                style: UgamText.bodyStrong.copyWith(
                  color: c.onAccent,
                  fontSize: 12.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tappable row inside the ⋮ overflow sheet. Neutral, so it never competes
/// with the card's single accent CTA; destructive actions tint danger.
class _OverflowMenuRow extends StatelessWidget {
  final _RowAction action;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _OverflowMenuRow({
    required this.action,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tint = action.destructive ? c.danger : c.ink;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Icon(action.icon, size: 18, color: tint),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                action.label,
                style: UgamText.bodyStrong.copyWith(color: tint, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 110, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
      ],
    );
  }
}

/// A request is truly PENDING (and self-cancellable): still 'pending', not
/// organiser-confirmed, no seats yet. Mirrors [CustomerRequestEntry.canCancel].
/// A booking still waiting on someone to act.
///
/// `held` belongs here: the seats ARE blocked on the chart and the booking is
/// live, it is simply waiting on the customer's advance. Leaving it out stranded
/// held bookings in the All tab only — the one place a customer chasing an
/// unpaid booking is least likely to look.
bool _isPending(CustomerRequestEntry e) =>
    (e.status == 'pending' || e.isHeld) &&
    !e.hasSeatsAssigned &&
    !e.isConfirmed;

/// A request reads as CONFIRMED once the organiser confirms it, accepts it, or
/// seats are assigned.
bool _isConfirmedish(CustomerRequestEntry e) =>
    e.hasSeatsAssigned || e.status == 'accepted' || e.isConfirmed;

/// Route monogram (e.g. `"S→M"`) from the from/to city initials, for the
/// graphite UgamBusBackdrop tile. Matches the sibling customer screens.
String _routeInitials(String from, String to) {
  String first(String s) {
    final t = s.trim();
    return t.isEmpty ? '' : t.characters.first.toUpperCase();
  }

  final f = first(from);
  final t = first(to);
  if (f.isEmpty && t.isEmpty) return '';
  return '$f→$t';
}
