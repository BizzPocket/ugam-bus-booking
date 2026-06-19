import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../controllers/user_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../routes/app_routes.dart';
import '../services/whatsapp_outbound.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/tour_capacity.dart';
import '../widgets/booking_capture_form.dart';
import '../widgets/edit_request_sheet.dart';
import '../widgets/group_picker.dart';
import 'add_bus_screen.dart';

/// Requests tab — passenger management workspace.
///
/// Layout top → bottom:
///   [Title + circle search + groups + circle "+"]
///   [Collapsible search bar]
///   [Tour selector pills (active solid accent)]
///   [Collapsible capacity banner (_CapacityBanner)]
///   [Four status tabs (UgamTabPills): New / Waitlist / Confirmed / Assigned]
///   [Passenger list — dense _RequestCard: name + phone/time + one chip Wrap + action row]
///   [Sticky bottom CTA → seat assignment]
///
/// Selection mode is entered via long-press. While active the bottom CTA
/// is replaced by a bulk-action bar (Waitlist / Send WA / Cancel).
class RequestsScreen extends StatefulWidget {
  /// When set, the screen opens with this tour pre-selected. Used by deep
  /// links such as the Fill-bus cockpit's "Edit requests" entry. Null keeps
  /// the default first-tour selection used by the bottom-nav tab.
  final String? initialTourId;

  const RequestsScreen({super.key, this.initialTourId});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

enum _RequestFilter { newRequests, waitlist, confirmed, assigned }

class _RequestsScreenState extends State<RequestsScreen> {
  final tourCtrl = Get.find<TourController>();
  final _searchCtrl = TextEditingController();

  int _selectedTourIndex = 0;
  _RequestFilter _filter = _RequestFilter.newRequests;
  bool _searchVisible = false;
  String _query = '';

  // ── Bulk selection state ─────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  // Bottom list clearance so the last card never hides under the floating
  // bars. Token-derived (8pt grid) — selection bar vs sticky CTA.
  static const double _listBottomPadSelection =
      UgamSpacing.huge3 + UgamSpacing.huge2 + UgamSpacing.lg; // 56+40+16 = 112
  static const double _listBottomPadNormal = UgamSpacing.huge2 * 4; // 40*4 = 160

