import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import 'create_tour_screen.dart';
import 'main_shell.dart';
import 'settings_screen.dart';
import 'tour_detail_screen.dart';

/// Admin home screen. Mirrors the Pencil "Admin Home" layout:
/// greeting + avatar, 2x2 stat grid, "Upcoming Tours" list with status
/// pills, and a floating "+" CTA that opens Create Tour.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final authCtrl = Get.find<AuthController>();
    final shell = Get.find<ShellController>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            // The full-screen empty-state branches (loading / error) still
            // need to gate the whole tree, so this outer Obx watches
            // `isLoading` + `hasError` + `tours` for emptiness only. Once
            // we render the list, the inner sections each carry their
            // own Obx scope so an auth-name update doesn't repaint stats,
            // and a stats-recomputation doesn't repaint every tour card.
            Obx(() {
              if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                return _ErrorState(
                  message: tourCtrl.errorMessage.value,
                  onRetry: tourCtrl.refreshTours,
                );
              }
              return RefreshIndicator(
                onRefresh: tourCtrl.refreshTours,
                color: AppTheme.brand,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 140),
                  children: [
                    // Greeting — depends on auth state only. Lifted into
                    // its own Obx so a tour write doesn't re-render the
                    // avatar or the user's display name.
                    Obx(() => _Greeting(
                          name: authCtrl.userName.value,
                          initials: authCtrl.initials,
                        )),
                    const SizedBox(height: 28),
                    _SectionLabel(tr('dashboard.section_overview')),
                    const SizedBox(height: 12),
                    // Stats — derived from tours. Recomputes only when
                    // the tours list itself emits.
                    Obx(() {
                      final tours = tourCtrl.tours;
                      final activeTours = tourCtrl.activeTours;
                      final pendingRequests = tourCtrl
                          .toursByStatus(TourStatus.collecting)
                          .length;
                      final totalPassengers = tours.fold<int>(
                          0, (s, t) => s + t.passengerCount);
                      final revenue = tours.fold<double>(
                          0,
                          (s, t) =>
                              s + (t.pricePerSeat * t.totalSeatsRequested));
                      return _StatRow(
                        activeCount: activeTours.length,
                        pendingRequests: pendingRequests,
                        totalPassengers: totalPassengers,
                        revenue: revenue,
                      );
                    }),
                    const SizedBox(height: 28),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          tr('dashboard.section_upcoming'),
                          style: AppText.sectionTitle.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => shell.switchTab(1),
                          child: Text(
                            tr('dashboard.see_all'),
                            style: AppText.link.copyWith(color: AppTheme.brand),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // Tours list — its own Obx so stat recomputations
                    // never trigger card rebuilds and vice-versa. Uses
                    // ListView.builder (shrink-wrapped, non-scrollable —
                    // the outer ListView owns the scroll) so each card
                    // is built lazily as it scrolls into view instead of
                    // up-front on first paint.
                    Obx(() {
                      final activeTours = tourCtrl.activeTours;
                      if (activeTours.isEmpty) return const _EmptyTours();
                      return ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        itemCount: activeTours.length,
                        itemBuilder: (context, i) {
                          final tour = activeTours[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _TourCard(
                              tour: tour,
                              onTap: () => Get.to(
                                () => TourDetailScreen(tourId: tour.id),
                                transition: Transition.cupertino,
                              ),
                            ),
                          );
                        },
                      );
                    }),
                  ],
                ),
              );
            }),

            // Floating "+" — sits clear of the pill bottom nav (~104px tall).
            Positioned(
              right: 20,
              bottom: 110,
              child: _Fab(onTap: () => Get.to(() => const CreateTourScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  final String name;
  final String initials;

  const _Greeting({required this.name, required this.initials});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final greeting = _greetingForHour(DateTime.now().hour);
    final displayName = name.isNotEmpty ? name : tr('dashboard.welcome_fallback');
    final displayInitials = initials.isNotEmpty ? initials : '👋';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                greeting,
                style: AppText.bodyMd.copyWith(
                  color: AppColors.textMuted(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                displayName,
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => Get.to(
            () => const SettingsScreen(),
            transition: Transition.cupertino,
          ),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: AppTheme.brand,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              displayInitials,
              style: AppText.chipText.copyWith(
                fontSize: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _greetingForHour(int hour) {
    if (hour < 12) return tr('dashboard.greeting_morning');
    if (hour < 17) return tr('dashboard.greeting_afternoon');
    return tr('dashboard.greeting_evening');
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppText.labelCaps.copyWith(color: AppColors.textMuted(context)),
    );
  }
}

/// Horizontal pill row of compact stats. Replaces the old 2×2 stat
/// grid — that grid ate ~200px of vertical real estate showing mostly
/// zeros while the agent's actual work (tour cards) was pushed down.
/// Pills scroll horizontally so we can grow the set later without
/// stealing more vertical space.
class _StatRow extends StatelessWidget {
  final int activeCount;
  final int pendingRequests;
  final int totalPassengers;
  final double revenue;

  const _StatRow({
    required this.activeCount,
    required this.pendingRequests,
    required this.totalPassengers,
    required this.revenue,
  });

  @override
  Widget build(BuildContext context) {
    final pills = <Widget>[
      _StatPill(
        icon: Icons.map_rounded,
        accent: AppTheme.brand,
        accentBg: AppTheme.brandLight,
        value: '$activeCount',
        label: tr('dashboard.stat_active_tours'),
      ),
      _StatPill(
        icon: Icons.access_time_rounded,
        accent: AppTheme.warning,
        accentBg: AppTheme.warningLight,
        value: '$pendingRequests',
        label: tr('dashboard.stat_pending_requests'),
      ),
      _StatPill(
        icon: Icons.people_rounded,
        accent: AppTheme.success,
        accentBg: AppTheme.successLight,
        value: '$totalPassengers',
        label: tr('dashboard.stat_total_passengers'),
      ),
      _StatPill(
        icon: Icons.currency_rupee_rounded,
        accent: AppTheme.info,
        accentBg: AppTheme.infoLight,
        value: _formatRevenue(revenue),
        label: tr('dashboard.stat_revenue'),
      ),
    ];

    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: pills.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => pills[i],
      ),
    );
  }

  String _formatRevenue(double amount) {
    if (amount >= 100000) {
      final lakhs = amount / 100000;
      return lakhs == lakhs.roundToDouble()
          ? '₹${lakhs.toInt()}L'
          : '₹${lakhs.toStringAsFixed(1)}L';
    }
    if (amount >= 1000) {
      final k = amount / 1000;
      return k == k.roundToDouble()
          ? '₹${k.toInt()}K'
          : '₹${k.toStringAsFixed(1)}K';
    }
    return '₹${amount.toInt()}';
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final Color accentBg;
  final String value;
  final String label;

  const _StatPill({
    required this.icon,
    required this.accent,
    required this.accentBg,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: AppTheme.subtleShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: accentBg,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: accent),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: AppText.statValue.copyWith(
                  color: AppColors.text(context),
                ),
              ),
              Text(
                label,
                style: AppText.cardLabel.copyWith(
                  color: AppColors.textMuted(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TourCard extends StatelessWidget {
  final Tour tour;
  final VoidCallback onTap;

  const _TourCard({required this.tour, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = _statusColors(context, tour.status);
    final assignedTotal = tour.totalSeatsAssigned;
    final capacity = tour.totalBusSeats;
    final pct = capacity > 0
        ? (assignedTotal / capacity).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border(context)),
          boxShadow: AppTheme.subtleShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Title row: name on the left, status pill on the right
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    tour.title,
                    style: AppText.cardTitle.copyWith(
                      color: AppColors.text(context),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.$1,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    tour.status.displayName,
                    style: AppText.badge.copyWith(color: colors.$2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Meta row: route, date, pax
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _MetaItem(
                  icon: Icons.calendar_today_outlined,
                  text: _formatDate(tour.departureDate, tour.returnDate),
                ),
                _MetaItem(
                  icon: Icons.people_outline_rounded,
                  text: tr('dashboard.pax',
                      namedArgs: {'count': '${tour.passengerCount}'}),
                ),
                if (tour.fromCity.isNotEmpty || tour.toCity.isNotEmpty)
                  _MetaItem(
                    icon: Icons.south_east_rounded,
                    text: '${tour.fromCity} → ${tour.toCity}',
                  ),
              ],
            ),
            // ── Seats progress bar (only when buses are booked + capacity > 0)
            if (capacity > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 6,
                        backgroundColor: AppColors.bg(context),
                        valueColor: AlwaysStoppedAnimation(colors.$2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$assignedTotal/$capacity',
                    style: AppText.cardMeta.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMuted(context),
                    ),
                  ),
                ],
              ),
            ],
            // ── Inline quick actions, status-aware
            ..._buildQuickActions(context),
          ],
        ),
      ),
    );
  }

  /// Status-aware row of quick actions. Returns an empty list when no
  /// action fits the current status — keeps the card tight for terminal
  /// states like `locked` / `completed`.
  List<Widget> _buildQuickActions(BuildContext context) {
    final actions = <_QuickAction>[];
    switch (tour.status) {
      case TourStatus.planning:
      case TourStatus.collecting:
      case TourStatus.busBooked:
      case TourStatus.assigning:
        actions.add(_QuickAction(
          icon: Icons.event_seat_rounded,
          label: tr('dashboard.action_assign_seats'),
          onTap: () => Get.toNamed(
            AppRoutes.seatAssignment,
            arguments: {'tourId': tour.id},
          ),
        ));
        break;
      case TourStatus.locked:
      case TourStatus.completed:
        break;
    }
    if (actions.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Row(
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: actions[i]),
          ],
        ],
      ),
    ];
  }

  String _formatDate(DateTime departure, DateTime? returnDate) {
    final fmt = DateFormat('MMM d');
    if (returnDate != null) {
      return '${fmt.format(departure)} – ${fmt.format(returnDate)}';
    }
    return fmt.format(departure);
  }

  (Color, Color) _statusColors(BuildContext context, TourStatus status) {
    switch (status) {
      case TourStatus.planning:
        return (AppTheme.infoLight, AppTheme.info);
      case TourStatus.collecting:
        return (AppTheme.warningLight, AppTheme.warning);
      case TourStatus.busBooked:
        return (AppTheme.brandLight, AppTheme.brand);
      case TourStatus.assigning:
        return (AppTheme.brandLight, AppTheme.brand);
      case TourStatus.locked:
        return (AppTheme.successLight, AppTheme.success);
      case TourStatus.completed:
        return (AppColors.surfaceAlt(context), AppColors.textMuted(context));
    }
  }
}

