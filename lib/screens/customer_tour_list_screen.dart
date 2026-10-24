import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/content_block_view.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../services/crowd_location_share.dart';
import '../services/customer_requests_store.dart';
import '../utils/time_format.dart';
import 'customer_booking_request_screen.dart';
import 'customer_more_screen.dart';
import 'customer_my_requests_screen.dart';
import 'customer_tour_detail_screen.dart';
import 'find_my_seat_screen.dart';
import 'party_gate_screen.dart';
import 'customer_format.dart';

part 'customer_tour_list/top_bar.dart';
part 'customer_tour_list/tour_row.dart';

/// Public-facing tour list — image-5 fidelity.
///
/// Layout:
///   [Title row + my-bookings + more]
///   [Find my seat bar (expands to a number field)]
///   [Group: Upcoming]
///   [Group: Later]
///
/// Visually mirrors the admin `tours_screen.dart`: photo-anchored 88-px
/// rows with backdrop thumbnail + route header + date pill + chips. No
/// "+" button — customers don't create tours. No "Past" group — customers
/// don't need history.
///
/// THERE IS NO SEARCH. It occupied the most valuable slot on the customer's
/// first screen to filter a list that is two or three rows long — the whole
/// list is already on screen, so the field could only ever hide rows. That
/// slot now belongs to "Find my seat", which is what a customer who already
/// booked actually opens the app to do, and which was previously buried three
/// taps deep behind the More menu.
class CustomerTourListScreen extends StatefulWidget {
  const CustomerTourListScreen({super.key});

  @override
  State<CustomerTourListScreen> createState() => _CustomerTourListScreenState();
}

class _CustomerTourListScreenState extends State<CustomerTourListScreen> {
  final _store = CustomerRequestsStore();
  final _phoneCtrl = TextEditingController();
  final _phoneFocus = FocusNode();

  /// The find-my-seat bar starts as a one-line prompt and opens into a number
  /// field on tap. Collapsed by default so the tours — the reason a NEW
  /// visitor is here — stay at the top of the page.
  bool _findOpen = false;
  int _myRequestCount = 0;

  @override
  void initState() {
    super.initState();
    _loadRequestCount();
    _loadRememberedPhone();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _phoneFocus.dispose();
    super.dispose();
  }

  /// Reads the device-local journal of submitted requests (cheap cached
  /// read — no network) so the top-bar badge reflects how many bookings
  /// the customer can track.
  Future<void> _loadRequestCount() async {
    final entries = await _store.list();
    if (!mounted) return;
    // Only count live requests; past tours are history and should not
    // inflate the "My booking(s)" badge on the main screen.
    setState(() => _myRequestCount = entries.where((e) => !e.isPast).length);
  }

  /// Pre-fills the number the rider last found their seat with, so the bar
  /// opens one tap away from the answer instead of on an empty field.
  ///
  /// [overwrite] is set when returning from the lookup screen: the rider may
  /// have found their seat under a DIFFERENT number there, and only a number
  /// that actually resolved is ever remembered — so it beats whatever is
  /// sitting in the field.
  Future<void> _loadRememberedPhone({bool overwrite = false}) async {
    final remembered = await _store.lastSeatLookupPhone();
    if (!mounted || remembered == null) return;
    if (overwrite || _phoneCtrl.text.isEmpty) {
      _phoneCtrl.text = remembered;
    }
    // A rider who already found their seat is on a bus. Ask this phone to
    // share its precise location so the office is not depending on one admin.
    unawaited(CrowdLocationShare.offer(context, _phoneCtrl.text));
  }

  void _toggleFind() {
    HapticFeedback.selectionClick();
    setState(() => _findOpen = !_findOpen);
    if (_findOpen) {
      _phoneFocus.requestFocus();
    } else {
      _phoneFocus.unfocus();
    }
  }

  /// Hands whatever is in the field to the lookup screen, which validates it,
  /// runs the search and draws the chart. Deliberately forgiving about an
  /// empty or half-typed number: the screen simply opens focused on the field,
  /// so a mistap still lands somewhere useful instead of on an error.
  Future<void> _openFindMySeat() async {
    HapticFeedback.selectionClick();
    _phoneFocus.unfocus();
    await Get.to(
      () => FindMySeatScreen(initialPhone: _phoneCtrl.text.trim()),
      transition: Transition.cupertino,
    );
    if (!mounted) return;
    setState(() => _findOpen = false);
    // The rider may have looked up a different number while they were there.
    _loadRememberedPhone(overwrite: true);
  }

  Future<void> _openMyRequests() async {
    HapticFeedback.selectionClick();
    await Get.to(
      () => const CustomerMyRequestsScreen(),
      transition: Transition.cupertino,
    );
    // Status/count may have changed (edits, refreshed statuses) — re-read.
    _loadRequestCount();
  }

