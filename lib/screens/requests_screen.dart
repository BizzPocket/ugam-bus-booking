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
import '../widgets/booking_capture_form.dart';
import '../widgets/edit_request_sheet.dart';
import '../widgets/group_picker.dart';

/// Requests tab — passenger management workspace.
///
/// Layout top → bottom:
///   [Title + circle search + circle "+"]
///   [Collapsible search bar]
///   [Tour selector pills (active solid accent)]
///   [Stats strip: New / Waitlist / Assigned counts]
///   [Filter pills mirror the stats]
///   [Passenger list (dense _RequestCard with avatar / chips / actions)]
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

enum _RequestSort { newest, name, mostSeats }

class _RequestsScreenState extends State<RequestsScreen> {
  final tourCtrl = Get.find<TourController>();
  final _searchCtrl = TextEditingController();

  int _selectedTourIndex = 0;
  _RequestFilter _filter = _RequestFilter.newRequests;
  _RequestSort _sort = _RequestSort.newest;
  bool _searchVisible = false;
  String _query = '';

  // ── Bulk selection state ─────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

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
    UgamSheet.show(
      context,
      title: tr('requests.sheet.title'),
      builder: (_) => _AddRequestForm(tour: tour),
    );
  }

  /// Empty the ENTIRE tour: unassign every seat on every bus in one shot.
  /// Passengers keep their requests and drop straight back into New, so the
  /// agent can re-run auto-fill from a clean slate. Destructive → confirm.
  Future<void> _confirmEmptyBus(Tour tour) async {
    final assigned = tour.totalSeatsAssigned;
    if (assigned == 0) {
      AppSnackBar.info(tr('requests.empty_bus.none'));
      return;
    }
    final ok = await UgamDialog.confirm(
      context,
      title: tr('requests.empty_bus.title'),
      message: tr('requests.empty_bus.body', namedArgs: {'count': '$assigned'}),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.empty_bus.confirm'),
      destructive: true,
      confirmIcon: Icons.layers_clear_rounded,
    );
    if (!ok) return;
    for (final bus in tour.buses) {
      await tourCtrl.unassignBus(tour.id, bus.id);
    }
    if (!mounted) return;
    AppSnackBar.success(tr('requests.empty_bus.done'));
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
  /// per-card Confirm (which clears any waitlist flag), but skips the per-person
  /// WhatsApp send so the bulk move stays fast. Already-assigned passengers are
  /// ignored (they're past the confirm stage).
  Future<void> _bulkConfirm(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    var done = 0;
    for (final id in ids) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null || p.isFullyAssigned) continue;
      await tourCtrl.setConfirmed(tour.id, id, true);
      done++;
    }
    if (!mounted) return;
    AppSnackBar.success(
      tr('requests.bulk.confirmed', namedArgs: {'n': '$done'}),
    );
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

  /// Cycle the list sort order (Newest → Name → Most seats → …) and surface
  /// the new mode as a toast so the change is legible even though the control
  /// is a single compact button.
  void _cycleSort() {
    HapticFeedback.selectionClick();
    setState(() {
      _sort = _RequestSort
          .values[(_sort.index + 1) % _RequestSort.values.length];
    });
  }

  String _sortLabel(_RequestSort s) => switch (s) {
    _RequestSort.newest => tr('requests.sort.newest'),
    _RequestSort.name => tr('requests.sort.name'),
    _RequestSort.mostSeats => tr('requests.sort.most_seats'),
  };

  List<Passenger> _applySort(List<Passenger> list) {
    final out = List<Passenger>.from(list);
    switch (_sort) {
      case _RequestSort.newest:
        out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _RequestSort.name:
        out.sort(
          (a, b) =>
              a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
        );
      case _RequestSort.mostSeats:
        out.sort(
          (a, b) => b.totalSeatsRequested.compareTo(a.totalSeatsRequested),
        );
    }
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
                    searchActive: _searchVisible,
                    onToggleSearch: _toggleSearch,
                    onAdd: selectedTour == null
                        ? null
                        : () => _openAddRequest(selectedTour),
                    onEmptyBus: selectedTour == null
                        ? null
                        : () => _confirmEmptyBus(selectedTour),
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
    final passengers = _applySort(filtered);

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
        // One filter row: pills (with counts) + a compact sort toggle. The old
        // stats strip was redundant with these counts, so it's gone.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: Row(
            children: [
              Expanded(
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
              const SizedBox(width: UgamSpacing.sm),
              // Four pills leave little room, so the sort control is icon-only
              // here; its current mode shows in the tooltip and still cycles
              // on tap.
              _SortButton(
                c: c,
                tooltip: _sortLabel(_sort),
                onTap: _cycleSort,
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
                      _selectionMode ? 110 : 160,
                    ),
                    itemCount: passengers.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.md),
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
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback? onAdd;
  final VoidCallback? onEmptyBus;
  final bool selectionMode;
  final int selectedCount;
  final VoidCallback onExitSelection;

  const _TopBar({
    required this.c,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onAdd,
    required this.onEmptyBus,
    required this.selectionMode,
    required this.selectedCount,
    required this.onExitSelection,
  });

  @override
  Widget build(BuildContext context) {
    if (selectionMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.lg,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        child: Row(
          children: [
            _CircleBtn(icon: Icons.close_rounded, c: c, onTap: onExitSelection),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                tr('requests.selected_count', namedArgs: {'n': '$selectedCount'}),
                style: UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr('requests.title'),
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 28),
            ),
          ),
          _CircleBtn(
            icon: searchActive ? Icons.close_rounded : Icons.search_rounded,
            c: c,
            onTap: onToggleSearch,
            active: searchActive,
          ),
          if (onEmptyBus != null) ...[
            const SizedBox(width: UgamSpacing.sm),
            _MoreMenu(c: c, onEmptyBus: onEmptyBus),
          ],
          const SizedBox(width: UgamSpacing.sm),
          GestureDetector(
            onTap: onAdd,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: onAdd == null
                    ? c.accent.withValues(alpha: 0.4)
                    : c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.person_add_alt_rounded,
                size: 19,
                color: c.onAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool active;
  const _CircleBtn({
    required this.icon,
    required this.c,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: active ? c.accent : c.ink),
      ),
    );
  }
}

/// Compact "more actions" overflow for the Requests top bar. Holds the one
/// tour-level move that doesn't belong on any single passenger card: empty
/// every assigned seat on the tour. (Groups & Priority has its single home on
/// the tour workspace TourTools tile — it is NOT duplicated here.) The callback
/// is nullable — the menu only renders when it's live.
class _MoreMenu extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback? onEmptyBus;
  const _MoreMenu({required this.c, required this.onEmptyBus});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
      child: PopupMenuButton<_TopAction>(
        tooltip: tr('requests.menu.tooltip'),
        icon: Icon(Icons.more_vert_rounded, size: 19, color: c.ink),
        position: PopupMenuPosition.under,
        color: c.card,
        onSelected: (a) {
          switch (a) {
            case _TopAction.emptyBus:
              onEmptyBus?.call();
          }
        },
        itemBuilder: (_) => [
          if (onEmptyBus != null)
            PopupMenuItem<_TopAction>(
              value: _TopAction.emptyBus,
              child: _MenuRow(
                icon: Icons.layers_clear_rounded,
                label: tr('requests.menu.empty_bus'),
                c: c,
                danger: true,
              ),
            ),
        ],
      ),
    );
  }
}

