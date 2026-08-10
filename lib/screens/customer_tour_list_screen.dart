import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../services/customer_requests_store.dart';
import 'customer_booking_request_screen.dart';
import 'customer_more_screen.dart';
import 'customer_my_requests_screen.dart';
import 'customer_tour_detail_screen.dart';
import 'find_my_seat_screen.dart';
import 'party_gate_screen.dart';

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
    if (!overwrite && _phoneCtrl.text.isNotEmpty) return;
    _phoneCtrl.text = remembered;
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
                  return _LoadingShimmer();
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
                      body: tr('customer_tour_list.pull_to_refresh'),
                    ),
                  );
                }

                final groups = _group(visible);

                return RefreshIndicator(
                  color: c.accent,
                  onRefresh: tourCtrl.refreshTours,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                      UgamSpacing.gutter,
                      UgamSpacing.dockClearance,
                    ),
                    itemCount: groups.length,
                    itemBuilder: (_, i) {
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
                            for (var j = 0; j < g.tours.length; j++) ...[
                              _TourRow(
                                tour: g.tours[j],
                                c: c,
                                onTap: () => Get.to(
                                  () => CustomerTourDetailScreen(
                                    tour: g.tours[j],
                                  ),
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
                                  final t = g.tours[j];
                                  Get.to(
                                    () => t.bookingMode.isChart
                                        ? PartyGateScreen(tour: t)
                                        : CustomerBookingRequestScreen(tour: t),
                                    transition: Transition.cupertino,
                                  );
                                },
                              ),
                              if (j != g.tours.length - 1)
                                const SizedBox(height: UgamSpacing.sm + 2),
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
      color: c.accent,
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

// ─── widget pieces ────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onMore;
  final VoidCallback onMyRequests;
  final int myRequestCount;

  const _TopBar({
    required this.c,
    required this.onMore,
    required this.onMyRequests,
    required this.myRequestCount,
  });

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
          Expanded(
            // Discreet, customer-invisible admin entry: long-press the
            // title to open the (otherwise unlinked) login route.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () {
                HapticFeedback.mediumImpact();
                Get.toNamed(AppRoutes.login);
              },
              child: Text(
                tr('customer_tour_list.header_explore'),
                style: UgamText.titleXl.copyWith(color: c.ink),
              ),
            ),
          ),
          Tooltip(
            message: tr('customer_tour_list.my_requests_tooltip'),
            child: _IconCircle(
              // Filled, not outlined. At 19 px the outlined ticket read as a
              // generic rounded rectangle; the solid one is unmistakably a
              // ticket stub, which is what "my bookings" is.
              icon: Icons.confirmation_number_rounded,
              c: c,
              onTap: onMyRequests,
              badgeCount: myRequestCount,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Tooltip(
            message: tr('customer_more.title'),
            // Not a hamburger. Three stacked lines promise a slide-out drawer,
            // and this app has none — the icon opens a short pushed list whose
            // title is literally "More", so the ellipsis is the honest glyph.
            child: _IconCircle(
              icon: Icons.more_horiz_rounded,
              c: c,
              onTap: onMore,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconCircle extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;

  /// When > 0, paints an accent badge in the top-right corner.
  final int badgeCount;

  const _IconCircle({
    required this.icon,
    required this.c,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 19, color: c.ink),
          ),
          if (badgeCount > 0)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.bg, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  badgeCount > 9 ? '9+' : '$badgeCount',
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(
                      color: c.onAccent,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Find my seat", promoted out of the More menu and onto the first screen.
///
/// Sits collapsed as one prompt line — a returning rider recognises it without
/// reading, a first-time visitor loses ~56 px of tour list to it. Tapping it
/// opens the number field IN PLACE; the actual lookup, its errors and the
/// chart all stay in [FindMySeatScreen], so there is exactly one implementation
/// of the flow and this bar is only its doorway.
///
/// The seat tile is accent-filled because a seat you hold is the canonical
/// "this is yours"; the Find button is [UgamColorSet.action], because a control
/// asking to be pressed never spends the brand hue.
class _FindMySeatBar extends StatelessWidget {
  final UgamColorSet c;
  final bool open;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onToggle;
  final VoidCallback onSubmit;

  const _FindMySeatBar({
    required this.c,
    required this.open,
    required this.controller,
    required this.focusNode,
    required this.onToggle,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm + 2),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      borderRadius: BorderRadius.circular(UgamRadius.input),
                    ),
                    alignment: Alignment.center,
                    child: Icon(kFindMySeatIcon, size: 20, color: c.accent),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('find_seat.title'),
                          style: UgamText.titleS.copyWith(
                            color: c.ink,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          tr('find_seat.home_subtitle'),
                          style: UgamText.caption.copyWith(
                            color: c.ink3,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: c.ink3,
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              alignment: Alignment.topCenter,
              child: open
                  ? Padding(
                      padding: const EdgeInsets.only(top: UgamSpacing.sm + 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 44,
                              padding: const EdgeInsets.symmetric(
                                horizontal: UgamSpacing.md,
                              ),
                              decoration: BoxDecoration(
                                color: c.cardElev,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.chip,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.phone_iphone_rounded,
                                    size: 16,
                                    color: c.ink3,
                                  ),
                                  const SizedBox(width: UgamSpacing.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: controller,
                                      focusNode: focusNode,
                                      keyboardType: TextInputType.phone,
                                      textInputAction: TextInputAction.search,
                                      onSubmitted: (_) => onSubmit(),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'[0-9+ ]'),
                                        ),
                                      ],
                                      style: UgamText.tabular(
                                        UgamText.body.copyWith(
                                          color: c.ink,
                                          fontSize: 14,
                                        ),
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        hintText: tr('find_seat.phone_hint'),
                                        hintStyle: UgamText.body.copyWith(
                                          color: c.ink3,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.sm),
                          GestureDetector(
                            onTap: onSubmit,
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              height: 44,
                              padding: const EdgeInsets.symmetric(
                                horizontal: UgamSpacing.lg,
                              ),
                              decoration: BoxDecoration(
                                color: c.action,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.chip,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                tr('find_seat.home_action'),
                                style: UgamText.bodyStrong.copyWith(
                                  color: c.onAction,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _GroupHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: UgamText.titleM.copyWith(color: c.ink, fontSize: 17),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            '$count',
            style: UgamText.tabular(
              UgamText.micro.copyWith(color: c.ink2, fontSize: 10),
            ),
          ),
        ),
      ],
    );
  }
}

class _TourRow extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final VoidCallback onTap;
  final VoidCallback onBook;

  const _TourRow({
    required this.tour,
    required this.c,
    required this.onTap,
    required this.onBook,
  });

  /// Decode the banner at the width we paint, not the width uploaded. The
  /// picker stores at maxWidth 1600, so a full-bleed card banner would
  /// otherwise decode a ~6.8 MB bitmap PER ROW.
  static int _decodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final physical = (mq.size.width * mq.devicePixelRatio).round();
    if (physical <= 0) return 800;
    return physical > 1600 ? 1600 : physical;
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: there is deliberately no seats-left chip here any more. It read
    // `tour.totalBusSeats`, and `buses` has no anon SELECT policy — so on the
    // customer side that sum is ALWAYS 0, `hasCapacity` was always false, and
    // every row on every tour showed the same generic "open" chip. A count we
    // cannot know is worse than no count; the detail screen fetches the real
    // one through the public RPC and states it there.
    final closed = !tour.acceptsBookings;
    final countdown = departureCountdownLabel(tour.departureDate);
    final hasPhoto = (tour.broadcastImageUrl ?? '').trim().isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The banner. This is the organiser's own uploaded broadcast photo
            // — the same image that goes out on WhatsApp. The row used to draw
            // a 96×88 generated backdrop and ignore `broadcastImageUrl`
            // entirely, so a tour with a real photo still showed a placeholder
            // monogram. Full-bleed because the photo IS the reason a customer
            // recognises the trip.
            SizedBox(
              height: 148,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasPhoto)
                    Image.network(
                      tour.broadcastImageUrl!.trim(),
                      fit: BoxFit.cover,
                      cacheWidth: _decodeWidth(context),
                      loadingBuilder: (ctx, child, progress) => progress == null
                          ? child
                          : UgamBusBackdrop(
                              seed: tour.id,
                              label: _routeInitials(
                                tour.fromCity,
                                tour.toCity,
                              ),
                            ),
                      errorBuilder: (_, _, _) => UgamBusBackdrop(
                        seed: tour.id,
                        label: _routeInitials(tour.fromCity, tour.toCity),
                      ),
                    )
                  else
                    UgamBusBackdrop(
                      seed: tour.id,
                      label: _routeInitials(tour.fromCity, tour.toCity),
                    ),
                  // Scrim top and bottom only — enough to hold the date and
                  // status badges over any photo without flattening it.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x8C000000),
                          Color(0x00000000),
                          Color(0x00000000),
                          Color(0x66000000),
                        ],
                        stops: [0.0, 0.35, 0.65, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    left: UgamSpacing.tight,
                    top: UgamSpacing.tight,
                    child: _BannerBadge(
                      label: _formatDate(tour.departureDate),
                      tabular: true,
                    ),
                  ),
                  if (closed)
                    Positioned(
                      right: UgamSpacing.tight,
                      top: UgamSpacing.tight,
                      child: _BannerBadge(
                        label: tr('customer_tour_list.chip_closed'),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(UgamSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tour.title,
                    style: UgamText.titleS.copyWith(color: c.ink, fontSize: 16),
                    // Two lines: these titles carry the festival name AND the
                    // date, and one line cut every one of them mid-word.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    // No leading arrow icon. A south-east glyph next to a route
                    // encodes nothing — the "→" between the cities already says
                    // which way the bus goes.
                    '${tour.fromCity} → ${tour.toCity}',
                    style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  Row(
                    children: [
                      // No price. It is withheld on the detail page — the fare
                      // is settled over WhatsApp — and a figure here would
                      // contradict that the moment the customer taps through.
                      Expanded(
                        child: countdown == null
                            ? const SizedBox.shrink()
                            : Text(
                                countdown,
                                style: UgamText.tabular(
                                  UgamText.caption.copyWith(
                                    color: c.ink3,
                                    fontSize: 12,
                                  ),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      // One-tap Book pill — jumps straight to the booking step,
                      // collapsing list → detail → form to a single nav. Its
                      // own gesture, so it doesn't bubble to tap-to-detail.
                      _BookPill(
                        c: c,
                        full: false,
                        closed: closed,
                        onTap: onBook,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
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

/// A small label that sits ON the card banner — the date, or the closed state.
///
/// Uses its own dark scrim and white ink rather than the theme's chip colours:
/// the badge floats over an arbitrary photo, so it cannot rely on the page
/// background for contrast the way `UgamReqChip` does.
class _BannerBadge extends StatelessWidget {
  final String label;
  final bool tabular;

  const _BannerBadge({required this.label, this.tabular = false});

  @override
  Widget build(BuildContext context) {
    final style = UgamText.micro.copyWith(color: Colors.white, fontSize: 10.5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(label, style: tabular ? UgamText.tabular(style) : style),
    );
  }
}

/// Route monogram for the bus backdrop, e.g. "S→M" from "Surat"/"Mumbai".
/// Uses the first letter of each city; returns empty when neither is set so
/// the backdrop simply shows the bus motif.
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

/// Trailing "Book" pill on a tour row. Its own gesture (so it doesn't bubble up
/// to the row's tap-to-detail) takes the customer straight to the booking form.
/// When the bus is full it renders as a muted, non-actionable arrow chip, and
/// once the tour is locked it renders a non-actionable lock chip — in both
/// cases the row still opens detail, but there's no tappable "Book" affordance.
class _BookPill extends StatelessWidget {
  final UgamColorSet c;
  final bool full;
  final bool closed;
  final VoidCallback onTap;

  const _BookPill({
    required this.c,
    required this.full,
    required this.closed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (closed) {
      // Bookings closed (tour locked/completed) — no "Book" affordance; the
      // row still opens detail, which explains the closed state.
      return Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(Icons.lock_outline_rounded, size: 14, color: c.ink3),
      );
    }
    if (full) {
      // Non-actionable arrow — booking a full bus isn't offered from the row.
      return Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(Icons.arrow_forward_rounded, size: 14, color: c.ink3),
      );
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          // Neutral, not amber: the accent means "this is yours", never
          // "press me". Uber's buttonPrimaryFill is #000000 and Ola ships a
          // black booking button despite a green brand — spending the brand
          // hue on controls is what leaves nothing to carry meaning.
          color: c.action,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          boxShadow: [
            BoxShadow(
              // Was the amber glow, which read as a halo under a button that
              // is no longer amber. Separation is by hairline and contrast now.
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr('customer_tour_list.book_button'),
              style: UgamText.bodyStrong.copyWith(
                color: c.onAction,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_forward_rounded, size: 13, color: c.onAction),
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
        UgamSkeleton(height: 28, width: 120, radius: 8),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.sm + 2),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 28, width: 120, radius: 8),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
      ],
    );
  }
}
