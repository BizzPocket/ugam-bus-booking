import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
// ScrollDirection — flutter/widgets only re-exports TextSelectionHandleType
// from rendering, so the bottom bar's scroll-direction listener needs this.
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/pickup_controller.dart';
import '../controllers/tour_controller.dart';
import '../controllers/user_controller.dart';
// Not in the design barrel yet (the foundation phase added the component but
// not the export line) — imported directly rather than hand-rolling a press.
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/trip_type.dart';
import '../routes/app_routes.dart';
import '../services/whatsapp_outbound.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_nav.dart';
import '../utils/app_snackbar.dart';
import '../utils/in_flight.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/tour_capacity.dart';
import '../utils/wa_error_text.dart';
import '../widgets/booking_capture_form.dart';
import '../widgets/waitlist_collect_sheet.dart';
import '../widgets/edit_request_sheet.dart';
import '../widgets/group_picker.dart';
import 'add_bus_screen.dart';
import 'main_shell.dart';

part 'requests/bulk_actions.dart';
part 'requests/chrome.dart';
part 'requests/capacity_banner.dart';
part 'requests/request_card.dart';
part 'requests/request_actions.dart';
part 'requests/add_request_form.dart';

/// Requests tab — passenger management workspace.
///
/// Layout top → bottom:
///   [Title + circle search + groups + circle "+"]
///   [Collapsible search bar]
///   [Tour selector pills (active tonal accent)]
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

  /// True until the agent picks a tab themselves. While set, the list opens
  /// on the FIRST NON-EMPTY tab (New preferred) instead of always landing on
  /// an empty "New 0" with every rider hidden one tap away. Re-armed by every
  /// path that used to snap back to New (re-entry, deep link, tour switch).
  bool _autoFilter = true;
  bool _searchVisible = false;
  String _query = '';

  // Which request row is expanded (single-open accordion). Null = all collapsed.
  String? _expandedId;

  // ── Bulk selection state ─────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  // Requests is index 3 in MainShell._adminPages. Named so the re-entry reset
  // below reads intentionally rather than as a bare magic number.
  static const int _kRequestsTabIndex = 3;
  // Watches the shell's active-tab index (wired in initState) so the filter can
  // snap back to New whenever this tab is re-entered — see _resetToNewOnReentry.
  Worker? _tabReentryWorker;

  // ── Bottom chrome geometry ───────────────────────────────────
  //
  // This screen floats its OWN action bar over a shell that already floats the
  // dock nav at the same edge. Both used to be pinned to `bottom: 0`, so the
  // black "Seats · 7 left" bar sat behind the dock capsule and list rows
  // scrolled under two overlapping slabs. The bar is now lifted to rest
  // directly on top of the dock, and it retracts behind the dock while the
  // agent scrolls DOWN the list, so the bottom edge only ever carries one
  // piece of chrome at a time.
  //
  // Both floating controls are 52pt tall: UgamDockNav's capsule is its 44pt
  // tap floor plus 4pt of padding on each side, and UgamCTA floors at
  // `minHeight: 52`. Neither is exposed as a token — AppSnackBar hand-sums the
  // same number for its toast offset.
  static const double _kFloatingControl = 52;

  /// Lift that clears the dock: its capsule + the dock's own bottom padding.
  /// The safe-area inset is NOT added here — [UgamStickyCTA] wraps its child
  /// in a bottom `SafeArea`, which supplies exactly that much itself.
  static const double _kBarLift = _kFloatingControl + UgamSpacing.md; // 64

  /// [UgamStickyCTA]'s own painted height: 16 above the control, 12 below.
  static const double _kBarHeight =
      UgamSpacing.lg + _kFloatingControl + UgamSpacing.md; // 80

  /// Bottom inset the list must reserve so no row is ever trapped behind
  /// chrome. With no bottom bar the dock alone is in the way and the shared
  /// [UgamSpacing.dockClearance] covers it; with a bar, its lift + height +
  /// the safe-area inset it adds stack on top of that edge.
  double _listBottomInset(BuildContext context, {required bool withBar}) {
    if (!withBar) return UgamSpacing.dockClearance;
    return _kBarLift + _kBarHeight + MediaQuery.paddingOf(context).bottom;
  }

  /// Whether a bottom bar will ACTUALLY paint over the content.
  ///
  /// Used to be assumed true, because the Seats CTA was always there. It is
  /// gone (see [_AssignmentCTA]), so the two remaining cases are the bulk bar
  /// while multi-selecting and the add-bus CTA on a tour with no bus. Anything
  /// that reserves bottom space has to ask this rather than assume — reserving
  /// for an absent bar leaves 144pt of dead space under the last row, and NOT
  /// reserving for a present one traps that row behind it.
  bool _hasBottomBar(Tour tour) => _selectionMode || tour.buses.isEmpty;

  // Whether the floating action bar is currently extended. Scrolling DOWN the
  // list retracts it behind the dock; scrolling back up — or any state change
  // that re-frames the list — brings it home. The bulk-action bar is exempt:
  // it is the only way out of a multi-select, so it never hides.
  bool _barShown = true;

  bool _onUserScroll(UserScrollNotification n) {
    if (_selectionMode || n.metrics.axis != Axis.vertical) return false;
    if (n.direction == ScrollDirection.reverse && _barShown) {
      setState(() => _barShown = false);
    } else if (n.direction == ScrollDirection.forward && !_barShown) {
      setState(() => _barShown = true);
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    // Load the global pickup-location list once so cards can resolve the
    // short code ("ST") beside each rider's pickup name. Guarded + idempotent.
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
    // Honour a deep-link target tour, falling back to the first tour when the
    // id is unknown (e.g. the tour was completed/removed since the link).
    final id = widget.initialTourId;
    if (id != null) {
      final idx = tourCtrl.activeTours.indexWhere((t) => t.id == id);
      if (idx >= 0) _selectedTourIndex = idx;
    }
    // This screen lives in MainShell's IndexedStack, so a bare tab switch (the
    // dashboard "new request" card / a push that just calls onTabTapped) does
    // NOT re-run initState or didUpdateWidget — the widget only goes from off-
    // to on-stage with _filter/_selection frozen from the previous visit. A
    // request that arrived while the agent last left the Confirmed/Assigned tab
    // open would then land on a tab where it's invisible. Watch the shell's
    // active-tab index and, each time the Requests tab becomes active again,
    // snap back to New + drop stale selection so the new request is in view.
    if (Get.isRegistered<ShellController>()) {
      _tabReentryWorker =
          ever<int>(Get.find<ShellController>().currentIndex, (i) {
        if (i == _kRequestsTabIndex) _resetToNewOnReentry();
      });
    }
  }

  @override
  void didUpdateWidget(RequestsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A deep link / push that names a specific tour rebuilds us with a new
    // initialTourId: honor it (select that tour) and reset to the New tab so the
    // request that triggered the navigation is on screen, not stranded behind a
    // stale filter left over from the previous visit.
    final id = widget.initialTourId;
    if (id != null && id != oldWidget.initialTourId && mounted) {
      final idx = tourCtrl.activeTours.indexWhere((t) => t.id == id);
      setState(() {
        if (idx >= 0) _selectedTourIndex = idx;
        _resetViewState();
      });
    }
  }

  /// Back to the New tab (auto-filter re-armed) with nothing expanded or
  /// selected. Callers wrap it in setState.
  void _resetViewState() {
    _filter = _RequestFilter.newRequests;
    _autoFilter = true;
    _expandedId = null;
    _selectionMode = false;
    _selectedIds.clear();
    _barShown = true;
  }

  @override
  void dispose() {
    _tabReentryWorker?.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Snap the list back to the New tab and drop any stale expand/selection.
  /// Fired by the shell-index worker (see initState) so a request that arrives
  /// while this tab was off-stage is always visible on re-entry.
  void _resetToNewOnReentry() {
    if (!mounted) return;
    setState(_resetViewState);
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
    // Locking a tour closes it to CUSTOMERS only — the anonymous
    // submit_booking_request RPC (migration 026/030) refuses a new request once
    // the status is locked/completed. The ORGANISER, however, must still be able
    // to add a rider by hand after locking (a late walk-in or phone booking), so
    // the admin add form always opens; its save passes overrideLock (see
    // _AddRequestForm._submit) to skip the acceptsBookings gate.
    // This sheet hosts the full multi-field BookingCaptureForm with no draft
    // persistence, so a stray downward drag while scrolling it used to discard
    // an entire walk-in booking. Drag is off; the scrim/back path is guarded by
    // a PopScope inside _AddRequestForm once seats have been entered.
    UgamSheet.show(
      context,
      title: tr('requests.sheet.title'),
      enableDrag: false,
      builder: (_) => _AddRequestForm(tour: tour),
    );
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
      // Leaving a multi-select re-frames the bottom edge — bring the Seats CTA
      // back rather than leaving the edge empty until the next upward scroll.
      _barShown = true;
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
      _expandedId = null;
      _selectedIds.add(id);
      _barShown = true;
    });
  }

  /// Default ordering: newest request first. The sort control was removed —
  /// Newest-first for New/Waitlist/Assigned. On Confirmed, partially assigned
  /// riders (still owing berths) float above unseated accepts so remaining
  /// seats aren't buried.
  List<Passenger> _orderForFilter(List<Passenger> list) {
    final out = List<Passenger>.from(list);
    if (_filter == _RequestFilter.confirmed) {
      out.sort((a, b) {
        final ap = a.isPartiallyAssigned ? 0 : 1;
        final bp = b.isPartiallyAssigned ? 0 : 1;
        if (ap != bp) return ap - bp;
        return b.createdAt.compareTo(a.createdAt);
      });
    } else {
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return out;
  }

  /// Wrap a request row in the shared swipe affordance. Right swipe = the
  /// state's positive move (snaps back); left swipe = decline (removes the row).
  /// Assigned rows and pending-cancellation rows expose no destructive left
  /// swipe — decline isn't offered there.
  Widget _swipeWrap(Tour tour, Passenger p, Widget card) {
    final c = UgamColors.of(context);
    final act = _RequestActions(passenger: p, tour: tour);

    // Right-swipe action + icon by state.
    final IconData rightIcon;
    final VoidCallback onRight;
    if (p.isCancelRequested) {
      rightIcon = Icons.event_busy_rounded;
      onRight = () => act.approveCancellation(context);
    } else if (p.isFullyAssigned) {
      rightIcon = Icons.chat_rounded;
      onRight = act.sendAck;
    } else if (p.isConfirmed) {
      rightIcon = Icons.grid_view_rounded;
      onRight = act.openAssignment;
    } else {
      // New / waitlisted: right-swipe ACCEPTS (and fires the WhatsApp
      // confirmation) but does NOT open the seat grid, so the icon is a check,
      // not a seat — matching the Accept primary on the card.
      rightIcon = Icons.check_circle_rounded;
      onRight = act.confirmAndSeat;
    }

    // Left (destructive) swipe = decline, only where decline is offered. On
    // Assigned / cancel-pending rows the gate returns false so a left swipe
    // never dismisses the row.
    final bool canDecline = !p.isFullyAssigned && !p.isCancelRequested;

    return UgamSwipeAction(
      key: ValueKey('swipe_${p.id}'),
      borderRadius: BorderRadius.circular(UgamRadius.card),
      rightIcon: rightIcon,
      // Tonal, not solid: the sticky "Seats" CTA is the screen's one solid
      // accent, so the swipe pane must not paint a competing full-bleed slab.
      rightColor: c.accentFill,
      onRight: onRight,
      confirmDelete: canDecline
          ? () => act.confirmDecline(context)
          : () async => false,
      deleteIcon: Icons.close_rounded,
      child: card,
    );
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
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
          // Hide the sticky assignment CTA until there's at least one live
          // request: on an empty roster "Add a bus"/"Seats" is a dead-end
          // action (BUG-003). journeyDone passengers are off the active roster.
          final bool hasRequests = selectedTour != null &&
              selectedTour.passengers.any((p) => !p.journeyDone);

          final stack = Stack(
            children: [
              Column(
                children: [
                  _TopBar(
                    c: c,
                    // Pushed/scoped mode (opened from a tour workspace with a
                    // tour pre-selected) strands the user with no dock nav — so
                    // render a back affordance. The shell tab (initialTourId
                    // null, nothing to pop) keeps the plain title.
                    showBack: widget.initialTourId != null &&
                        Navigator.canPop(context),
                    onBack: () => AppNav.pop(context),
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
                        // "No tours" is a verdict only once the list has
                        // answered: on a first load, or after it failed, the
                        // agent's tours are simply not here YET.
                        ? (tourCtrl.isLoading.value
                            ? ListView(
                                physics: const NeverScrollableScrollPhysics(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UgamSpacing.gutter,
                                ),
                                children: [
                                  for (var i = 0; i < 5; i++) ...[
                                    const UgamSkeleton.row(),
                                    const SizedBox(height: UgamSpacing.sm),
                                  ],
                                ],
                              )
                            : tourCtrl.hasError.value
                                ? UgamEmpty.error(
                                    onRetry: () => tourCtrl.refreshTours(),
                                  )
                                : UgamEmpty(
                                    icon: Icons.chat_bubble_outline_rounded,
                                    title: tr('requests.empty_no_tours.title'),
                                    body: tr('requests.empty_no_tours.body'),
                                  ))
                        : _buildBody(activeTours, selectedTour!, c),
                  ),
                ],
              ),
              if (selectedTour != null)
                Positioned(
                  left: 0,
                  right: 0,
                  // Lifted clear of the shell's floating dock instead of
                  // stacking on top of it (see _kBarLift).
                  bottom: _kBarLift,
                  child: _RetractingBar(
                    // The bulk bar owns the edge outright while selecting; only
                    // the Seats CTA gets out of the way on a downward scroll.
                    shown: _selectionMode || _barShown,
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
                          // Decline/cancel stays available through the confirmed
                          // stage (a confirmed-but-unseated request may need to
                          // be removed). Only the Assigned tab hides it — there
                          // the seat is unassigned first, which drops the
                          // passenger back to Confirmed where decline lives.
                          canDecline:
                              _filter != _RequestFilter.assigned,
                          // ONE bulk action per tour at a time: a second tap
                          // on a slow link re-ran the whole loop — a second
                          // confirmation WhatsApp to every selected rider.
                          onWaitlist: () => _bulkOnce(
                              selectedTour, () => _bulkWaitlist(selectedTour)),
                          onPromote: () => _bulkOnce(
                              selectedTour, () => _bulkPromote(selectedTour)),
                          onConfirm: () => _bulkOnce(
                              selectedTour, () => _bulkConfirm(selectedTour)),
                          onSendWA: () => _bulkOnce(
                              selectedTour, () => _bulkSendWA(selectedTour)),
                          onDecline: () => _bulkOnce(
                              selectedTour, () => _bulkDecline(selectedTour)),
                          onCancel: _exitSelection,
                        )
                      : (hasRequests
                          ? _AssignmentCTA(tour: selectedTour, c: c)
                          : const SizedBox.shrink()),
                  ),
                ),
            ],
          );

          // Android back while rows are selected must CLEAR the selection, not
          // leave the screen. This screen lives in MainShell's IndexedStack, so
          // popping out latches it: coming back shows the bulk bar still up,
          // the old rows still checked, and no undo but the header X.
          return PopScope(
            canPop: !_selectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _selectionMode) _exitSelection();
            },
            child: stack,
          );
        }),
      ),
    );
  }

  /// Empty-list placeholder: a search miss wins over the per-tab copy.
  Widget _emptyState() {
    if (_query.isNotEmpty) {
      return UgamEmpty(
        icon: Icons.search_off_rounded,
        title: tr('requests.empty_search.title'),
        body: tr('requests.empty_search.body', namedArgs: {'query': _query}),
      );
    }
    return switch (_filter) {
      _RequestFilter.newRequests => UgamEmpty(
          icon: Icons.people_outline_rounded,
          title: tr('requests.empty_new.title'),
          body: tr('requests.empty_new.body'),
        ),
      _RequestFilter.waitlist => UgamEmpty(
          icon: Icons.hourglass_empty_rounded,
          title: tr('requests.empty_waitlist.title'),
          body: tr('requests.empty_waitlist.body'),
        ),
      _RequestFilter.confirmed => UgamEmpty(
          icon: Icons.verified_rounded,
          title: tr('requests.empty_confirmed.title'),
          body: tr('requests.empty_confirmed.body'),
        ),
      _RequestFilter.assigned => UgamEmpty(
          icon: Icons.check_circle_outline_rounded,
          title: tr('requests.empty_assigned.title'),
          body: tr('requests.empty_assigned.body'),
        ),
    };
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

    if (_autoFilter) {
      // First non-empty tab, in tab order — so New wins whenever it has
      // anyone (a fresh request is always in view), and a locked tour where
      // everyone is seated opens on Assigned rather than an empty New.
      final lists = [newList, waitlistList, confirmedList, assignedList];
      final first = lists.indexWhere((l) => l.isNotEmpty);
      _filter = _RequestFilter.values[first < 0 ? 0 : first];
    }

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
    final passengers = _orderForFilter(filtered);

    return Column(
      children: [
        if (activeTours.length > 1) ...[
          const SizedBox(height: UgamSpacing.xs),
          UgamSelectorPills(
            currentIndex: _selectedTourIndex,
            onChanged: (i) {
              setState(() {
                _selectedTourIndex = i;
                _autoFilter = true;
                _expandedId = null;
                _barShown = true;
              });
              // Its own setState — never nest one inside another's callback.
              _exitSelection();
            },
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
            onChanged: (i) => setState(() {
              _filter = _RequestFilter.values[i];
              _autoFilter = false;
              _expandedId = null;
              _barShown = true;
            }),
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
          // Scroll direction drives the floating action bar's retract/extend
          // so the list never has to fight two slabs for the bottom edge.
          child: NotificationListener<UserScrollNotification>(
            onNotification: _onUserScroll,
            child: RefreshIndicator(
              // Chrome, not ownership — the pull spinner is neutral ink2 in
              // every screen, so it never changes hue between tabs.
              color: c.ink2,
              onRefresh: tourCtrl.refreshTours,
              child: passengers.isEmpty
                ? LayoutBuilder(
                  builder: (context, constraints) {
                  // The empty branch reserved NOTHING at the bottom while the
                  // populated one reserved the full bar inset, so the empty
                  // state's body text was laid out underneath the floating CTA
                  // and clipped by it. Same inset as the list, same predicate.
                  final inset = _listBottomInset(
                    context,
                    withBar: _hasBottomBar(selectedTour),
                  );
                  // Was a flat 45% of SCREEN height — a magic fraction blind to
                  // the tour/filter chrome above, the bar below and the text
                  // scale, which is how the body line ended up under the
                  // button. Measure the box this list actually has, minus what
                  // the chrome claims. Floored so a very small viewport at a
                  // large text scale can never ask for a negative height.
                  final free = math.max(0.0, constraints.maxHeight - inset);
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: EdgeInsets.only(bottom: inset),
                    children: [
                      SizedBox(height: free, child: _emptyState()),
                    ],
                  );
                })
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      0,
                      UgamSpacing.gutter,
                      // Reserve for the bar only when one is really there —
                      // the bulk bar while selecting, or the add-bus CTA on a
                      // busless tour. With the Seats CTA gone that is now the
                      // minority case, and assuming it left a dead 144pt gap
                      // below the last request.
                      _listBottomInset(
                        context,
                        withBar: _hasBottomBar(selectedTour),
                      ),
                    ),
                    itemCount: passengers.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.tight),
                    itemBuilder: (_, i) {
                      final p = passengers[i];
                      final selected = _selectedIds.contains(p.id);
                      final card = _RequestCard(
                        passenger: p,
                        tour: selectedTour,
                        c: c,
                        selectionMode: _selectionMode,
                        selected: selected,
                        expanded: _expandedId == p.id,
                        onToggleExpand: () => setState(() {
                          _expandedId = _expandedId == p.id ? null : p.id;
                        }),
                        onLongPress: () => _enterSelection(p.id),
                        onSelectTap: () => _toggleSelect(p.id),
                      );
                      // Selection mode disables swipe (tap selects, long-press
                      // is already active); otherwise wrap in the swipe path.
                      if (_selectionMode) return card;
                      return _swipeWrap(selectedTour, p, card);
                    },
                  ),
            ),
          ),
        ),
      ],
    );
  }
}
