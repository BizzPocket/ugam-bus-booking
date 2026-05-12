import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/tour_controller.dart';
import '../models/tour_status.dart';
import '../components/tour_card.dart';
import '../config/theme.dart';
import 'tour_detail_screen.dart';

class ToursScreen extends StatelessWidget {
  const ToursScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Lift the FAB above MainShell's floating pill bottom nav (~104px tall
      // with extendBody: true). Without this it disappears behind the nav.
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 90),
        child: FloatingActionButton(
          heroTag: 'tours_fab',
          onPressed: () => Get.toNamed('/create-tour'),
          child: const Icon(Icons.add),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    tr('tours.title'),
                    style: GoogleFonts.inter(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text(context),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Quick Stats Row ─────────────────────────────────────
            Obx(() => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      _StatChip(
                        label: tr('tours.stat.active'),
                        count: tourCtrl.activeTours.length,
                        color: AppTheme.brand,
                      ),
                      const SizedBox(width: 8),
                      _StatChip(
                        label: tr('tours.stat.collecting'),
                        count: tourCtrl
                            .toursByStatus(TourStatus.collecting)
                            .length,
                        color: AppTheme.warning,
                      ),
                      const SizedBox(width: 8),
                      _StatChip(
                        label: tr('tours.stat.locked'),
                        count:
                            tourCtrl.toursByStatus(TourStatus.locked).length,
                        color: AppTheme.success,
                      ),
                      const SizedBox(width: 8),
                      _StatChip(
                        label: tr('tours.stat.completed'),
                        count: tourCtrl.completedTours.length,
                        color: const Color(0xFF6B7280),
                      ),
                    ],
                  ),
                )),

            const SizedBox(height: 20),

            // ── Tour List / Empty State ─────────────────────────────
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_off_rounded,
                              size: 48,
                              color: AppColors.textMuted(context)),
                          const SizedBox(height: 16),
                          Text(
                            tourCtrl.errorMessage.value,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              color: AppColors.textMuted(context),
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: tourCtrl.refreshTours,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: Text(tr('app.action.retry')),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final tours = tourCtrl.tours;

                if (tours.isEmpty) {
                  return _EmptyState(
                    onCreateTour: () => Get.toNamed('/create-tour'),
                  );
                }

                return RefreshIndicator(
                  onRefresh: tourCtrl.refreshTours,
                  color: AppTheme.brand,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 100),
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    itemCount: tours.length,
                    itemBuilder: (ctx, i) {
                      final tour = tours[tours.length - 1 - i]; // newest first
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TourCard(
                          tour: tour,
                          onTap: () => Get.to(
                            () => TourDetailScreen(tourId: tour.id),
                            transition: Transition.cupertino,
                          ),
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
}

// ── Stat Chip ──────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.border(context),
          ),
          boxShadow: AppTheme.subtleShadow,
        ),
        child: Column(
          children: [
            Text(
              count.toString(),
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: color,
                height: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted(context),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty State ────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTour;

  const _EmptyState({required this.onCreateTour});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.brand.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.explore_rounded,
                size: 40,
                color: AppTheme.brand.withAlpha(150),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              tr('tours.empty.title'),
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.text(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr('tours.empty.subtitle'),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: AppColors.textMuted(context),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: onCreateTour,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: Text(
                  tr('tours.empty.cta'),
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}
