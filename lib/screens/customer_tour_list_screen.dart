import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../utils/formatters.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../services/customer_requests_store.dart';
import 'customer_booking_request_screen.dart';
import 'customer_more_screen.dart';
import 'customer_my_requests_screen.dart';
import 'customer_tour_detail_screen.dart';

/// Public-facing tour list — image-5 fidelity.
///
/// Layout:
///   [Title row + circle search + circle filter]
///   [Search field (collapsible)]
///   [Group: Upcoming]
///   [Group: Later]
///
/// Visually mirrors the admin `tours_screen.dart`: photo-anchored 88-px
/// rows with backdrop thumbnail + route header + date pill + chips. No
/// "+" button — customers don't create tours. No "Past" group — customers
/// don't need history.
class CustomerTourListScreen extends StatefulWidget {
  const CustomerTourListScreen({super.key});

  @override
  State<CustomerTourListScreen> createState() => _CustomerTourListScreenState();
}

class _CustomerTourListScreenState extends State<CustomerTourListScreen> {
  final _searchCtrl = TextEditingController();
  bool _searchVisible = false;
  String _query = '';
  int _myRequestCount = 0;

  @override
  void initState() {
    super.initState();
    _loadRequestCount();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Reads the device-local journal of submitted requests (cheap cached
  /// read — no network) so the top-bar badge reflects how many bookings
  /// the customer can track.
  Future<void> _loadRequestCount() async {
    final entries = await CustomerRequestsStore().list();
    if (!mounted) return;
    setState(() => _myRequestCount = entries.length);
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

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              c: c,
              searchActive: _searchVisible,
              onToggleSearch: _toggleSearch,
              myRequestCount: _myRequestCount,
              onMyRequests: _openMyRequests,
              onMore: _openMore,
            ),
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              child: _searchVisible
                  ? _SearchField(
                      c: c,
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _query = v.trim()),
                    )
                  : const SizedBox.shrink(),
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
                final hasMatches = groups.any((g) => g.tours.isNotEmpty);

                if (_query.isNotEmpty && !hasMatches) {
                  return _refreshable(
                    c,
                    tourCtrl,
                    UgamEmpty(
                      icon: Icons.search_off_rounded,
                      title: tr('customer_tour_list.no_matches_title'),
                      body: tr(
                        'customer_tour_list.no_matches_body',
                        namedArgs: {'q': _query},
                      ),
                    ),
                  );
                }

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
                      140,
                    ),
                    itemCount: groups.length,
                    itemBuilder: (_, i) {
                      final g = groups[i];
                      if (g.tours.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: i == groups.length - 1 ? 0 : UgamSpacing.lg,
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
                                // form, collapsing list → detail → form to a
                                // single nav. Row tap still opens detail.
                                onBook: () {
                                  HapticFeedback.selectionClick();
                                  Get.to(
                                    () => CustomerBookingRequestScreen(
                                      tour: g.tours[j],
                                    ),
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

    final filtered = _query.isEmpty
        ? all
        : all
              .where(
                (t) =>
                    t.title.toLowerCase().contains(_query.toLowerCase()) ||
                    t.fromCity.toLowerCase().contains(_query.toLowerCase()) ||
                    t.toCity.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    final upcoming = <Tour>[];
    final later = <Tour>[];

    for (final t in filtered) {
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
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback onMore;
  final VoidCallback onMyRequests;
  final int myRequestCount;

  const _TopBar({
    required this.c,
    required this.searchActive,
    required this.onToggleSearch,
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
                style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 28),
              ),
            ),
          ),
          Tooltip(
            message: tr('customer_tour_list.my_requests_tooltip'),
            child: _IconCircle(
              icon: Icons.confirmation_number_outlined,
              c: c,
              onTap: onMyRequests,
              badgeCount: myRequestCount,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          _IconCircle(
            icon: searchActive ? Icons.close_rounded : Icons.search_rounded,
            c: c,
            onTap: onToggleSearch,
            active: searchActive,
          ),
          const SizedBox(width: UgamSpacing.sm),
          Tooltip(
            message: tr('customer_more.title'),
            child: _IconCircle(icon: Icons.menu_rounded, c: c, onTap: onMore),
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
  final bool active;

  /// When > 0, paints an accent badge in the top-right corner.
  final int badgeCount;

  const _IconCircle({
    required this.icon,
    required this.c,
    required this.onTap,
    this.active = false,
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
              color: active ? c.accentFill : c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 19, color: active ? c.accent : c.ink),
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

class _SearchField extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.c,
    required this.controller,
    required this.onChanged,
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
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: c.ink2),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: tr('customer_tour_list.search_hint'),
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
          style: UgamText.titleM.copyWith(color: c.ink, fontSize: 16),
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

  @override
  Widget build(BuildContext context) {
    final capacity = tour.totalBusSeats;
    final assigned = tour.totalSeatsAssigned;
    final seatsLeft = capacity - assigned;
    final hasCapacity = capacity > 0;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Photo-anchored 88-px thumbnail with date pill overlay.
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 96,
                    height: 88,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        UgamBusBackdrop(
                          seed: tour.id,
                          label: _routeInitials(tour.fromCity, tour.toCity),
                        ),
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.cardElev,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _formatDate(tour.departureDate),
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
                        tour.title,
                        style: UgamText.titleS.copyWith(
                          color: c.ink,
                          fontSize: 15,
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
                              '${tour.fromCity} → ${tour.toCity}',
                              style: UgamText.caption.copyWith(
                                color: c.ink2,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (tour.pricePerSeat > 0) ...[
                            const SizedBox(width: UgamSpacing.sm),
                            Text(
                              '·',
                              style: UgamText.caption.copyWith(
                                color: c.ink3,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: UgamSpacing.sm),
                            Text(
                              tr(
                                'customer_tour_list.price_per_seat',
                                namedArgs: {
                                  'price': Formatters.formatMoneyInr(
                                    tour.pricePerSeat,
                                  ).replaceFirst('₹', ''),
                                },
                              ),
                              style: UgamText.tabular(
                                UgamText.caption.copyWith(
                                  color: c.ink2,
                                  fontSize: 12,
                                ),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: UgamSpacing.sm + 2),
                      Row(
                        children: [
                          if (hasCapacity)
                            UgamReqChip(
                              label: seatsLeft <= 0
                                  ? tr('customer_tour_list.chip_full')
                                  : tr(
                                      'customer_tour_list.chip_left',
                                      namedArgs: {'n': seatsLeft.toString()},
                                    ),
                              variant: seatsLeft <= 0
                                  ? UgamChipVariant.warm
                                  : UgamChipVariant.good,
                            )
                          else
                            UgamReqChip(
                              label: tr('customer_tour_list.chip_open'),
                              variant: UgamChipVariant.neutral,
                            ),
                          const Spacer(),
                          // One-tap Book pill — jumps straight to the booking
                          // form (skips the detail screen). Has its own gesture
                          // so it doesn't bubble up to the row's tap-to-detail.
                          // Reads as a non-actionable arrow when the bus is full.
                          _BookPill(
                            c: c,
                            full: hasCapacity && seatsLeft <= 0,
                            closed: !tour.acceptsBookings,
                            onTap: onBook,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
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
          color: c.accent,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr('customer_tour_list.book_button'),
              style: UgamText.bodyStrong.copyWith(
                color: c.onAccent,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_forward_rounded, size: 13, color: c.onAccent),
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
        UgamSkeleton(height: 110, radius: 20),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 110, radius: 20),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 28, width: 120, radius: 8),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: 20),
      ],
    );
  }
}