enum _TopAction { emptyBus }

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final UgamColorSet c;
  final bool danger;
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.c,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: danger ? c.danger : c.ink2),
        const SizedBox(width: UgamSpacing.sm + 2),
        Text(
          label,
          style: UgamText.body.copyWith(
            color: danger ? c.danger : c.ink,
            fontSize: 13,
          ),
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
class _CapacityBanner extends StatelessWidget {
  final UgamColorSet c;
  final Tour tour;
  const _CapacityBanner({required this.c, required this.tour});

  @override
  Widget build(BuildContext context) {
    final capacity = tour.totalBusSeats;
    var demand = 0;
    for (final p in tour.passengers) {
      if (p.isWaitlisted) continue;
      for (final line in p.requestLines) {
        demand += line.qty * (line.seatType == SeatType.doubleSofa ? 2 : 1);
      }
    }
    final noBus = tour.buses.isEmpty;
    final free = capacity - demand;
    final over = !noBus && free < 0;

    final (Color tone, Color fill, IconData icon, String statusValue,
        String statusLabel) = noBus
        ? (c.warm, c.warmFill, Icons.directions_bus_outlined, '—',
            tr('requests.capacity.no_buses'))
        : over
        ? (c.danger, c.danger.withValues(alpha: 0.12),
            Icons.error_outline_rounded, '${-free}',
            tr('requests.capacity.over'))
        : (c.good, c.goodFill, Icons.event_seat_outlined, '$free',
            tr('requests.capacity.free'));

    return Container(
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
          Row(
            children: [
              Icon(icon, size: 18, color: tone),
              const SizedBox(width: UgamSpacing.sm),
              _CapSeg(
                c: c,
                value: '$demand',
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
          // Glanceable demand-vs-capacity fill bar — reads "how full the bus is"
          // at a glance, without parsing the three numbers. Hidden when there's
          // no bus yet (no capacity to fill).
          if (!noBus) ...[
            const SizedBox(height: UgamSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: capacity <= 0 ? 0 : (demand / capacity).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: c.border,
                valueColor: AlwaysStoppedAnimation<Color>(tone),
              ),
            ),
          ],
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

// ─── Sort button ──────────────────────────────────────────────────────

/// Compact sort toggle that sits beside the filter pills. Tapping cycles the
/// order; the current mode is shown as its short label.
class _SortButton extends StatelessWidget {
  final UgamColorSet c;
  final String tooltip;
  final VoidCallback onTap;
  const _SortButton({
    required this.c,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Icon-only sort toggle: with four filter pills sharing the row there's no
    // room for the mode label, so the tappable icon stands in for it and the
    // current mode lives in the tooltip.
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.swap_vert_rounded, size: 18, color: c.ink2),
        ),
      ),
    );
  }
}

// ─── Assignment CTA ───────────────────────────────────────────────────

class _AssignmentCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _AssignmentCTA({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final remaining = (tour.totalSeatsRequested - tour.totalSeatsAssigned)
        .clamp(0, 99999);
    final hasBus = tour.buses.isNotEmpty;
    return UgamStickyCTA(
      child: UgamCTA(
        // ONE seating entry, ONE label: "Seats". It opens the Seats workspace
        // on the auto-fill SUMMARY (SeatsMode.summary). Auto-fill / re-generate
        // are actions INSIDE that screen, never the navigation entry label.
        label: hasBus ? tr('seats.title') : tr('requests.cta_add_bus'),
        leadingIcon: Icons.event_seat_rounded,
        trailingValue: hasBus && remaining > 0
            ? tr('requests.cta_remaining', namedArgs: {'n': '$remaining'})
            : null,
        onPressed: hasBus
            ? () {
                HapticFeedback.lightImpact();
                // Seats workspace on the SUMMARY; the in-screen "Edit seats by
                // hand" CTA switches to the editable grid as needed.
                Get.toNamed(
                  AppRoutes.tourOverview,
                  arguments: {'tourId': tour.id},
                );
              }
            : null,
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

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

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

    Widget leading;
    if (selectionMode) {
      leading = Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: selected ? c.accent : c.cardElev,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? c.accent : c.border, width: 1.5),
        ),
        alignment: Alignment.center,
        child: selected
            ? Icon(Icons.check_rounded, size: 18, color: c.onAccent)
            : null,
      );
    } else {
      leading = Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(
          _initials(passenger.name),
          style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
        ),
      );
    }

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: UgamSpacing.sm + 2),
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
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // Phone (tap to call) + time-ago. The list is already
                      // filtered by status, so the old status chip was noise —
                      // the number the agent calls is far more useful here.
                      Row(
                        children: [
                          if (passenger.phone.trim().isNotEmpty) ...[
                            GestureDetector(
                              onTap: selectionMode
                                  ? null
                                  : () => PhoneDialer.call(passenger.phone),
                              behavior: HitTestBehavior.opaque,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.phone_rounded,
                                    size: 12,
                                    color: c.accent,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    passenger.phone,
                                    style: UgamText.caption.copyWith(
                                      color: c.ink2,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '·',
                              style: UgamText.caption.copyWith(
                                color: c.ink3,
                                fontSize: 11,
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
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (passenger.isPartiallyAssigned)
                  UgamReqChip(
                    label: tr('requests.status.partial').toUpperCase(),
                    variant: UgamChipVariant.warm,
                  ),
              ],
            ),
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
            if (passenger.isPriorityApproved || group != null) ...[
              const SizedBox(height: UgamSpacing.md),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (passenger.isPriorityApproved) _PriorityBadge(c: c),
                  // Badge reflects membership; tapping links into the single
                  // Groups & Priority home (no group management on the card).
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
                ],
              ),
            ],
            if (passenger.requestLines.isNotEmpty) ...[
              const SizedBox(height: UgamSpacing.md),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  UgamReqChip(
                    // Count BERTHS (a Double Sofa = 2 seats), so "2 × Double
                    // Sofa" reads as 4 SEATS. assignedSeats is already berths.
                    // Unit word is localized + pluralised (1 SEAT vs 4 SEATS).
                    label: passenger.isPartiallyAssigned
                        ? '${passenger.totalSeatsAssigned}/${passenger.seatBerths} ${plural('requests.chip.seats_unit', passenger.seatBerths)}'
                              .toUpperCase()
                        : '${passenger.seatBerths} ${plural('requests.chip.seats_unit', passenger.seatBerths)}'
                              .toUpperCase(),
                    variant: isAssigned
                        ? UgamChipVariant.good
                        : UgamChipVariant.accent,
                  ),
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
                      label: passenger.tripType == TripType.outboundOnly
                          ? tr(
                              'requests.chip.trip_outbound',
                              namedArgs: {
                                'from': tour.fromCity,
                                'to': tour.toCity,
                              },
                            ).toUpperCase()
                          : tr(
                              'requests.chip.trip_return',
                              namedArgs: {
                                'from': tour.toCity,
                                'to': tour.fromCity,
                              },
                            ).toUpperCase(),
                      variant: UgamChipVariant.warm,
                    ),
                  ..._assignedSeatChips(),
                ],
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
        borderRadius: BorderRadius.circular(6),
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
              fontSize: 9.5,
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
        borderRadius: BorderRadius.circular(6),
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
              fontSize: 9.5,
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
    // Seats assigned (but tour not locked) → send the Cloud `seat_allotment`
    // "seat confirmed" template from the business number (automatic, no manual
    // WhatsApp tap). Before any seats exist, fall back to the free-text
    // request-received deep-link the agent sends from their own WhatsApp.
    if (passenger.assignedSeats.isNotEmpty) {
      try {
        final result = await WhatsAppOutbound().sendSeatConfirmed(
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
  /// the controller), then jump straight into the seat grid pre-selected to
  /// this passenger. No WhatsApp send here — the agent is mid-seating, so the
  /// confirmation message goes out later from the assigned card.
  Future<void> _confirmAndSeat() async {
    HapticFeedback.lightImpact();
    await _ctrl.setConfirmed(tour.id, passenger.id, true);
    _openAssignment();
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
    final btn = GestureDetector(
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
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
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
      );
      menu = [
        editItem,
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
                        fontSize: 12.5,
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