  @override
  void initState() {
    super.initState();
    // Honour a deep-link target tour, falling back to the first tour when the
    // id is unknown (e.g. the tour was completed/removed since the link).
    final id = widget.initialTourId;
    if (id != null) {
      final idx = tourCtrl.activeTours.indexWhere((t) => t.id == id);
      if (idx >= 0) _selectedTourIndex = idx;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    HapticFeedback.selectionClick();
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  void _openAddRequest(Tour tour) {
    // Once the tour is locked the allocation is final — admins/handlers can no
    // longer add a new request. Tell them why rather than opening a form whose
    // save the controller would silently refuse.
    if (!tour.acceptsBookings) {
      AppSnackBar.error(tr('errors.bookings_closed'));
      return;
    }
    UgamSheet.show(
      context,
      title: tr('requests.sheet.title'),
      builder: (_) => _AddRequestForm(tour: tour),
    );
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _enterSelection(String id) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  Future<void> _bulkWaitlist(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      await tourCtrl.setWaitlisted(tour.id, id, true);
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.snack.bulk_waitlisted', namedArgs: {'n': '${ids.length}'}),
    );
    _exitSelection();
  }

  /// Confirm every selected New/waitlisted request in one tap — mirrors the
  /// per-card Confirm exactly: clears any waitlist flag AND auto-sends each
  /// passenger the Cloud `seat_allocation` confirmation template (no manual
  /// WhatsApp tap). Already-assigned passengers are ignored (they're past the
  /// confirm stage).
  Future<void> _bulkConfirm(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    var confirmed = 0;
    var sent = 0;
    var failed = 0;
    for (final id in ids) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null || p.isFullyAssigned) continue;
      await tourCtrl.setConfirmed(tour.id, id, true);
      confirmed++;
      // Same send as the per-card _confirm(): the dedicated confirm template,
      // fired automatically so confirming IS messaging.
      try {
        final result = await WhatsAppOutbound().sendConfirmed(
          tour: tour,
          passenger: p,
        );
        if (result.anySent) {
          sent++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    if (failed == 0) {
      AppSnackBar.success(
        tr(
          'requests.bulk.confirmed_sent',
          namedArgs: {'n': '$confirmed', 'sent': '$sent'},
        ),
      );
    } else {
      AppSnackBar.warning(
        tr(
          'requests.bulk.confirmed_sent_partial',
          namedArgs: {'n': '$confirmed', 'sent': '$sent', 'failed': '$failed'},
        ),
      );
    }
    _exitSelection();
  }

  Future<void> _bulkSendWA(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    int opened = 0;
    for (final id in ids) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null) continue;
      final ok = await WhatsAppService().sendAck(passenger: p, tour: tour);
      if (ok) opened++;
    }
    if (!mounted) return;
    if (opened > 0) {
      AppSnackBar.success(
        tr('requests.snack.bulk_wa_opened', namedArgs: {'n': '$opened'}),
      );
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
    _exitSelection();
  }

  /// Promote every selected passenger off the waitlist back into New. Only
  /// offered while the Waitlist filter is active (see [_BulkActionBar]).
  Future<void> _bulkPromote(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      await tourCtrl.setWaitlisted(tour.id, id, false);
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.bulk.promoted', namedArgs: {'n': '${ids.length}'}),
    );
    _exitSelection();
  }

  /// Decline (delete) every selected request after one confirm. Destructive,
  /// so it goes through [UgamDialog.confirm] like the per-card decline.
  Future<void> _bulkDecline(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    if (ids.isEmpty) return;
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.bulk.decline_title'),
      message: tr(
        'requests.bulk.decline_body',
        namedArgs: {'n': '${ids.length}'},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.bulk.decline_confirm'),
      destructive: true,
      confirmIcon: Icons.close_rounded,
    );
    if (!confirmed) return;
    for (final id in ids) {
      await tourCtrl.removePassenger(tour.id, id);
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.bulk.declined', namedArgs: {'n': '${ids.length}'}),
    );
    _exitSelection();
  }

  /// Default ordering: newest request first. The sort control was removed —
  /// agents triage top-down, and a stable newest-first order is the one that
  /// matches how requests arrive.
  List<Passenger> _orderNewestFirst(List<Passenger> list) {
    final out = List<Passenger>.from(list)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final activeTours = tourCtrl.activeTours;
          if (_selectedTourIndex >= activeTours.length) {
            _selectedTourIndex = 0;
          }
          final Tour? selectedTour = activeTours.isEmpty
              ? null
              : activeTours[_selectedTourIndex];

          return Stack(
            children: [
              Column(
                children: [
                  _TopBar(
                    c: c,
                    // Selected tour's route shown as the eyebrow above the
                    // title (e.g. "Surat → Ambaji").
                    eyebrow: selectedTour == null
                        ? null
                        : '${selectedTour.fromCity} → ${selectedTour.toCity}',
                    // Pushed/scoped mode (opened from a tour workspace with a
                    // tour pre-selected) strands the user with no dock nav — so
                    // render a back affordance. The shell tab (initialTourId
                    // null, nothing to pop) keeps the plain title.
                    showBack: widget.initialTourId != null &&
                        Navigator.canPop(context),
                    onBack: Get.back,
                    searchActive: _searchVisible,
                    onToggleSearch: _toggleSearch,
                    onAdd: selectedTour == null
                        ? null
                        : () => _openAddRequest(selectedTour),
                    onGroups: selectedTour == null
                        ? null
                        : () => Get.toNamed(
                              AppRoutes.tourGroups,
                              arguments: {'tourId': selectedTour.id},
                            ),
                    selectionMode: _selectionMode,
                    selectedCount: _selectedIds.length,
                    onExitSelection: _exitSelection,
                  ),
                  AnimatedSize(
                    duration: UgamMotion.tab,
                    curve: UgamMotion.easeOut,
                    child: _searchVisible
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(
                              UgamSpacing.gutter,
                              0,
                              UgamSpacing.gutter,
                              UgamSpacing.md,
                            ),
                            child: UgamSearchField(
                              hint: tr('requests.search_hint'),
                              controller: _searchCtrl,
                              autofocus: true,
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                              onClear: () => setState(() => _query = ''),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: activeTours.isEmpty
                        ? UgamEmpty(
                            icon: Icons.chat_bubble_outline_rounded,
                            title: tr('requests.empty_no_tours.title'),
                            body: tr('requests.empty_no_tours.body'),
                          )
                        : _buildBody(activeTours, selectedTour!, c),
                  ),
                ],
              ),
              if (selectedTour != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _selectionMode
                      ? _BulkActionBar(
                          c: c,
                          count: _selectedIds.length,
                          // In the Waitlist tab the move-target is "promote
                          // back to New"; everywhere else it's "to waitlist".
                          isWaitlistTab:
                              _filter == _RequestFilter.waitlist,
                          // Confirm only makes sense before seats are locked —
                          // hide it on the Assigned tab where every selection is
                          // already past the confirm stage.
                          canConfirm:
                              _filter != _RequestFilter.assigned,
                          onWaitlist: () => _bulkWaitlist(selectedTour),
                          onPromote: () => _bulkPromote(selectedTour),
                          onConfirm: () => _bulkConfirm(selectedTour),
                          onSendWA: () => _bulkSendWA(selectedTour),
                          onDecline: () => _bulkDecline(selectedTour),
                          onCancel: _exitSelection,
                        )
                      : _AssignmentCTA(tour: selectedTour, c: c),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildBody(List<Tour> activeTours, Tour selectedTour, UgamColorSet c) {
    // Exclude passengers whose leg is finished (cleared by "Complete GO leg")
    // — they keep their record but drop off the active roster.
    final allPassengers =
        selectedTour.passengers.where((p) => !p.journeyDone).toList();

    final newList = allPassengers
        .where((p) => !p.isWaitlisted && !p.isConfirmed && !p.isFullyAssigned)
        .toList();
    final waitlistList = allPassengers
        .where((p) => p.isWaitlisted && !p.isFullyAssigned)
        .toList();
    final confirmedList = allPassengers
        .where((p) => p.isConfirmed && !p.isWaitlisted && !p.isFullyAssigned)
        .toList();
    final assignedList = allPassengers.where((p) => p.isFullyAssigned).toList();

    final base = switch (_filter) {
      _RequestFilter.newRequests => newList,
      _RequestFilter.waitlist => waitlistList,
      _RequestFilter.confirmed => confirmedList,
      _RequestFilter.assigned => assignedList,
    };

    final q = _query.toLowerCase();
    final filtered = q.isEmpty
        ? base
        : base
              .where(
                (p) =>
                    p.displayName.toLowerCase().contains(q) ||
                    p.phone.toLowerCase().contains(q),
              )
              .toList();
    final passengers = _orderNewestFirst(filtered);

    return Column(
      children: [
        if (activeTours.length > 1) ...[
          const SizedBox(height: UgamSpacing.xs),
          UgamSelectorPills(
            currentIndex: _selectedTourIndex,
            onChanged: (i) => setState(() {
              _selectedTourIndex = i;
              _exitSelection();
            }),
            items: [
              for (final tour in activeTours)
                UgamSelectorItem(label: tour.title),
            ],
          ),
        ],
        const SizedBox(height: UgamSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: _CapacityBanner(c: c, tour: selectedTour),
        ),
        const SizedBox(height: UgamSpacing.md),
        // Status filter pills (with counts). The sort control was removed — the
        // list is ordered newest-first and the four tabs now use the full width.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: UgamTabPills(
            currentIndex: _filter.index,
            onChanged: (i) =>
                setState(() => _filter = _RequestFilter.values[i]),
            items: [
              UgamTabItem(
                label: tr('requests.filter.new'),
                count: newList.length,
              ),
              UgamTabItem(
                label: tr('requests.filter.waitlist'),
                count: waitlistList.length,
              ),
              UgamTabItem(
                label: tr('requests.filter.confirmed'),
                count: confirmedList.length,
              ),
              UgamTabItem(
                label: tr('requests.filter.assigned'),
                count: assignedList.length,
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.lg),
        Expanded(
          child: RefreshIndicator(
            color: c.accent,
            onRefresh: tourCtrl.refreshTours,
            child: passengers.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.45,
                        child: UgamEmpty(
                          icon: _query.isNotEmpty
                              ? Icons.search_off_rounded
                              : switch (_filter) {
                                  _RequestFilter.newRequests =>
                                    Icons.people_outline_rounded,
                                  _RequestFilter.waitlist =>
                                    Icons.hourglass_empty_rounded,
                                  _RequestFilter.confirmed =>
                                    Icons.verified_rounded,
                                  _RequestFilter.assigned =>
                                    Icons.check_circle_outline_rounded,
                                },
                          title: _query.isNotEmpty
                              ? tr('requests.empty_search.title')
                              : switch (_filter) {
                                  _RequestFilter.newRequests => tr(
                                    'requests.empty_new.title',
                                  ),
                                  _RequestFilter.waitlist => tr(
                                    'requests.empty_waitlist.title',
                                  ),
                                  _RequestFilter.confirmed => tr(
                                    'requests.empty_confirmed.title',
                                  ),
                                  _RequestFilter.assigned => tr(
                                    'requests.empty_assigned.title',
                                  ),
                                },
                          body: _query.isNotEmpty
                              ? tr(
                                  'requests.empty_search.body',
                                  namedArgs: {'query': _query},
                                )
                              : switch (_filter) {
                                  _RequestFilter.newRequests => tr(
                                    'requests.empty_new.body',
                                  ),
                                  _RequestFilter.waitlist => tr(
                                    'requests.empty_waitlist.body',
                                  ),
                                  _RequestFilter.confirmed => tr(
                                    'requests.empty_confirmed.body',
                                  ),
                                  _RequestFilter.assigned => tr(
                                    'requests.empty_assigned.body',
                                  ),
                                },
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      0,
                      UgamSpacing.gutter,
                      _selectionMode
                          ? _listBottomPadSelection
                          : _listBottomPadNormal,
                    ),
                    itemCount: passengers.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.sm + 2),
                    itemBuilder: (_, i) {
                      final p = passengers[i];
                      final selected = _selectedIds.contains(p.id);
                      return _RequestCard(
                        passenger: p,
                        tour: selectedTour,
                        c: c,
                        selectionMode: _selectionMode,
                        selected: selected,
                        onLongPress: () => _enterSelection(p.id),
                        onSelectTap: () => _toggleSelect(p.id),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// ─── Top bar ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final bool showBack;
  final VoidCallback onBack;
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback? onAdd;
  final VoidCallback? onGroups;
  final bool selectionMode;
  final int selectedCount;
  final VoidCallback onExitSelection;

  /// Optional small champagne label above the title — the selected tour's
  /// route (e.g. "Surat → Ambaji"), so the agent always sees which tour these
  /// requests belong to. Null when no tour is selected.
  final String? eyebrow;

  const _TopBar({
    required this.c,
    this.showBack = false,
    required this.onBack,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onAdd,
    required this.onGroups,
    required this.selectionMode,
    required this.selectedCount,
    required this.onExitSelection,
    this.eyebrow,
  });

  @override
  Widget build(BuildContext context) {
    // Selection mode: the shared app bar with a close-X "back" and the
    // selected-count as the title. Keeps the chrome identical to the rest of
    // the app instead of a hand-rolled row.
    if (selectionMode) {
      return UgamAppBar(
        title: tr('requests.selected_count', namedArgs: {'n': '$selectedCount'}),
        showBack: true,
        onBack: onExitSelection,
      );
    }

    // Normal mode. Add is now a NEUTRAL chrome action (champagne is rationed to
    // the sticky Seats CTA + bulk-Confirm); a null onTap renders it properly
    // disabled via UgamIconButton's muted token, not an accent-at-40% hack.
    return UgamAppBar(
      title: tr('requests.title'),
      // Selected tour's route as the eyebrow, so the agent always sees which
      // tour these requests belong to.
      eyebrow: eyebrow,
      // Pushed/scoped mode shows the back affordance; the shell tab hides it.
      showBack: showBack,
      onBack: onBack,
      actions: [
        UgamAppBarAction(
          icon: searchActive ? Icons.close_rounded : Icons.search_rounded,
          onTap: onToggleSearch,
          active: searchActive,
        ),
        UgamIconButton(
          icon: Icons.groups_rounded,
          onTap: onGroups,
          size: 42,
          semanticLabel: tr('tour_detail.tool_groups'),
        ),
        UgamIconButton(
          icon: Icons.person_add_alt_rounded,
          onTap: onAdd,
          size: 42,
          semanticLabel: tr('requests.sheet.title'),
        ),
      ],
    );
  }
}

// ─── Capacity banner ──────────────────────────────────────────────────

/// At-a-glance demand-vs-capacity strip: how many berths the ACTIVE (non-
/// waitlisted) requests need, the bus capacity, and whether there's room or
/// an overflow. This is the screen where the agent decides who to waitlist,
/// so the capacity pressure belongs right here. Counted in berths — a Double
/// Sofa request line costs 2 berths — matching [Tour.totalBusSeats].
class _CapacityBanner extends StatefulWidget {
  final UgamColorSet c;
  final Tour tour;
  const _CapacityBanner({required this.c, required this.tour});

  @override
  State<_CapacityBanner> createState() => _CapacityBannerState();
}

class _CapacityBannerState extends State<_CapacityBanner> {
  // Collapsed by default so the passenger cards surface sooner — the agent
  // taps to reveal the full demand/seats/free breakdown only when triaging.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final tour = widget.tour;
    final capacity = tour.totalBusSeats;
    // Trip-aware seat-LOAD: a round-trip rider weighs a full seat, a one-way
    // rider half. The headline "requested" figure uses this weight so the 0.5
    // a one-way booking adds is honest and visible (e.g. "1.5"), while the
    // free/over maths below stay on the PHYSICAL leg demand so the busier leg
    // is never overbooked.
    var loadDemand = 0.0;
    for (final p in tour.passengers) {
      if (p.isWaitlisted || p.journeyDone) continue;
      loadDemand += p.seatLoad;
    }
    final noBus = tour.buses.isEmpty;
    // Engine-truth occupancy (the single source) — see [computeTourCapacity].
    // The old `capacity − demand` lied "FULL" while a seat sat physically empty,
    // because it counted every non-waitlisted rider as seatable even when the
    // engine could not place them (stranger-share double, leg-blocked single,
    // seater vs sofa). Reading the deterministic plan makes `free` mean GENUINELY
    // empty, and the riders the engine can't auto-seat surface as
    // "needs your decision" instead of hiding inside a phantom full bus.
    final cap = computeTourCapacity(tour);
    final occupied = cap.occupied;
    final free = cap.free;
    final needsDecision = cap.needsDecision;
    // Per-leg one-way surplus, derived from the SAME plan as [free] (never from
    // raw demand, which counted the unseatable needsDecision rider and inverted
    // the reclaim direction). At most one is non-zero per bus, but across buses
    // both can be — so both are surfaced.
    final goOnlyFree = cap.goOnlyFree;
    final retOnlyFree = cap.retOnlyFree;
    // GENUINELY-empty berths per seat type, read from the SAME engine plan as
    // [free] (see [TourCapacity.freeByType]). The old `capacity − requested
    // demand` math lived here and could go NEGATIVE (e.g. "Single Sofa −2") when
    // riders asked for more of a type than exists — disagreeing with the engine
    // headline. Over-demand now surfaces as [needsDecision], never a phantom
    // negative. Only types the buses actually have are shown.
    final typeFree = <(String, int)>[
      for (final st in const [
        SeatType.singleSofa,
        SeatType.doubleSofa,
        SeatType.seater,
      ])
        if ((cap.capByType[st] ?? 0) > 0)
          (st.displayName, cap.freeByType[st] ?? 0),
    ];

    final (Color tone, Color fill, IconData icon, String statusValue,
        String statusLabel) = noBus
        ? (c.warm, c.warmFill, Icons.directions_bus_outlined, '—',
            tr('requests.capacity.no_buses'))
        : free > 0
        ? (c.good, c.goodFill, Icons.event_seat_outlined, '$free',
            tr('requests.capacity.free'))
        : (c.ink3, c.card, Icons.event_seat_outlined, '0',
            tr('requests.capacity.free'));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _expanded = !_expanded);
      },
      child: AnimatedSize(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        alignment: Alignment.topCenter,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(UgamRadius.stat),
            border: Border.all(color: tone.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Collapsed glance line: status icon + the headline numbers + a
              // chevron. The bus-fill bar fills the middle so demand-vs-capacity
              // still reads at a glance without expanding.
              Row(
                children: [
                  Icon(icon, size: 18, color: tone),
                  const SizedBox(width: UgamSpacing.sm),
                  Text(
                    noBus
                        ? _fmtSeatLoad(loadDemand)
                        : '$occupied/$capacity',
                    style: UgamText.tabular(
                      UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  if (!noBus)
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(UgamRadius.chip),
                        child: LinearProgressIndicator(
                          value: capacity <= 0
                              ? 0
                              : (occupied / capacity).clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: c.border,
                          valueColor: AlwaysStoppedAnimation<Color>(tone),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: UgamSpacing.sm),
                  Text(
                    '$statusValue ${statusLabel.toUpperCase()}',
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(color: tone),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: c.ink3,
                  ),
                ],
              ),
              // Honest "blocked" line: riders the engine can't auto-seat under
              // the hard rules (stranger-share double, leg conflict, wrong seat
              // type). Shown right under the glance line so an empty-but-blocked
              // seat is never mistaken for a miscalculated "full".
              if (!noBus && needsDecision > 0) ...[
                const SizedBox(height: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Get.toNamed(
                      AppRoutes.seatingExceptions,
                      arguments: {'tourId': tour.id},
                    );
                  },
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 14, color: c.warm),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          tr('requests.capacity.needs_decision',
                              namedArgs: {'n': '$needsDecision'}),
                          style: UgamText.micro.copyWith(color: c.warm),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 14, color: c.warm),
                    ],
                  ),
                ),
              ],
              // Expanded detail: the full three-segment breakdown + per-leg
              // reclaim row. Hidden by default so cards surface sooner.
              if (_expanded) ...[
                const SizedBox(height: UgamSpacing.sm + 2),
                Row(
                  children: [
                    _CapSeg(
                      c: c,
                      value: _fmtSeatLoad(loadDemand),
                      label: tr('requests.capacity.requested'),
                      color: c.ink,
                    ),
                    _CapDivider(c: c),
                    _CapSeg(
                      c: c,
                      value: noBus ? '—' : '$capacity',
                      label: tr('requests.capacity.seats'),
                      color: c.ink,
                    ),
                    _CapDivider(c: c),
                    _CapSeg(
                      c: c,
                      value: statusValue,
                      label: statusLabel,
                      color: tone,
                    ),
                  ],
                ),
                // Per-leg breakdown — only meaningful when one-way riders make
                // the two legs differ. Shows the engine-PLACED load per leg and
                // the opposite-leg seats still open, so the agent can fill
                // "going-out-full, coming-back-empty" seats. All plan-derived, so
                // the GO/RET counts and the reclaim direction agree with the
                // chart instead of the old raw-demand reclaim that could invert.
                if (!noBus && (goOnlyFree > 0 || retOnlyFree > 0)) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        tr('requests.capacity.legs', namedArgs: {
                          'go': '${cap.goOccupied}',
                          'ret': '${cap.retOccupied}',
                        }),
                        style: UgamText.micro.copyWith(color: c.ink2),
                      ),
                      const Spacer(),
                      Text(
                        [
                          if (goOnlyFree > 0)
                            tr('requests.capacity.reclaim_go',
                                namedArgs: {'n': '$goOnlyFree'}),
                          if (retOnlyFree > 0)
                            tr('requests.capacity.reclaim_ret',
                                namedArgs: {'n': '$retOnlyFree'}),
                        ].join(' · '),
                        style: UgamText.micro.copyWith(color: c.good),
                      ),
                    ],
                  ),
                ],
                // Free-by-type breakdown — which KIND of seat is still open, so
                // the agent can match a Double Sofa request to a free double
                // (not just any empty berth). Only shown when the bus mixes seat
                // types; a single-type bus already says it in the headline free.
                if (!noBus && typeFree.length >= 2) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        tr('requests.capacity.free_by_type'),
                        style: UgamText.micro.copyWith(color: c.ink3),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          alignment: WrapAlignment.end,
                          children: [
                            for (final (label, free) in typeFree)
                              _TypeFreePill(c: c, label: label, free: free),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One "Single Sofa · 2" free-seat pill in the capacity banner's by-type row.
/// The count is tinted green when seats remain, red when that type is
/// over-subscribed, muted when exactly full.
class _TypeFreePill extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  final int free;
  const _TypeFreePill({
    required this.c,
    required this.label,
    required this.free,
  });

  @override
  Widget build(BuildContext context) {
    final tone = free > 0 ? c.good : (free < 0 ? c.danger : c.ink3);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: UgamText.micro.copyWith(color: c.ink2, fontSize: 10),
          ),
          const SizedBox(width: 5),
          Text(
            '$free',
            style: UgamText.tabular(
              UgamText.micro.copyWith(
                color: tone,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapSeg extends StatelessWidget {
  final UgamColorSet c;
  final String value;
  final String label;
  final Color color;
  const _CapSeg({
    required this.c,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: UgamText.tabular(
              UgamText.numLg.copyWith(color: color, fontSize: 18),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UgamText.micro.copyWith(color: c.ink3, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _CapDivider extends StatelessWidget {
  final UgamColorSet c;
  const _CapDivider({required this.c});
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
        color: c.border,
      );
}


// ─── Assignment CTA ───────────────────────────────────────────────────

class _AssignmentCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _AssignmentCTA({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final remaining = tour.pendingSeatsToAssign;
    final hasBus = tour.buses.isNotEmpty;
    return UgamStickyCTA(
      child: UgamCTA(
        // ONE seating entry, ONE label: "Seats". It opens the Seats workspace
        // on the auto-fill SUMMARY (SeatsMode.summary). Auto-fill / re-generate
        // are actions INSIDE that screen, never the navigation entry label.
        label: hasBus ? tr('seats.title') : tr('requests.cta_add_bus'),
        leadingIcon: hasBus ? Icons.event_seat_rounded : Icons.add_rounded,
        trailingValue: hasBus && remaining > 0
            ? tr('requests.cta_remaining', namedArgs: {'n': '$remaining'})
            : null,
        // With a bus → open the Seats workspace (auto-fill SUMMARY). Without a
        // bus → the label says "Add bus" and it must DO that, not sit disabled:
        // route into the add-bus flow so the CTA is never a dead end.
        onPressed: () {
          HapticFeedback.lightImpact();
          if (hasBus) {
            Get.toNamed(
              AppRoutes.tourOverview,
              arguments: {'tourId': tour.id},
            );
          } else {
            Get.to(() => AddBusScreen(tourId: tour.id));
          }
        },
      ),
    );
  }
}

// ─── Bulk action bar ──────────────────────────────────────────────────

class _BulkActionBar extends StatelessWidget {
  final UgamColorSet c;
  final int count;
  final bool isWaitlistTab;

  /// Whether the Confirm slot is offered (false on the Assigned tab, where the
  /// selection is already past the confirm stage).
  final bool canConfirm;
  final VoidCallback onWaitlist;
  final VoidCallback onPromote;
  final VoidCallback onConfirm;
  final VoidCallback onSendWA;
  final VoidCallback onDecline;
  final VoidCallback onCancel;

  const _BulkActionBar({
    required this.c,
    required this.count,
    required this.isWaitlistTab,
    required this.canConfirm,
    required this.onWaitlist,
    required this.onPromote,
    required this.onConfirm,
    required this.onSendWA,
    required this.onDecline,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = count > 0;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.xxl,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c.bg.withValues(alpha: 0), c.bg],
            stops: const [0, 0.35],
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.sm),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            border: Border.all(color: c.border),
          ),
          // Cancel lives in the top bar (the close-X shown in selection mode),
          // so the bar focuses on the real moves. The first slot flips between
          // Promote (waitlist tab) and Waitlist (everywhere else). Confirm is
          // the accent primary when offered; it drops to a plain Send-WA primary
          // on the Assigned tab where confirming is moot.
          child: Row(
            children: [
              Expanded(
                child: isWaitlistTab
                    ? UgamButton(
                        icon: Icons.arrow_back_rounded,
                        label: tr('requests.bulk.promote'),
                        kind: UgamButtonKind.ghost,
                        expand: true,
                        onPressed: enabled ? onPromote : null,
                      )
                    : UgamButton(
                        icon: Icons.hourglass_top_rounded,
                        label: tr('requests.bulk.waitlist'),
                        kind: UgamButtonKind.ghost,
                        expand: true,
                        onPressed: enabled ? onWaitlist : null,
                      ),
              ),
              if (canConfirm)
                Expanded(
                  child: UgamButton(
                    icon: Icons.verified_rounded,
                    label: tr('requests.bulk.confirm'),
                    // The ONE accent in the bulk bar (per accent-rationing).
                    kind: UgamButtonKind.primary,
                    expand: true,
                    onPressed: enabled ? onConfirm : null,
                  ),
                ),
              Expanded(
                child: UgamButton(
                  icon: Icons.chat_rounded,
                  label: tr('requests.bulk.send_wa'),
                  // Accent primary only when Confirm isn't taking that slot
                  // (Assigned tab); otherwise a quiet ghost.
                  kind: canConfirm
                      ? UgamButtonKind.ghost
                      : UgamButtonKind.primary,
                  expand: true,
                  onPressed: enabled ? onSendWA : null,
                ),
              ),
              Expanded(
                child: UgamButton(
                  icon: Icons.close_rounded,
                  label: tr('requests.bulk.decline'),
                  kind: UgamButtonKind.dangerTonal,
                  expand: true,
                  onPressed: enabled ? onDecline : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Passenger card ───────────────────────────────────────────────────

/// Compact seat-weight label: a whole number drops its decimal (1.0 → "1"),
/// a half keeps it (0.5 → "0.5"). Used on the one-way trip chip.
String _fmtSeatLoad(double load) =>
    load == load.roundToDouble() ? load.toInt().toString() : load.toString();

class _RequestCard extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final UgamColorSet c;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback onSelectTap;

  const _RequestCard({
    required this.passenger,
    required this.tour,
    required this.c,
    required this.selectionMode,
    required this.selected,
    required this.onLongPress,
    required this.onSelectTap,
  });

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) {
      return tr('requests.time.days_ago', namedArgs: {'n': '${diff.inDays}'});
    }
    if (diff.inHours > 0) {
      return tr('requests.time.hours_ago', namedArgs: {'n': '${diff.inHours}'});
    }
    if (diff.inMinutes > 0) {
      return tr(
        'requests.time.minutes_ago',
        namedArgs: {'n': '${diff.inMinutes}'},
      );
    }
    return tr('requests.time.just_now');
  }

  /// "BUS 1 · L3, L4" chips — one per bus this passenger holds berths on, so
  /// the agent sees WHERE someone is seated without opening the assignment.
  /// Seat IDs are deduped because a whole double sofa books one seatId twice.
  List<Widget> _assignedSeatChips() {
    if (passenger.assignedSeats.isEmpty) return const [];
    final byBus = <String, List<String>>{};
    for (final a in passenger.assignedSeats) {
      final list = byBus.putIfAbsent(a.busId, () => <String>[]);
      if (!list.contains(a.seatId)) list.add(a.seatId);
    }
    final chips = <Widget>[];
    byBus.forEach((busId, seats) {
      final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
      final busName = bus?.name ?? tr('requests.assigned.bus_fallback');
      chips.add(
        UgamReqChip(
          label: '$busName · ${seats.join(', ')}'.toUpperCase(),
          variant: UgamChipVariant.good,
        ),
      );
    });
    return chips;
  }

  @override
  Widget build(BuildContext context) {
    final isAssigned = passenger.isFullyAssigned;
    final isWaitlisted = passenger.isWaitlisted;
    final isConfirmed = passenger.isConfirmed;
    final PassengerGroup? group = passenger.groupId == null
        ? null
        : tour.groups.firstWhereOrNull((g) => g.id == passenger.groupId);

    // Selection mode keeps a leading checkbox; normal mode drops the avatar
    // entirely (no initials / profile pictures) so the name leads the card and
    // the row stays compact.
    final Widget? checkbox = selectionMode
        ? Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: selected ? c.accent : c.cardElev,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? c.accent : c.border,
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: selected
                ? Icon(Icons.check_rounded, size: 16, color: c.onAccent)
                : null,
          )
        : null;

    final card = AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(
          color: selected ? c.accent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: UgamCard.plain(
        // 8pt grid: 12 padding on every side.
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (checkbox != null) ...[
                  checkbox,
                  const SizedBox(width: UgamSpacing.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        passenger.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.titleS.copyWith(
                          color: c.ink,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.xs),
                      // Phone (tap to call) + time-ago. The list is already
                      // filtered by status, so the old status chip was noise —
                      // the number the agent calls is far more useful here.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (passenger.phone.trim().isNotEmpty) ...[
                            GestureDetector(
                              onTap: selectionMode
                                  ? null
                                  : () => PhoneDialer.call(passenger.phone),
                              behavior: HitTestBehavior.opaque,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 40),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.phone_rounded,
                                      size: 14,
                                      color: c.ink2,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      passenger.phone,
                                      style: UgamText.caption.copyWith(
                                        color: c.ink2,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '·',
                              style: UgamText.caption.copyWith(
                                color: c.ink3,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              _timeAgo(passenger.createdAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: UgamText.caption.copyWith(
                                color: c.ink3,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // All info chips on ONE wrap directly under the name — seat count,
            // request breakdown, one-way weight, partial, priority, group and
            // any assigned seats — instead of three stacked blocks. 8pt-grid
            // spacing (8) between chips. Built inline and spread so the gap
            // above only appears when there's at least one chip.
            ...(() {
              final chips = <Widget>[
                if (passenger.requestLines.isNotEmpty)
                  UgamReqChip(
                    // Count BERTHS (a Double Sofa = 2 seats), so "2 × Double
                    // Sofa" reads as 4 SEATS. Unit word is localized + pluralised.
                    label: passenger.isPartiallyAssigned
                        ? '${passenger.totalSeatsAssigned}/${passenger.seatBerths} ${plural('requests.chip.seats_unit', passenger.seatBerths)}'
                              .toUpperCase()
                        : '${passenger.seatBerths} ${plural('requests.chip.seats_unit', passenger.seatBerths)}'
                              .toUpperCase(),
                    variant: isAssigned
                        ? UgamChipVariant.good
                        : UgamChipVariant.accent,
                  ),
                if (passenger.requestLines.isNotEmpty)
                  UgamReqChip(
                    label: passenger.requestLines
                        .map((l) => l.label)
                        .join(' + ')
                        .toUpperCase(),
                    variant: isAssigned
                        ? UgamChipVariant.good
                        : UgamChipVariant.accent,
                  ),
                if (passenger.tripType.isOneWay)
                  UgamReqChip(
                    // One-way loads a single leg, so it weighs HALF a physical
                    // seat per berth — surface that weight on the trip chip.
                    label: '${passenger.tripType == TripType.outboundOnly ? tr(
                            'requests.chip.trip_outbound',
                            namedArgs: {
                              'from': tour.fromCity,
                              'to': tour.toCity,
                            },
                          ) : tr(
                            'requests.chip.trip_return',
                            namedArgs: {
                              'from': tour.toCity,
                              'to': tour.fromCity,
                            },
                          )} · ${_fmtSeatLoad(passenger.seatLoad)}'
                        .toUpperCase(),
                    variant: UgamChipVariant.warm,
                  ),
                if (passenger.isPartiallyAssigned)
                  UgamReqChip(
                    label: tr('requests.status.partial').toUpperCase(),
                    variant: UgamChipVariant.warm,
                  ),
                if (passenger.isPriorityApproved) _PriorityBadge(c: c),
                // Group badge taps into the single Groups & Priority home.
                if (group != null)
                  GestureDetector(
                    onTap: selectionMode
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            Get.toNamed(
                              AppRoutes.tourGroups,
                              arguments: {'tourId': tour.id},
                            );
                          },
                    behavior: HitTestBehavior.opaque,
                    child: _GroupBadge(group: group, c: c),
                  ),
                ..._assignedSeatChips(),
              ];
              if (chips.isEmpty) return const <Widget>[];
              return <Widget>[
                const SizedBox(height: UgamSpacing.sm),
                Wrap(
                  spacing: UgamSpacing.sm,
                  runSpacing: UgamSpacing.sm,
                  children: chips,
                ),
              ];
            })(),
            if (passenger.note != null && passenger.note!.isNotEmpty) ...[
              const SizedBox(height: UgamSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 16,
                      color: c.ink3,
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        '"${passenger.note}"',
                        // Cap a very long note so it can't blow out the card
                        // height; the full text is still visible on the request.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.caption.copyWith(
                          color: c.ink2,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (!selectionMode) ...[
              const SizedBox(height: UgamSpacing.md),
              _CardActions(
                passenger: passenger,
                tour: tour,
                isAssigned: isAssigned,
                isWaitlisted: isWaitlisted,
                isConfirmed: isConfirmed,
                c: c,
              ),
            ],
          ],
        ),
      ),
    );

    return GestureDetector(
      onLongPress: selectionMode ? null : onLongPress,
      onTap: selectionMode ? onSelectTap : null,
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }
}

/// Warm priority chip shown on a card when the agent has approved a
/// front/sofa need — mirrors the priority star on the Groups & Priority screen.
class _PriorityBadge extends StatelessWidget {
  final UgamColorSet c;
  const _PriorityBadge({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 11, color: c.warm),
          const SizedBox(width: 3),
          Text(
            tr('requests.chip.priority').toUpperCase(),
            style: UgamText.micro.copyWith(
              color: c.warm,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Group badge on a card: the group's stable colour dot + label, so the agent
/// sees a passenger's cross-booking group while triaging without opening the
/// Groups screen. Colour comes from the shared [GroupDot] (seat-chart palette).
class _GroupBadge extends StatelessWidget {
  final PassengerGroup group;
  final UgamColorSet c;
  const _GroupBadge({required this.group, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GroupDot(colorIndex: group.colorIndex, size: 8),
          const SizedBox(width: 4),
          Text(
            (group.label.isEmpty ? tr('tour_groups.group') : group.label)
                .toUpperCase(),
            style: UgamText.micro.copyWith(
              color: c.ink2,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _CardActions extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final bool isAssigned;
  final bool isWaitlisted;
  final bool isConfirmed;
  final UgamColorSet c;

  const _CardActions({
    required this.passenger,
    required this.tour,
    required this.isAssigned,
    required this.isWaitlisted,
    required this.isConfirmed,
    required this.c,
  });

  TourController get _ctrl => Get.find<TourController>();

  Future<void> _sendAck() async {
    // Re-notify ("notify again") an already-seated passenger. Once the tour is
    // LOCKED the seats are final, so this delivers the SAME full seat-allotment
    // as the lock-time send — the highlighted seat chart + boarding place +
    // departure + handler contact — not just a "seats confirmed" greeting.
    // Before lock the seats are provisional (hidden), so we send only the
    // lighter greeting. Before any seats exist, fall back to the free-text
    // request-received deep-link the agent sends from their own WhatsApp.
    if (passenger.assignedSeats.isNotEmpty) {
      try {
        final result =
            WhatsAppOutbound.shouldSendFullAllotment(tour, passenger)
                ? await WhatsAppOutbound().sendSeatAllocations(
                    tour: tour,
                    onlyPassengerIds: {passenger.id},
                  )
                : await WhatsAppOutbound().sendSeatConfirmed(
                    tour: tour,
                    passenger: passenger,
                  );
        if (result.anySent) {
          AppSnackBar.success(
            tr(
              'requests.snack.confirm_sent_body',
              namedArgs: {'name': passenger.displayName},
            ),
            title: tr('requests.snack.confirm_sent_title'),
          );
        } else {
          AppSnackBar.error(tr('requests.snack.confirm_error'));
        }
      } catch (e) {
        AppSnackBar.error('${tr('requests.snack.confirm_error')}\n$e');
      }
      return;
    }

    final sent = await WhatsAppService().sendAck(
      passenger: passenger,
      tour: tour,
    );
    if (sent) {
      AppSnackBar.success(
        tr(
          'requests.snack.ack_opened',
          namedArgs: {'name': passenger.displayName},
        ),
        title: tr('requests.snack.ack_title'),
      );
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
  }

  Future<void> _toWaitlist() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, true);
    AppSnackBar.success(
      tr(
        'requests.snack.moved_to_waitlist',
        namedArgs: {'name': passenger.displayName},
      ),
    );
  }

  Future<void> _promote() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, false);
    AppSnackBar.success(
      tr(
        'requests.snack.promoted_to_new',
        namedArgs: {'name': passenger.displayName},
      ),
    );
  }

  /// Move the request into the Confirmed state (clears any waitlist flag in the
  /// controller) and auto-send the Cloud `seat_allocation` confirmation. This is
  /// the dedicated confirm template — NOT the assign-stage `seat_allotment`
  /// "seat confirmed" message that _sendAck sends once seats exist.
  Future<void> _confirm() async {
    await _ctrl.setConfirmed(tour.id, passenger.id, true);
    await _sendConfirmationMessage();
  }

  /// Fires the Cloud `seat_allocation` confirmation template to this passenger
  /// and toasts the outcome. Split out of [_confirm] so "Confirm & seat" can
  /// reuse the exact same send without re-confirming.
  Future<void> _sendConfirmationMessage() async {
    try {
      final result = await WhatsAppOutbound().sendConfirmed(
        tour: tour,
        passenger: passenger,
      );
      if (result.anySent) {
        AppSnackBar.success(
          tr(
            'requests.snack.confirm_sent_body',
            namedArgs: {'name': passenger.displayName},
          ),
          title: tr('requests.snack.confirm_sent_title'),
        );
      } else {
        // Surface Meta's actual rejection reason (unknown template, wrong
        // language, parameter-count mismatch, etc.) instead of a generic
        // failure — the Cloud API error is the only thing that tells us why.
        final reason = result.results.isNotEmpty
            ? result.results.first.error
            : null;
        debugPrint('Confirm send failed for ${passenger.phone}: '
            '${result.results.map((r) => r.error).toList()}');
        AppSnackBar.error(
          reason == null || reason.isEmpty
              ? tr('requests.snack.confirm_error')
              : '${tr('requests.snack.confirm_error')}\n$reason',
        );
      }
    } catch (e) {
      AppSnackBar.error('${tr('requests.snack.confirm_error')}\n$e');
    }
  }

  /// "Back to New" on a confirmed card — drop the confirmed flag.
  Future<void> _unconfirm() async {
    await _ctrl.setConfirmed(tour.id, passenger.id, false);
  }

  Future<void> _unassignAll() async {
    await _ctrl.unassignSeats(tour.id, passenger.id);
    AppSnackBar.success(
      tr(
        'requests.snack.seats_cleared',
        namedArgs: {'name': passenger.displayName},
      ),
    );
  }

  Future<void> _confirmDecline(BuildContext context) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.decline_dialog.title'),
      message: tr(
        'requests.decline_dialog.body',
        namedArgs: {'name': passenger.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.decline_dialog.confirm'),
      destructive: true,
      confirmIcon: Icons.close_rounded,
    );
    if (!confirmed) return;
    await _ctrl.removePassenger(tour.id, passenger.id);
    AppSnackBar.success(
      tr(
        'requests.snack.declined_body',
        namedArgs: {'name': passenger.displayName},
      ),
      title: tr('requests.snack.declined_title'),
    );
  }

  void _openAssignment() {
    Get.toNamed(
      AppRoutes.seatAssignment,
      arguments: {'tourId': tour.id, 'passengerId': passenger.id},
    );
  }

  /// One-tap "Confirm & seat": collapse the two-step Confirm → Assign into a
  /// single move. Flip the passenger to Confirmed (clears any waitlist flag in
  /// the controller), fire the confirmation WhatsApp, then jump straight into
  /// the seat grid pre-selected to this passenger. The send runs in the
  /// background (unawaited) so the seat grid opens instantly — the toast still
  /// reports the outcome via the global snackbar.
  Future<void> _confirmAndSeat() async {
    HapticFeedback.lightImpact();
    await _ctrl.setConfirmed(tour.id, passenger.id, true);
    unawaited(_sendConfirmationMessage());
    // NOTE: per user request, confirming no longer auto-navigates to seat
    // allocation — it confirms + sends the WhatsApp message and stays on the
    // Requests list. Seats are assigned via the sticky Seats CTA / Assigned tab.
  }

  void _openEdit(BuildContext context) {
    EditRequestSheet.show(context: context, tour: tour, passenger: passenger);
  }

  /// Quick priority toggle — flips this booking between approved-priority and
  /// none right from the card, without opening the Groups & Priority manager.
  /// Turning priority ON confirms first (it promises to reserve a lower berth
  /// where possible); turning it OFF is a direct toggle.
  Future<void> _togglePriority(BuildContext context) async {
    if (!passenger.isPriorityApproved) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('priority.alert_title'),
        message: tr('priority.alert_msg'),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('priority.alert_confirm'),
        confirmIcon: Icons.star_rounded,
      );
      if (!ok) return;
    }
    await _ctrl.setPassengerPriority(
      tour.id,
      passenger.id,
      !passenger.isPriorityApproved,
    );
  }

  /// 40x40 circle icon button — the shared secondary-action primitive used in
  /// every state (Waitlist, Back to New, resend WhatsApp, …).
  Widget _circleButton({
    required IconData icon,
    required Color fill,
    required Color iconColor,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    Widget btn = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: iconColor),
      ),
    );
    if (tooltip != null) btn = Tooltip(message: tooltip, child: btn);
    return Semantics(button: true, label: tooltip, child: btn);
  }

  @override
  Widget build(BuildContext context) {
    final String primaryLabel;
    final IconData primaryIcon;
    final VoidCallback primaryAction;
    // Assigned uses the muted "good" fill; every other state uses the accent.
    final bool primaryIsGood = isAssigned;
    final Widget secondary;
    final List<_MenuItem> menu;

    final editItem = _MenuItem(
      tr('requests.action.edit_request'),
      Icons.edit_rounded,
      () => _openEdit(context),
    );
    final declineItem = _MenuItem(
      tr('requests.action.decline_request'),
      Icons.close_rounded,
      () => _confirmDecline(context),
      isDanger: true,
    );
    // Assign this passenger to an EXISTING cross-booking group (or change/remove
    // it) without leaving Requests. Group CREATION still lives in the single
    // Groups & Priority manager (reached from the sheet) — no duplicated logic.
    final groupItem = _MenuItem(
      passenger.groupId == null
          ? tr('requests.action.add_to_group')
          : tr('requests.action.change_group'),
      Icons.group_add_rounded,
      () => AssignGroupSheet.show(context, tour: tour, passenger: passenger),
    );

    if (isAssigned) {
      // ASSIGNED — view the seat map; keep the one-tap WhatsApp confirmation.
      primaryLabel = tr('requests.action.view_assignment');
      primaryIcon = Icons.visibility_rounded;
      primaryAction = _openAssignment;
      secondary = _circleButton(
        icon: Icons.chat_rounded,
        fill: c.accentFill,
        iconColor: c.accent,
        onTap: _sendAck,
        tooltip: tr('requests.action.send_wa_ack'),
      );
      menu = [
        editItem,
        _MenuItem(
          tr('requests.action.unassign_all'),
          Icons.replay_rounded,
          _unassignAll,
        ),
      ];
    } else if (isConfirmed) {
      // CONFIRMED (no seats yet) — push straight to seat assignment; the circle
      // resends the seat_allotment confirmation WhatsApp.
      primaryLabel = tr('requests.action.assign_seats');
      primaryIcon = Icons.grid_view_rounded;
      primaryAction = _openAssignment;
      secondary = _circleButton(
        icon: Icons.chat_rounded,
        fill: c.accentFill,
        iconColor: c.accent,
        onTap: _confirm,
        tooltip: tr('requests.action.send_wa_ack'),
      );
      menu = [
        editItem,
        groupItem,
        _MenuItem(
          tr('requests.action.back_to_new'),
          Icons.arrow_back_rounded,
          _unconfirm,
        ),
        _MenuItem(
          tr('requests.action.move_to_waitlist'),
          Icons.hourglass_top_rounded,
          _toWaitlist,
        ),
        declineItem,
      ];
    } else if (isWaitlisted) {
      // WAITLIST — "Confirm & seat" is the primary: it clears the waitlist flag
      // (via setConfirmed) and jumps straight into the seat grid, collapsing the
      // waitlist→confirm→assign shuffle. Plain "Confirm" (confirm + WhatsApp,
      // no seating) drops into the overflow. The circle drops back to New.
      primaryLabel = tr('requests.action.confirm_and_seat');
      primaryIcon = Icons.event_seat_rounded;
      primaryAction = _confirmAndSeat;
      secondary = _circleButton(
        icon: Icons.arrow_back_rounded,
        fill: c.cardElev,
        iconColor: c.ink2,
        onTap: _promote,
        tooltip: tr('requests.action.back_to_new'),
      );
      menu = [
        editItem,
        groupItem,
        // Plain confirm (no seating) — confirms + fires the WhatsApp template.
        _MenuItem(
          tr('requests.action.confirm'),
          Icons.verified_rounded,
          _confirm,
        ),
        declineItem,
      ];
    } else {
      // NEW — "Confirm & seat" is the primary (confirm + jump into the seat
      // grid, pre-selected to this passenger), collapsing the usual two-step
      // Confirm-then-Assign. Plain "Confirm" (confirm + WhatsApp, no seating)
      // lives in the overflow. The circle waitlists.
      primaryLabel = tr('requests.action.confirm_and_seat');
      primaryIcon = Icons.event_seat_rounded;
      primaryAction = _confirmAndSeat;
      secondary = _circleButton(
        icon: Icons.hourglass_top_rounded,
        fill: c.cardElev,
        iconColor: c.ink2,
        onTap: _toWaitlist,
        tooltip: tr('requests.action.move_to_waitlist'),
      );
      menu = [
        editItem,
        groupItem,
        // Plain confirm (no seating) — confirms + fires the WhatsApp template.
        _MenuItem(
          tr('requests.action.confirm'),
          Icons.verified_rounded,
          _confirm,
        ),
        _MenuItem(
          tr('requests.action.assign_seats'),
          Icons.grid_view_rounded,
          _openAssignment,
        ),
        declineItem,
      ];
    }

    // Card primary is TONAL (fill + coloured ink), never solid gold — solid
    // champagne is reserved for the screen's single bottom "Seats" CTA, so the
    // eye has one focal point. Assigned keeps the emerald "good" tone; every
    // other state uses the champagne accent. This unifies all four states.
    final Color primaryTone = primaryIsGood ? c.good : c.accent;
    final Color primaryFill = primaryIsGood ? c.goodFill : c.accentFill;

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: primaryAction,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: primaryFill,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: Border.all(color: primaryTone.withValues(alpha: 0.28)),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(primaryIcon, size: 16, color: primaryTone),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      primaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UgamText.bodyStrong.copyWith(
                        color: primaryTone,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        // Quick priority toggle — gold star when this booking is priority.
        _circleButton(
          icon: passenger.isPriorityApproved
              ? Icons.star_rounded
              : Icons.star_outline_rounded,
          fill: passenger.isPriorityApproved ? c.warmFill : c.cardElev,
          iconColor: passenger.isPriorityApproved ? c.warm : c.ink2,
          onTap: () => _togglePriority(context),
          tooltip: tr('requests.chip.priority'),
        ),
        const SizedBox(width: UgamSpacing.sm),
        // Per-state secondary action (Waitlist / Back to New / WhatsApp).
        secondary,
        const SizedBox(width: UgamSpacing.sm),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
          child: PopupMenuButton<_MenuItem>(
            tooltip: tr('requests.action.more_actions'),
            icon: Icon(Icons.more_vert_rounded, size: 18, color: c.ink2),
            position: PopupMenuPosition.under,
            onSelected: (item) => item.onTap(),
            color: c.card,
            itemBuilder: (_) => [
              for (final item in menu)
                PopupMenuItem<_MenuItem>(
                  value: item,
                  child: Row(
                    children: [
                      Icon(
                        item.icon,
                        size: 16,
                        color: item.isDanger ? c.danger : c.ink2,
                      ),
                      const SizedBox(width: UgamSpacing.sm + 2),
                      Text(
                        item.label,
                        style: UgamText.body.copyWith(
                          color: item.isDanger ? c.danger : c.ink,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuItem {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDanger;

  const _MenuItem(this.label, this.icon, this.onTap, {this.isDanger = false});
}


// ─── Add request sheet ────────────────────────────────────────────────

/// Bottom-sheet wrapper for the agent-side direct-add flow. The inputs are the
/// shared [BookingCaptureForm] (with admin contact picker + autocomplete);
/// this wrapper only owns the intro line, the Save CTA, and persistence via
/// [TourController.addPassenger].
class _AddRequestForm extends StatefulWidget {
  final Tour tour;

  const _AddRequestForm({required this.tour});

  @override
  State<_AddRequestForm> createState() => _AddRequestFormState();
}

class _AddRequestFormState extends State<_AddRequestForm> {
  // GlobalKey-style contract: the form is a pure collector, this wrapper reads
  // its validated result and owns the submit button + persistence.
  final _formKey = GlobalKey<BookingCaptureFormState>();
  final _userCtrl = Get.find<UserController>();

  bool _saving = false;

  // Live seat count for the Save CTA chip — updated via the form's onChanged.
  int _seatCount = 0;

  Future<void> _submit() async {
    final data = _formKey.currentState?.collect();
    if (data == null) return; // invalid — the form already showed inline errors.

    setState(() => _saving = true);
    try {
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: data.name,
        phone: data.normalisedPhone,
        requestLines: data.lines,
        note: data.note,
        tripType: data.tripType,
      );
      await Get.find<TourController>().addPassenger(widget.tour.id, passenger);
      // Remember this customer in the admin's directory so the name
      // autocompletes next time — covers people who aren't in the phonebook.
      // rememberContact wants the RAW 10-digit phone.
      // ignore: unawaited_futures
      _userCtrl.rememberContact(name: data.name, phone: data.phone);
      if (!mounted) return;
      Get.back();
      final total = data.totalSeats;
      AppSnackBar.success(
        total == 1
            ? tr('requests.snack.added_one', namedArgs: {'name': data.name})
            : tr(
                'requests.snack.added_many',
                namedArgs: {'name': data.name, 'count': '$total'},
              ),
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('requests.snack.add_error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr(
              'requests.sheet.subtitle',
              namedArgs: {'tourTitle': widget.tour.title},
            ),
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
          ),
          const SizedBox(height: UgamSpacing.lg),
          BookingCaptureForm(
            key: _formKey,
            fromCity: widget.tour.fromCity,
            toCity: widget.tour.toCity,
            enableContacts: true,
            maxPerType: 10,
            onChanged: () {
              final n = _formKey.currentState?.totalSeats ?? 0;
              if (n != _seatCount) setState(() => _seatCount = n);
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('requests.sheet.saving')
                : tr('requests.sheet.save'),
            leadingIcon: Icons.check_rounded,
            trailingValue: _seatCount > 0 ? '$_seatCount' : null,
            loading: _saving,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
