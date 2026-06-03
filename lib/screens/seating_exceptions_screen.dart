import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import '../utils/app_snackbar.dart';

/// SLICE 2 of the smart-seat UI: the short "needs your decision" list.
///
/// Reads the cached plan's [SeatingException]s for one tour
/// ([TourController.exceptionsForTour]) and renders them GROUPED by a
/// friendly category derived from [SeatingExceptionType]:
///
///   * priorityNoFrontSeat            → "Priority"
///   * groupWontFit, brokenPair       → "Groups"
///   * seatTypeUnavailable            → "Seat type"
///   * overflowWaitlist               → "Waitlist"
///
/// Each section has a header with a tabular count; each exception is a
/// warm attention card (a warm left rule + warm icon) showing the
/// engine's message, the affected passenger name (resolved from the tour
/// via [passengerId]), and the group label when [groupId] is set. Tapping
/// a card is reserved for the future per-bus seat-detail route.
///
/// When there are NO exceptions the screen shows a calm "All clear" panel
/// in good/ink tones — never warm, because an empty state is not an
/// attention item.
///
/// All colour comes from [UgamColors.of] — nothing hardcoded — and the
/// screen is dark-first per the locked design DNA. The list is reactive:
/// an Obx on [TourController.lastPlanByTour] repaints whenever a fresh
/// fillTour caches a new plan.
class SeatingExceptionsScreen extends StatelessWidget {
  final String tourId;

  const SeatingExceptionsScreen({super.key, required this.tourId});

  TourController get _ctrl => Get.find<TourController>();

  /// Navigate to the seat detail of the bus the affected passenger sits on,
  /// when resolvable. An exception is passenger-scoped (priority / seat-type)
  /// or group-scoped (group won't fit / broken pair); we resolve the first
  /// affected passenger that actually holds a seat and jump to that bus. When
  /// nothing is placed yet (the common case for an unfit group), there is no
  /// bus to show — surface a gentle hint instead of a dead tap.
  void _onExceptionTap(SeatingException ex) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;

    // Collect candidate passengers: the named one first, then any group
    // member when the exception is group-scoped.
    final candidates = <String?>[
      ex.passengerId,
      if (ex.groupId != null)
        ...tour.passengers
            .where((p) => p.groupId == ex.groupId)
            .map((p) => p.id),
    ];

    for (final pid in candidates) {
      if (pid == null) continue;
      final p = tour.passengers.where((x) => x.id == pid).firstOrNull;
      final seat = p?.assignedSeats.firstOrNull;
      if (seat != null) {
        Get.toNamed(
          AppRoutes.seatDetail,
          arguments: {'tourId': tourId, 'busId': seat.busId},
        );
        return;
      }
    }