/// One key/value meta row item used inside `_TourCard` — small icon +
/// muted text. Lives in a Wrap so it flows to a second line on narrow
/// screens instead of overflowing.
class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppColors.textMuted(context)),
        const SizedBox(width: 4),
        Text(
          text,
          style: AppText.cardMeta.copyWith(color: AppColors.textMuted(context)),
        ),
      ],
    );
  }
}

/// Inline brand-tinted action chip stamped on `_TourCard`. Tapping
/// stops the outer card's onTap (we route to the action's own target
/// instead of opening tour details).
class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.brandLight,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: AppTheme.brand),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppText.buttonInline.copyWith(color: AppTheme.brand),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fab extends StatelessWidget {
  final VoidCallback onTap;

  const _Fab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppTheme.brand,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppTheme.brand.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.add, size: 24, color: Colors.white),
      ),
    );
  }
}

class _EmptyTours extends StatelessWidget {
  const _EmptyTours();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: AppTheme.subtleShadow,
      ),
      child: Column(
        children: [
          Icon(Icons.map_outlined, size: 40, color: AppColors.textMuted(context)),
          const SizedBox(height: 8),
          Text(
            tr('dashboard.empty_tours'),
            style: AppText.bodyMd.copyWith(color: AppColors.textMuted(context)),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: AppColors.textMuted(context),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.bodyMd.copyWith(
                fontSize: 14,
                color: AppColors.textMuted(context),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(tr('app.action.retry')),
            ),
          ],
        ),
      ),
    );
  }
}
