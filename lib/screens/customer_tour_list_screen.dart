import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/content_block_view.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../services/customer_requests_store.dart';
import '../utils/time_format.dart';
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
    final size = UgamScale.tap(context, 44);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
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
                  // The one amber on this screen's chrome, and it earns it:
                  // the badge counts the bookings that are LITERALLY yours,
                  // which is the whole definition of the accent.
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
                      fontWeight: FontWeight.w700,
                      // Line-height, not a size override: a single digit has to
                      // sit dead-centre in an 18 px circle.
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
/// The medallion is NEUTRAL, not amber. Nothing is selected or owned yet — this
/// is a doorway, and the accent means "this is yours", never "press me". The
/// only amber above the fold is the my-bookings count, which is a real
/// ownership claim. The Find button is [UgamColorSet.action] for the same
/// reason: a control asking to be pressed never spends the brand hue.
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
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.tight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: UgamScale.tap(context, 44),
                ),
                child: Row(
                  children: [
                    Container(
                      width: UgamScale.px(context, 40),
                      height: UgamScale.px(context, 40),
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        borderRadius: BorderRadius.circular(UgamRadius.input),
                      ),
                      alignment: Alignment.center,
                      child: Icon(kFindMySeatIcon, size: 20, color: c.ink2),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('find_seat.title'),
                            style: UgamText.titleS.copyWith(color: c.ink),
                          ),
                          const SizedBox(height: 2),
                          // Wraps rather than ellipsing. The Gujarati is
                          // "બુકિંગ થઈ ગયું છે? તમારી સીટ જુઓ" — ~30% longer
                          // than the English, and a one-line clamp cut it at
                          // the question mark, which is the half that explains
                          // who the bar is for.
                          Text(
                            tr('find_seat.home_subtitle'),
                            style: UgamText.caption.copyWith(color: c.ink2),
                            maxLines: 2,
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
            ),
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              alignment: Alignment.topCenter,
              child: open
                  ? Padding(
                      padding: const EdgeInsets.only(top: UgamSpacing.tight),
                      // 2:1. The button is FLEXIBLE, not natural-width: a
                      // trailing child sized to its own content is unbounded in
                      // a Row, so a long translation of "Find" would push the
                      // number field off the card instead of shrinking itself.
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Container(
                              height: UgamScale.tap(context, 44),
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
                                        UgamText.body.copyWith(color: c.ink),
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        hintText: tr('find_seat.phone_hint'),
                                        hintStyle: UgamText.body.copyWith(
                                          color: c.ink3,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.sm),
                          Flexible(
                            child: GestureDetector(
                              onTap: onSubmit,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                height: UgamScale.tap(context, 44),
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
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
        Flexible(
          child: Text(
            label,
            style: UgamText.titleM.copyWith(color: c.ink),
            maxLines: 2,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.badgeH,
            vertical: UgamSpacing.badgeV,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            '$count',
            style: UgamText.tabular(UgamText.micro.copyWith(color: c.ink2)),
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
    final meta = _metaLine(tour, includeTime: hasPhoto);
    final description = (tour.description ?? '').trim();
    final blurb = description.isEmpty ? null : description;

    return UgamCard.plain(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(UgamRadius.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // TWO different headers, and which one you get depends on whether
            // there is anything real to show.
            //
            // With a photo: the organiser's own broadcast image — the same one
            // that goes out on WhatsApp, and the reason a customer recognises
            // the trip. It earns 148 px.
            //
            // Without one: a ROUTE BOARD, not a placeholder. The old row filled
            // the same 148 px with a generated graphite gradient, which is
            // indistinguishable from an image that failed to load and tells the
            // customer nothing. The board spends that space on the two facts
            // they are actually scanning for — where it goes and when it leaves.
            if (hasPhoto)
              _PhotoBanner(tour: tour, decodeWidth: _decodeWidth(context))
            else
              _RouteBoard(tour: tour, c: c),
            Padding(
              padding: const EdgeInsets.all(UgamSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tour.title,
                    style: UgamText.titleM.copyWith(color: c.ink),
                    // Two lines: these titles carry the festival name AND the
                    // date, and one line cut every one of them mid-word.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The route only belongs here on the photo variant — the
                  // board already states it, and saying it twice in one card
                  // is what the detail page was cleaned up for.
                  if (hasPhoto) ...[
                    const SizedBox(height: 3),
                    Text(
                      // No leading arrow icon. A south-east glyph next to a
                      // route encodes nothing — the "→" between the cities
                      // already says which way the bus goes.
                      '${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 2,
                    ),
                  ],
                  // A two-line teaser of the organiser's own blurb. The field
                  // was already fetched and only ever read on the detail page,
                  // so the card threw away the one thing that says what the
                  // trip actually IS. Omitted entirely when unset — never a
                  // reserved blank.
                  if (blurb != null) ...[
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      blurb,
                      style: UgamText.body.copyWith(color: c.ink2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (meta != null) ...[
                    const SizedBox(height: UgamSpacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: c.ink3,
                          ),
                        ),
                        const SizedBox(width: 5),
                        // Departure time and the return date — both already on
                        // the model, both previously thrown away, and both the
                        // first thing anyone asks about a trip.
                        Expanded(
                          child: Text(
                            meta,
                            style: UgamText.tabular(
                              UgamText.caption.copyWith(color: c.ink2),
                            ),
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: UgamSpacing.md),
                  // Both sides are flexible and the free space goes BETWEEN
                  // them, so the pill stays pinned right while neither child
                  // can push the other off the card. A trailing widget sized to
                  // its own natural width is unbounded in a Row: one long
                  // translation of "Book" and the countdown silently clips.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // No price. It is withheld on the detail page — the fare
                      // is settled over WhatsApp — and a figure here would
                      // contradict that the moment the customer taps through.
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: UgamSpacing.sm),
                          child: countdown == null
                              ? const SizedBox.shrink()
                              : Text(
                                  countdown,
                                  style: UgamText.tabular(
                                    UgamText.caption.copyWith(color: c.ink3),
                                  ),
                                  maxLines: 2,
                                ),
                        ),
                      ),
                      // One-tap Book pill — jumps straight to the booking step,
                      // collapsing list → detail → form to a single nav. Its
                      // own gesture, so it doesn't bubble to tap-to-detail.
                      Flexible(child: _BookPill(c: c, closed: closed, onTap: onBook)),
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

  /// The secondary facts line: departure time · return date. Null when the
  /// organiser has recorded neither, so the row simply omits it rather than
  /// reserving space for a blank.
  ///
  /// Both values come straight off [Tour] and were already fetched — the row
  /// just never rendered them, which is a large part of why a card that was
  /// mostly grey block had so little to say.
  ///
  /// [includeTime] is false on the no-photo variant, where [_RouteBoard] has
  /// already stated the departure time next to the route.
  static String? _metaLine(Tour tour, {required bool includeTime}) {
    final parts = <String>[
      if (includeTime) ?formatHhMm(tour.departureTime),
      if (tour.returnDate != null)
        tr(
          'customer_tour_list.returns_on',
          namedArgs: {'date': _formatDate(tour.returnDate!)},
        ),
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  /// `12 Sep` in the active locale.
  ///
  /// No `.toUpperCase()`: Gujarati and Hindi have no case, so it did nothing at
  /// all on the primary language and only ever styled the English build.
  static String _formatDate(DateTime d) => '${d.day} ${_monthShort(d.month)}';

  /// Localized 3-letter month abbreviation.
  static String _monthShort(int month) {
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
    return tr(keys[month - 1]);
  }
}

/// The organiser's broadcast photo, with the departure date badged over it.
///
/// Falls back to [UgamBusBackdrop] only while the image is in flight or when
/// the object is missing — never as the resting state, which is exactly the
/// "unloaded image" read the row used to ship by default.
class _PhotoBanner extends StatelessWidget {
  final Tour tour;
  final int decodeWidth;

  const _PhotoBanner({required this.tour, required this.decodeWidth});

  @override
  Widget build(BuildContext context) {
    final fallback = UgamBusBackdrop(
      seed: tour.id,
      label: _routeInitials(tour.fromCity, tour.toCity),
    );
    return SizedBox(
      height: UgamScale.px(context, 148),
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            tour.broadcastImageUrl!.trim(),
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            loadingBuilder: (ctx, child, progress) =>
                progress == null ? child : fallback,
            errorBuilder: (_, _, _) => fallback,
          ),
          // Scrim top and bottom only — enough to hold the date badge over any
          // photo without flattening it. These four values are NOT theme
          // colours and deliberately have no token: the badge floats on an
          // arbitrary uploaded image, so its contrast can't come from the page.
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
              label: _TourRow._formatDate(tour.departureDate),
            ),
          ),
        ],
      ),
    );
  }
}

/// The header for a tour with no photo: a date medallion beside the route.
///
/// This is the replacement for the generated grey gradient. Every pixel of it
/// is a fact the customer came for, it needs no network, and it cannot be
/// mistaken for a broken image.
class _RouteBoard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _RouteBoard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final side = UgamScale.px(context, 58);
    return Container(
      width: double.infinity,
      color: c.cardElev,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${tour.departureDate.day}',
                  style: UgamText.tabular(
                    UgamText.numLg.copyWith(color: c.ink),
                  ),
                ),
                const SizedBox(height: 2),
                // caption, not micro: micro's 1.4 letter-spacing pulls a
                // Gujarati month ("સપ્ટે") apart at the conjuncts and pushes it
                // past the medallion.
                Text(
                  _TourRow._monthShort(tour.departureDate.month),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Wraps to a second line rather than ellipsing — a route is the
                // one fact on the card that must READ, and Gujarati city names
                // ("અમદાવાદ → અંબાજી") are long.
                Text(
                  '${tour.fromCity} → ${tour.toCity}',
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                // The departure time sits here, where a real departure board
                // puts it — beside the route, under the date. On the photo
                // variant there is no board, so it moves into the meta line
                // below instead; it is never shown twice.
                if (formatHhMm(tour.departureTime) case final time?) ...[
                  const SizedBox(height: 3),
                  Text(
                    time,
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink2),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small label that sits ON the card banner — the date, or the closed state.
///
/// Uses its own dark scrim and white ink rather than the theme's chip colours:
/// the badge floats over an arbitrary photo, so it cannot rely on the page
/// background for contrast the way `UgamReqChip` does.
class _BannerBadge extends StatelessWidget {
  final String label;

  const _BannerBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(
        label,
        style: UgamText.tabular(
          UgamText.caption.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
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
///
/// Once the tour is locked there is no tappable affordance at all — it becomes
/// a warm CLOSED chip. That replaced a 30 px lock circle, which was both under
/// the 44 pt tap floor (while looking pressable) and mute: a padlock glyph does
/// not say whether the bus left, filled up, or was cancelled, and the word does.
class _BookPill extends StatelessWidget {
  final UgamColorSet c;
  final bool closed;
  final VoidCallback onTap;

  const _BookPill({required this.c, required this.closed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (closed) {
      return UgamReqChip(
        label: tr('customer_tour_list.chip_closed'),
        variant: UgamChipVariant.warm,
        leading: Icons.lock_outline_rounded,
      );
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: UgamScale.tap(context, 44),
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
        alignment: Alignment.center,
        // No hand-rolled shadow. The card this sits in is already at
        // UgamElevationSet.rest; a second, differently-tuned drop shadow on a
        // chip inside it read as a floating blob rather than depth.
        decoration: BoxDecoration(
          // Neutral, not amber: the accent means "this is yours", never
          // "press me". Uber's buttonPrimaryFill is #000000 and Ola ships a
          // black booking button despite a green brand — spending the brand
          // hue on controls is what leaves nothing to carry meaning.
          color: c.action,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                tr('customer_tour_list.book_button'),
                style: UgamText.bodyStrong.copyWith(color: c.onAction),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_rounded, size: 15, color: c.onAction),
          ],
        ),
      ),
    );
  }
}

/// First-load state: the finished page with the words taken out.
///
/// Every block is the size and position of the thing that replaces it, so the
/// list does not jump when the tours land. The old version stacked three flat
/// 110 px bars — less than half the height of a real row — so the page visibly
/// re-laid itself out on arrival, which is the "prototype" tell.
class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 22, width: 128, radius: 6),
        SizedBox(height: UgamSpacing.md),
        _TourRowSkeleton(),
        SizedBox(height: UgamSpacing.tight),
        _TourRowSkeleton(),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 22, width: 96, radius: 6),
        SizedBox(height: UgamSpacing.md),
        _TourRowSkeleton(),
      ],
    );
  }
}

/// One [_TourRow] with its content greyed out — route board, title, meta line
/// and the Book pill, each in its final place.
class _TourRowSkeleton extends StatelessWidget {
  const _TourRowSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UgamSpacing.md),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(UgamRadius.card),
              ),
            ),
            child: Row(
              children: [
                UgamSkeleton(
                  width: UgamScale.px(context, 58),
                  height: UgamScale.px(context, 58),
                  radius: UgamRadius.input,
                ),
                const SizedBox(width: UgamSpacing.md),
                const Expanded(child: UgamSkeleton(height: 18, radius: 6)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(UgamSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const UgamSkeleton(height: 17, radius: 6),
                const SizedBox(height: UgamSpacing.sm),
                const UgamSkeleton(height: 13, width: 190, radius: 6),
                const SizedBox(height: UgamSpacing.md),
                Row(
                  children: [
                    const UgamSkeleton(height: 13, width: 104, radius: 6),
                    const Spacer(),
                    UgamSkeleton(
                      width: 96,
                      height: UgamScale.tap(context, 44),
                      radius: UgamRadius.chip,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