  void _openMore() {
    HapticFeedback.selectionClick();
    Get.to(() => const CustomerMoreScreen(), transition: Transition.cupertino);
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);
    // There is NO dock on the customer surface (this route has no
    // bottomNavigationBar), so the list used to reserve `dockClearance` — 140 px
    // — of bottom padding for a bar that does not exist. On a two-tour list that
    // is most of the empty half of the screen. All the list actually needs is
    // clearance for the system nav bar, which `SafeArea(bottom: false)` above
    // deliberately does not consume so the scroll can run under it.
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + UgamSpacing.xl;

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              c: c,
              myRequestCount: _myRequestCount,
              onMyRequests: _openMyRequests,
              onMore: _openMore,
            ),
            _FindMySeatBar(
              c: c,
              open: _findOpen,
              controller: _phoneCtrl,
              focusNode: _phoneFocus,
              onToggle: _toggleFind,
              onSubmit: _openFindMySeat,
            ),
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return const _LoadingList();
                }
                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  return _refreshable(
                    c,
                    tourCtrl,
                    UgamEmpty(
                      icon: Icons.cloud_off_rounded,
                      title: tr('customer_tour_list.error_title'),
                      body: tourCtrl.errorMessage.value,
                      cta: UgamCTA(
                        label: tr('app.action.retry'),
                        leadingIcon: Icons.refresh_rounded,
                        onPressed: tourCtrl.refreshTours,
                      ),
                    ),
                  );
                }

                final visible = _visibleTours(tourCtrl.tours);

                if (visible.isEmpty) {
                  return _refreshable(
                    c,
                    tourCtrl,
                    UgamEmpty(
                      icon: Icons.event_busy_rounded,
                      title: tr('customer_tour_list.empty_title'),
                      // The subtitle answers "so what do I do?" — the
                      // pull-to-refresh line described a gesture the customer
                      // could not see and left the page with no action at all.
                      body: tr('customer_tour_list.empty_subtitle'),
                      cta: UgamCTA(
                        label: tr('app.action.refresh'),
                        leadingIcon: Icons.refresh_rounded,
                        onPressed: tourCtrl.refreshTours,
                      ),
                    ),
                  );
                }

                final groups = _group(visible);

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  color: c.ink2,
                  onRefresh: tourCtrl.refreshTours,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                      UgamSpacing.gutter,
                      bottomInset,
                    ),
                    // +1 for the server-driven content slot at the top. It
                    // renders zero-height when there is nothing to show, which
                    // is the normal state, so the list looks untouched unless
                    // content has actually been published.
                    itemCount: groups.length + 1,
                    itemBuilder: (_, index) {
                      if (index == 0) {
                        return const ContentSlot(
                          ContentSlots.customerTourListTop,
                        );
                      }
                      final i = index - 1;
                      final g = groups[i];
                      if (g.tours.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: i == groups.length - 1 ? 0 : UgamSpacing.xl,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _GroupHeader(
                              label: g.label,
                              count: g.tours.length,
                              c: c,
                            ),
                            const SizedBox(height: UgamSpacing.md),
                            for (final (j, t) in g.tours.indexed) ...[
                              _TourRow(
                                tour: t,
                                c: c,
                                onTap: () => Get.to(
                                  () => CustomerTourDetailScreen(tour: t),
                                  transition: Transition.cupertino,
                                ),
                                // One-tap "Book": jump straight to the booking
                                // step, collapsing list → detail → form to a
                                // single nav. Row tap still opens detail.
                                // Chart-mode tours go to the seat chart
                                // instead of the request form — otherwise this
                                // shortcut silently bypasses the new flow.
                                onBook: () {
                                  HapticFeedback.selectionClick();
                                  Get.to(
                                    () => t.bookingMode.isChart
                                        ? PartyGateScreen(tour: t)
                                        : CustomerBookingRequestScreen(tour: t),
                                    transition: Transition.cupertino,
                                  );
                                },
                              ),
                              if (j != g.tours.length - 1)
                                const SizedBox(height: UgamSpacing.tight),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Wraps a centered empty/error state in a pull-to-refresh scrollable so
  /// the customer can always retry the fetch — even when the list is empty
  /// and there's otherwise nothing to pull on.
  Widget _refreshable(UgamColorSet c, TourController tourCtrl, Widget child) {
    return RefreshIndicator(
      // Chrome, not ownership — the pull spinner is neutral ink2 in every
      // screen, so it never changes hue between tabs.
      color: c.ink2,
      onRefresh: tourCtrl.refreshTours,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        ),
      ),
    );
  }

  /// Public + non-completed, visible until the whole trip is over.
  ///
  /// A customer keeps seeing a tour until its END date passes — the end is the
  /// return date when there is one, otherwise the departure date. This mirrors
  /// the admin-side archive cutoff in TourController (`returnDate ?? departureDate`)
  /// so a round trip that departed yesterday but returns next week stays visible.
  List<Tour> _visibleTours(List<Tour> all) {
    final today = DateTime.now();
    final cutoff = DateTime(today.year, today.month, today.day);
    return all
        .where(
          (t) =>
              t.isPublic &&
              t.status != TourStatus.completed &&
              !(t.returnDate ?? t.departureDate).isBefore(cutoff),
        )
        .toList();
  }

  List<_Group> _group(List<Tour> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOf30 = today.add(const Duration(days: 30));

    final upcoming = <Tour>[];
    final later = <Tour>[];

    for (final t in all) {
      if (!t.departureDate.isAfter(endOf30)) {
        upcoming.add(t);
      } else {
        later.add(t);
      }
    }

    int byDate(Tour a, Tour b) => a.departureDate.compareTo(b.departureDate);
    upcoming.sort(byDate);
    later.sort(byDate);

    return [
      _Group(tr('customer_tour_list.group_upcoming'), upcoming),
      _Group(tr('customer_tour_list.group_later'), later),
    ];
  }
}

class _Group {
  final String label;
  final List<Tour> tours;
  _Group(this.label, this.tours);
}