    AppSnackBar.info(
      'These passengers are not seated yet — fill or assign them to a bus '
      'first, then open the chart.',
      title: 'Nothing placed yet',
    );
  }

  /// Resolve a passenger id to a display name via the tour roster. Falls
  /// back to null when the id is absent or unknown — callers then lean on
  /// the engine's own message text instead.
  String? _passengerName(String? passengerId) {
    if (passengerId == null) return null;
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return null;
    for (final p in tour.passengers) {
      if (p.id == passengerId) {
        return p.name.isNotEmpty ? p.name : null;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(c: c),
            Expanded(
              child: Obx(() {
                // Touch lastPlanByTour so this rebuilds when a fresh fill
                // caches a new plan; exceptionsForTour reads from it.
                _ctrl.lastPlanByTour; // ignore: unnecessary_statements
                final exceptions = _ctrl.exceptionsForTour(tourId);

                if (exceptions.isEmpty) {
                  return _AllClear(c: c);
                }

                final sections = _groupByCategory(exceptions);
                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xl,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    for (final section in sections) ...[
                      _SectionHeader(
                        label: section.label,
                        count: section.items.length,
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      for (final ex in section.items)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: UgamSpacing.md),
                          child: _ExceptionCard(
                            message: ex.message,
                            passengerName: _passengerName(ex.passengerId),
                            groupLabel: ex.groupId,
                            onTap: () => _onExceptionTap(ex),
                            c: c,
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.md),
                    ],
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Bucket exceptions into the friendly categories, preserving the
  /// engine's deterministic order within each bucket and emitting only
  /// the non-empty sections in a stable category order.
  static List<_Section> _groupByCategory(List<SeatingException> exceptions) {
    final order = <String>[
      _Category.priority,
      _Category.groups,
      _Category.seatType,
      _Category.waitlist,
    ];
    final byLabel = <String, List<SeatingException>>{};
    for (final ex in exceptions) {
      (byLabel[_categoryFor(ex.type)] ??= <SeatingException>[]).add(ex);
    }
    return [
      for (final label in order)
        if (byLabel[label] != null && byLabel[label]!.isNotEmpty)
          _Section(label: label, items: byLabel[label]!),
    ];
  }

  static String _categoryFor(SeatingExceptionType type) {
    switch (type) {
      case SeatingExceptionType.priorityNoFrontSeat:
        return _Category.priority;
      case SeatingExceptionType.groupWontFit:
      case SeatingExceptionType.brokenPair:
        return _Category.groups;
      case SeatingExceptionType.seatTypeUnavailable:
        return _Category.seatType;
      case SeatingExceptionType.overflowWaitlist:
        return _Category.waitlist;
    }
  }
}

/// Friendly category labels for the section headers.
class _Category {
  const _Category._();
  static const String priority = 'Priority';
  static const String groups = 'Groups';
  static const String seatType = 'Seat type';
  static const String waitlist = 'Waitlist';
}

class _Section {
  final String label;
  final List<SeatingException> items;
  const _Section({required this.label, required this.items});
}

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final UgamColorSet c;

  const _Header({required this.c});

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
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              'Needs your decision',
              style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section header ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            '$count',
            style: UgamText.tabular(
              UgamText.micro.copyWith(color: c.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Exception card ──────────────────────────────────────────────────────

class _ExceptionCard extends StatelessWidget {
  final String message;
  final String? passengerName;
  final String? groupLabel;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _ExceptionCard({
    required this.message,
    required this.passengerName,
    required this.groupLabel,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: onTap,
      radius: UgamRadius.row,
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Warm left rule = this is an attention item.
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: c.warm,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(UgamRadius.row),
                  bottomLeft: Radius.circular(UgamRadius.row),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(UgamSpacing.lg),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: c.warmFill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 18,
                        color: c.warm,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (passengerName != null) ...[
                            Text(
                              passengerName!,
                              style:
                                  UgamText.titleS.copyWith(color: c.ink),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                          ],
                          Text(
                            message,
                            style: UgamText.body.copyWith(
                              color: passengerName != null ? c.ink2 : c.ink,
                            ),
                          ),
                          if (groupLabel != null &&
                              groupLabel!.isNotEmpty) ...[
                            const SizedBox(height: UgamSpacing.sm),
                            _GroupChip(label: groupLabel!, c: c),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: c.ink3,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  final String label;
  final UgamColorSet c;

  const _GroupChip({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm + 2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group_rounded, size: 13, color: c.ink3),
          const SizedBox(width: UgamSpacing.xs + 1),
          Text(
            'Group $label',
            style: UgamText.caption.copyWith(
              color: c.ink2,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Empty ("All clear") state ────────────────────────────────────────────

class _AllClear extends StatelessWidget {
  final UgamColorSet c;

  const _AllClear({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.xl,
        vertical: UgamSpacing.huge,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: c.goodFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.check_circle_outline_rounded,
                size: 30,
                color: c.good,
              ),
            ),
            const SizedBox(height: UgamSpacing.lg),
            Text(
              'All clear',
              style: UgamText.titleM.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: UgamSpacing.sm),
            Text(
              'No seating decisions need your attention right now.',
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
