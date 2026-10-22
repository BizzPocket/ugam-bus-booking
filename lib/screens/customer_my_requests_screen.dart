import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/tour_controller.dart';
import '../components/content_block_view.dart';
import '../design/ugam.dart';
import '../design/components/ugam_tappable.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../routes/app_routes.dart';
import '../services/chart_advance_payment.dart';
import '../services/customer_requests_store.dart';
import '../widgets/hold_countdown_strip.dart';
import '../services/sync_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../widgets/customer_seat_layout_sheet.dart';
import 'customer_booking_request_screen.dart';
import 'handler/handler_shell.dart';
import 'customer_format.dart';

part 'customer_my_requests/request_row.dart';
part 'customer_my_requests/action_bar.dart';

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

  /// A cancel / cancellation-request RPC is in flight — ignore further taps.
  bool _cancelBusy = false;
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

  /// Finish paying a REQUEST-mode charge that was left unpaid at submit.
  ///
  /// The banded request has no seat hold and no deadline, so there is no
  /// countdown here — but the dead end is the same one the hold path already
  /// fixed: without a way back, a customer who dismissed the UPI sheet has a
  /// request the organiser will never treat as paid and no way to correct it.
  Future<void> _payCharge(CustomerRequestEntry entry) async {
    if (!entry.canPayCharge) return;
    final owed = entry.outstandingPaise;
    final recorded = await ChartAdvancePayment.collect(
      context: context,
      requestId: entry.id,
      payeeVpa: entry.collectVpa!,
      payeeName: (entry.collectPayeeName?.trim().isNotEmpty ?? false)
          ? entry.collectPayeeName!
          : entry.tourTitle,
      amountPaise: owed,
      note: '${entry.tourFromCity}-${entry.tourToCity} · ${entry.customerName}',
    );
    if (recorded) {
      await CustomerRequestsStore().upsert(
        entry.copyWith(claimedPaise: entry.claimedPaise + owed),
      );
    }
    await _refresh();
  }

  Future<void> _openEdit(CustomerRequestEntry entry) async {
    final tour = _resolveTour(entry);
    await Get.to<void>(
      () => CustomerBookingRequestScreen(tour: tour, existing: entry),
    );
    _refresh();
  }

  /// Opens a BLANK create form for [entry]'s tour, so a customer can lodge a
  /// SECOND distinct request from the same number (a different traveller / seat
  /// mix). `existing` is null → the form is in create mode and inserts a fresh
  /// passenger + request (migration 030 lets one phone hold many per tour).
  Future<void> _openAddAnother(CustomerRequestEntry entry) async {
    HapticFeedback.selectionClick();
    final tour = _resolveTour(entry);
    await Get.to<void>(
      () => CustomerBookingRequestScreen(tour: tour),
    );
    _refresh();
  }

  /// PAGE-LEVEL "add another request" — the bottom-anchored CTA.
  ///
  /// Lodging a second request is a page action, not a property of whichever
  /// card happened to render it, so it lives on the page and resolves its own
  /// trip: one live trip means no question to ask, several means the customer
  /// picks. That ambiguity is exactly why the button used to sit inside a card
  /// — the card silently supplied the answer, at the cost of scoping a page
  /// action to one list item.
  Future<void> _addAnotherFromPage() async {
    final byTour = <String, CustomerRequestEntry>{};
    for (final e in _live) {
      byTour.putIfAbsent(e.tourId, () => e);
    }
    final tours = byTour.values.toList();
    if (tours.isEmpty) return;
    if (tours.length == 1) {
      await _openAddAnother(tours.first);
      return;
    }
    final picked = await UgamSheet.show<CustomerRequestEntry>(
      context,
      title: tr('customer_my_requests.add_another_pick_title'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in tours)
            _TourPickRow(
              entry: e,
              onTap: () => Navigator.of(sheetCtx).pop(e),
            ),
        ],
      ),
    );
    if (!mounted || picked == null) return;
    await _openAddAnother(picked);
  }

  /// The way OUT of the zero-requests empty state: back to the trip list, which
  /// is the only place a first request can be created from. Pops when this
  /// screen was pushed over it (the usual path) and routes there outright when
  /// it was opened cold from a notification or a content block.
  void _browseTours() {
    HapticFeedback.selectionClick();
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      Get.offAllNamed(AppRoutes.customerHome);
    }
  }

  /// The live tour when the controller has it, else one rebuilt from the
  /// ticket's own snapshot (customers are anon and may hold no tour list).
  Tour _resolveTour(CustomerRequestEntry entry) {
    Tour? tour;
    if (Get.isRegistered<TourController>()) {
      tour = Get.find<TourController>().getTour(entry.tourId);
    }
    return tour ?? _tourFromEntry(entry);
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
    return switch (_filter) {
      _StatusFilter.pending => live.where(_isPending).toList(),
      _StatusFilter.confirmed => live.where(_isConfirmedish).toList(),
      // An expired hold sits here rather than under Pending — it is no longer
      // live — but it keeps its own label and a "Book again" action, because
      // unlike a cancellation it can simply be redone.
      _StatusFilter.cancelled =>
        live.where((e) => e.isCancelled || e.holdExpired).toList(),
      _StatusFilter.all => live,
    };
  }

  /// The quiet "what happens next" panel is tail content for a SHORT list — the
  /// case where a single card left roughly two thirds of the page as white
  /// void. Past two or three cards the list composes itself and the panel would
  /// just be filler, and under the Cancelled tab it would be describing a
  /// journey that is no longer happening.
  bool get _showTailPanel =>
      _visible.isNotEmpty &&
      _visible.length <= 2 &&
      _filter != _StatusFilter.cancelled;

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
                            // V-07: an empty state that only states the problem
                            // strands the customer. The one thing they can do
                            // from zero requests is go and pick a trip, so the
                            // state carries that action itself.
                            cta: UgamCTA(
                              label: tr('customer_my_requests.empty_cta'),
                              leadingIcon: Icons.explore_outlined,
                              onPressed: _browseTours,
                            ),
                          ),
                        ),
                        // Was `dockClearance` (140) — clearance for a floating
                        // dock this pushed screen does not have. With the slot
                        // empty (its normal state) that was 140px of phantom
                        // gap shoving the empty state off centre and opening a
                        // void under it. SafeArea gives the real bottom inset.
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                              UgamSpacing.gutter,
                              0,
                              UgamSpacing.gutter,
                              UgamSpacing.lg,
                            ),
                            child: const ContentSlot(
                              ContentSlots.customerMyRequestsEmpty,
                            ),
                          ),
                        ),
                      ],
                    )
                  : _visible.isEmpty
                  ? UgamEmpty(
                      icon: Icons.filter_alt_off_rounded,
                      title: tr('customer_my_requests.empty_filter_title'),
                      body: tr('customer_my_requests.empty_filter_body'),
                      // Tonal, not solid: the page's one solid control is the
                      // bottom CTA, which is on screen behind this.
                      cta: UgamButton(
                        label: tr('customer_my_requests.empty_filter_cta'),
                        icon: Icons.filter_alt_off_rounded,
                        kind: UgamButtonKind.tonal,
                        onPressed: () =>
                            setState(() => _filter = _StatusFilter.all),
                      ),
                    )
                  : RefreshIndicator(
                      // Chrome, not ownership — the pull spinner is neutral
                      // ink2 in every screen, so it never changes hue between
                      // tabs. It matters most here: the accent is already
                      // marking the customer's OWN requests below it.
                      color: c.ink2,
                      onRefresh: _refresh,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        // The old bottom pad cleared the floating dock (140).
                        // This screen is pushed — there is no dock — and the
                        // page CTA below now owns the bottom of the layout, so
                        // the list stops scrolling into a void of its own.
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          UgamSpacing.sm,
                          UgamSpacing.gutter,
                          UgamSpacing.lg,
                        ),
                        // +1 for the slot at the head of the list. It renders
                        // zero-height when nothing is published, so the list
                        // is unchanged by default. +1 more for the tail panel
                        // on a short list (see [_showTailPanel]).
                        itemCount:
                            _visible.length + 1 + (_showTailPanel ? 1 : 0),
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UgamSpacing.md),
                        itemBuilder: (_, index) {
                          if (index == 0) {
                            return const ContentSlot(
                              ContentSlots.customerMyRequestsTop,
                            );
                          }
                          final i = index - 1;
                          final visible = _visible;
                          if (i >= visible.length) return const _NextSteps();
                          final entry = visible[i];
                          return _RequestRow(
                            entry: entry,
                            isHandler: _handlerStatus[entry.id] ?? false,
                            onTap: () => _onRowTap(entry),
                            onEdit: () => _openEdit(entry),
                            onViewChart: () => _openFullChart(entry),
                            onRebook: () => _openAddAnother(entry),
                            onPayAdvance: _payAdvance,
                            onPayCharge: _payCharge,
                            onCancel: () => _cancel(entry),
                            onRequestCancel: () => _requestCancel(entry),
                            onContact: () => _contactOrganiser(entry),
                          );
                        },
                      ),
                    ),
            ),
            // PAGE-LEVEL action, anchored. It used to render inside a request
            // card, which scoped "add ANOTHER request" to whichever booking the
            // list happened to draw it on; down here its scope is the page and
            // it also gives the layout a bottom edge, so a one-card list no
            // longer reads as a card floating in white space.
            if (!_loading && live.isNotEmpty)
              UgamStickyCTA(
                child: UgamCTA(
                  label: tr('customer_my_requests.add_another'),
                  leadingIcon: Icons.add_rounded,
                  onPressed: _addAnotherFromPage,
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
      () => HandlerShell(requestId: entry.id),
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
    if (ok != true || _cancelBusy) return;
    // Busy guard: on a slow link the first tap's RPC is still in flight, and a
    // second one lands on an already-cancelled row → "blocked".
    _cancelBusy = true;
    final CustomerRequestEntry? result;
    try {
      result = await _store.cancel(entry.id);
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('errors.no_connection_try_again'));
      return;
    } finally {
      _cancelBusy = false;
    }
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
    if (ok != true || _cancelBusy) return;
    _cancelBusy = true;
    final CustomerRequestEntry? result;
    try {
      result = await _store.requestCancellation(entry.id);
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('errors.no_connection_try_again'));
      return;
    } finally {
      _cancelBusy = false;
    }
    if (!mounted) return;
    if (result == null) {
      AppSnackBar.warning(tr('customer_my_requests.request_cancel_blocked'));
      _refresh();
      return;
    }
    // Hand the request off to the organiser over WhatsApp too. Prefer the phone
    // captured on the entry, falling back to the live tour's createdBy — the
    // same resolution _contactOrganiser uses.
    final tour = _resolveTour(entry);
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

/// A booking still waiting on someone to act: still 'pending' (or held), not
/// organiser-confirmed, no seats yet.
///
/// This is the Pending FILTER, not the self-cancel gate — it deliberately no
/// longer mirrors [CustomerRequestEntry.canCancel], because it also counts
/// held bookings.
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
