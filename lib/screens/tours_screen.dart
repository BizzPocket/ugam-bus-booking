import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/formatters.dart';
import '../widgets/cached_data_banner.dart';
import 'create_tour_screen.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'seats_screen.dart';
import 'tour_detail_screen.dart';

part 'tours/tour_row.dart';
part 'tours/loading_shimmer.dart';

/// Tours tab — chronologically grouped instead of filter-pill-driven.
///
/// Why time-grouped: agents think in time ("this week's trips"), not in
/// status (collecting / busBooked / assigning). Status is encoded per
/// row via a status dot.
///
/// Layout:
///   [Title + circle "+" + search icon]
///   [Search bar (collapsible)]
///   [Group: This week]
///   [Group: Next 30 days]
///   [Group: Later]
///   [Group: Past (collapsed by default)]
class ToursScreen extends StatefulWidget {
  const ToursScreen({super.key});

  @override
  State<ToursScreen> createState() => _ToursScreenState();
}

class _ToursScreenState extends State<ToursScreen> {
  final _searchCtrl = TextEditingController();
  bool _searchVisible = false;
  String _query = '';

  /// "Past trips" section disclosure — collapsed by default so the browse
  /// view stays on upcoming work, but one tap away instead of search-only.
  bool _pastOpen = false;

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

