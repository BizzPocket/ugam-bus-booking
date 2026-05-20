import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
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
              onFilter: () {
                HapticFeedback.selectionClick();
                // Future: open a filter sheet (date / price band / city).
              },
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
                  return UgamEmpty(
                    icon: Icons.cloud_off_rounded,
                    title: tr('customer_tour_list.error_title'),
                    body: tourCtrl.errorMessage.value,
                    cta: UgamCTA(
                      label: tr('app.action.retry'),
                      leadingIcon: Icons.refresh_rounded,
                      onPressed: tourCtrl.refreshTours,
                    ),
                  );
                }

                final visible = _visibleTours(tourCtrl.tours);

                if (visible.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.event_busy_rounded,
                    title: 'No upcoming tours',
                    body: 'Pull down to refresh — new trips appear here.',
                  );
                }

                final groups = _group(visible);
                final hasMatches = groups.any((g) => g.tours.isNotEmpty);

                if (_query.isNotEmpty && !hasMatches) {
                  return UgamEmpty(
                    icon: Icons.search_off_rounded,
                    title: 'No matches',
                    body: 'No tours match "$_query".',
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
                                      tour: g.tours[j]),
                                  transition: Transition.cupertino,
                                ),
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

  /// Public + non-completed, future-dated only.
  List<Tour> _visibleTours(List<Tour> all) {
    final today = DateTime.now();
    final cutoff = DateTime(today.year, today.month, today.day);
    return all
        .where((t) =>
            t.isPublic &&
            t.status != TourStatus.completed &&
            !t.departureDate.isBefore(cutoff))
        .toList();
  }

  List<_Group> _group(List<Tour> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOf30 = today.add(const Duration(days: 30));

    final filtered = _query.isEmpty
        ? all
        : all
            .where((t) =>
                t.title.toLowerCase().contains(_query.toLowerCase()) ||
                t.fromCity.toLowerCase().contains(_query.toLowerCase()) ||
                t.toCity.toLowerCase().contains(_query.toLowerCase()))
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
      _Group('Upcoming', upcoming),
      _Group('Later', later),
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
  final VoidCallback onFilter;

  const _TopBar({
    required this.c,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onFilter,
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
            child: Text(
              'Explore tours',
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 28),
            ),
          ),
          _IconCircle(
            icon:
                searchActive ? Icons.close_rounded : Icons.search_rounded,
            c: c,
            onTap: onToggleSearch,
            active: searchActive,
          ),
          const SizedBox(width: UgamSpacing.sm),
          _IconCircle(
            icon: Icons.tune_rounded,
            c: c,
            onTap: onFilter,
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
  const _IconCircle({
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
                  hintText: 'Search by route or destination…',
                  hintStyle:
                      UgamText.body.copyWith(color: c.ink3, fontSize: 14),
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
        Text(label,
            style: UgamText.titleM.copyWith(color: c.ink, fontSize: 16)),
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

  const _TourRow({
    required this.tour,
    required this.c,
    required this.onTap,
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
                        UgamBusBackdrop(seed: tour.id),
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _formatDate(tour.departureDate),
                              style: UgamText.tabular(
                                UgamText.micro.copyWith(
                                  color: Colors.white,
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
                        style: UgamText.titleS
                            .copyWith(color: c.ink, fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.south_east_rounded,
                              size: 12, color: c.ink2),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${tour.fromCity} → ${tour.toCity}',
                              style: UgamText.caption
                                  .copyWith(color: c.ink2, fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: UgamSpacing.sm + 2),
                      Row(
                        children: [
                          if (hasCapacity)
                            UgamReqChip(
                              label: seatsLeft <= 0
                                  ? 'FULL'
                                  : '$seatsLeft LEFT',
                              variant: seatsLeft <= 0
                                  ? UgamChipVariant.warm
                                  : UgamChipVariant.good,
                            )
                          else
                            const UgamReqChip(
                              label: 'OPEN',
                              variant: UgamChipVariant.neutral,
                            ),
                          const SizedBox(width: 5),
                          UgamReqChip(
                            label:
                                'FROM ₹${tour.pricePerSeat.toStringAsFixed(0)}',
                            variant: UgamChipVariant.accent,
                          ),
                          const Spacer(),
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(Icons.arrow_forward_rounded,
                                size: 14, color: c.accent),
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
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
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