  /// The one way into tour creation from this tab — shared by the app-bar
  /// action, every empty state's CTA and the list's tail button.
  void _openCreate(BuildContext context) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const CreateTourScreen()),
    );
  }

  /// Centred states (empty / error / no-match) fill the whole tab body, whose
  /// bottom ~80pt is covered by the floating dock. Reserving the same
  /// [UgamSpacing.dockClearance] the scrolling list reserves optically centres
  /// them in the area the agent can actually see, instead of parking the CTA
  /// behind the dock.
  Widget _dockSafe(Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: UgamSpacing.dockClearance),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              title: tr('tours.title'),
              showBack: false,
              actions: [
                UgamAppBarAction(
                  icon: _searchVisible
                      ? Icons.close_rounded
                      : Icons.search_rounded,
                  active: _searchVisible,
                  tooltip: tr('tours.search'),
                  onTap: _toggleSearch,
                ),
                // No `tint: c.accent` — tokens.dart reserves the amber for
                // "this is yours" (a selection / an owned row) and explicitly
                // NOT for controls. The create affordance is instead made
                // unmissable by the full-width tail button at the end of the
                // list, which also sits in the thumb zone.
                UgamAppBarAction(
                  icon: Icons.add_rounded,
                  tooltip: tr('tours.create'),
                  onTap: () => _openCreate(context),
                ),
              ],
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
                        controller: _searchCtrl,
                        hint: tr('tours.search_hint'),
                        autofocus: true,
                        onChanged: (v) => setState(() => _query = v.trim()),
                        onClear: () => setState(() => _query = ''),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            // The tour list is the entry point to every other surface, so it is
            // where the agent should first learn the app is running on saved
            // data. Renders nothing when the graph is live.
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
              child: CachedDataBanner(),
            ),
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return _LoadingShimmer();
                }
                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  // Shared load-failed + retry surface. errorMessage carries the
                  // tour-specific tr('errors.load_tours') copy; retry re-runs the
                  // (now internally-retrying) fetch.
                  return _dockSafe(
                    UgamEmpty.error(
                      onRetry: tourCtrl.refreshTours,
                      message: tourCtrl.errorMessage.value,
                    ),
                  );
                }

                if (tourCtrl.tours.isEmpty) {
                  return _dockSafe(
                    UgamEmpty(
                      icon: Icons.explore_rounded,
                      title: tr('tours.empty.title'),
                      body: tr('tours.empty.subtitle'),
                      cta: UgamCTA(
                        label: tr('tours.empty.cta'),
                        leadingIcon: Icons.add_rounded,
                        onPressed: () => _openCreate(context),
                      ),
                    ),
                  );
                }

                final groups = _group(tourCtrl.tours);
                final hasMatches = groups.any((g) => g.tours.isNotEmpty);

                if (_query.isNotEmpty && !hasMatches) {
                  return _dockSafe(
                    UgamEmpty(
                      icon: Icons.search_off_rounded,
                      title: tr('tours.no_matches_title'),
                      body: tr(
                        'tours.no_matches_body',
                        namedArgs: {'query': _query},
                      ),
                    ),
                  );
                }

                // Tours on file, but every one of them has already finished.
                // The three upcoming buckets are empty and Past is deliberately
                // kept out of the browse view, so without this branch the tab
                // rendered three collapsed groups — a completely blank page
                // that reads as a failed load. "Genuinely zero upcoming" is a
                // different statement from "no tours yet", so it gets its own
                // copy and its own way forward.
                if (!hasMatches) {
                  return _dockSafe(
                    UgamEmpty(
                      icon: Icons.event_available_rounded,
                      title: tr('tours.only_past_title'),
                      body: tr(
                        'tours.only_past_body',
                        namedArgs: {'n': '${tourCtrl.tours.length}'},
                      ),
                      cta: UgamCTA(
                        label: tr('tours.new_tour'),
                        leadingIcon: Icons.add_rounded,
                        onPressed: () => _openCreate(context),
                      ),
                    ),
                  );
                }

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  color: c.ink2,
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
                    // +1 for the tail. A short list (one or two upcoming
                    // trips) used to end halfway up the screen with the rest
                    // of the tab as undesigned void; the tail closes the page
                    // with the tab's own primary verb, in the thumb zone,
                    // where a top-right 44pt icon was the only door before.
                    itemCount: groups.length + 1,
                    itemBuilder: (_, i) {
                      if (i == groups.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: UgamSpacing.xl),
                          child: UgamButton(
                            label: tr('tours.new_tour'),
                            icon: Icons.add_rounded,
                            kind: UgamButtonKind.neutral,
                            expand: true,
                            onPressed: () => _openCreate(context),
                          ),
                        );
                      }
                      final g = groups[i];
                      if (g.tours.isEmpty) return const SizedBox.shrink();
                      final isPast = g.bucket == _Bucket.past;
                      final hasUpcoming = groups.any(
                        (x) => x.bucket != _Bucket.past && x.tours.isNotEmpty,
                      );
                      final pastOpen =
                          _pastOpen || _query.isNotEmpty || !hasUpcoming;
                      if (isPast && !pastOpen) {
                        return Padding(
                          padding: EdgeInsets.only(
                            bottom:
                                i == groups.length - 1 ? 0 : UgamSpacing.xl,
                          ),
                          child: _GroupHeader(
                            label: g.label,
                            count: g.tours.length,
                            c: c,
                            expanded: false,
                            onTap: () => setState(() => _pastOpen = true),
                          ),
                        );
                      }
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
                              expanded: isPast ? true : null,
                              onTap: isPast && _query.isEmpty && hasUpcoming
                                  ? () => setState(() => _pastOpen = false)
                                  : null,
                            ),
                            const SizedBox(height: UgamSpacing.md),
                            for (var j = 0; j < g.tours.length; j++) ...[
                              _TourRow(
                                tour: g.tours[j],
                                c: c,
                                dim: isPast,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        TourDetailScreen(tourId: g.tours[j].id),
                                  ),
                                ),
                              ),
                              if (j != g.tours.length - 1)
                                const SizedBox(height: UgamSpacing.md),
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

  // ── grouping ──────────────────────────────────────────────────────

  List<_Group> _group(List<Tour> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOfWeek = today.add(Duration(days: 7 - today.weekday));
    final endOf30 = today.add(const Duration(days: 30));

    final q = _query.toLowerCase();
    final filtered = _query.isEmpty
        ? all
        : all
              .where(
                (t) =>
                    t.title.toLowerCase().contains(q) ||
                    t.fromCity.toLowerCase().contains(q) ||
                    t.toCity.toLowerCase().contains(q),
              )
              .toList();

    final thisWeek = <Tour>[];
    final next30 = <Tour>[];
    final later = <Tour>[];
    final past = <Tour>[];

    for (final t in filtered) {
      // A tour is "past" once its end day (return date if any, else departure)
      // is before today — multi-day trips stay active until they actually end.
      final end = t.returnDate ?? t.departureDate;
      final endDay = DateTime(end.year, end.month, end.day);
      if (endDay.isBefore(today)) {
        past.add(t);
      } else if (!t.departureDate.isAfter(endOfWeek)) {
        thisWeek.add(t);
      } else if (!t.departureDate.isAfter(endOf30)) {
        next30.add(t);
      } else {
        later.add(t);
      }
    }

    int byDate(Tour a, Tour b) => a.departureDate.compareTo(b.departureDate);
    int byDateDesc(Tour a, Tour b) =>
        b.departureDate.compareTo(a.departureDate);

    thisWeek.sort(byDate);
    next30.sort(byDate);
    later.sort(byDate);
    past.sort(byDateDesc);

    return [
      _Group(_Bucket.thisWeek, tr('tours.group.this_week'), thisWeek),
      _Group(_Bucket.next30, tr('tours.group.next_30_days'), next30),
      _Group(_Bucket.later, tr('tours.group.later'), later),
      // Past/closed tours sit LAST behind a collapsed "Past trips (n)" header
      // so the browse view stays on upcoming work while finished trips are
      // still reachable without guessing a search term. Searching opens it.
      _Group(_Bucket.past, tr('tours.group.past_trips'), past),
    ];
  }
}

enum _Bucket { thisWeek, next30, later, past }

class _Group {
  final _Bucket bucket;
  final String label;
  final List<Tour> tours;
  _Group(this.bucket, this.label, this.tours);
}
