import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import '../utils/app_snackbar.dart';
import '../widgets/edit_request_sheet.dart';

/// SLICE 2 of the smart-seat UI: the short "needs your decision" list.
///
/// Reads the cached plan's [SeatingException]s for one tour
/// ([TourController.exceptionsForTour]) and renders them GROUPED by a
/// friendly category derived from [SeatingExceptionType]:
///
///   * priorityNoLowerBerth           → "Priority"
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

  /// Open the unified seat grid pre-selected to the bus the affected passenger
  /// sits on, when resolvable. An exception is passenger-scoped (priority /
  /// seat-type) or group-scoped (group won't fit / broken pair); we resolve the
  /// first affected passenger that actually holds a seat and jump to that bus.
  /// When nothing is placed yet (the common case for an unfit group), there is
  /// no bus to show — surface a gentle hint instead of a dead tap.
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
          AppRoutes.seatAssignment,
          arguments: {'tourId': tourId, 'busId': seat.busId},
        );
        return;
      }
    }

    AppSnackBar.info(
      tr('seating_exceptions.nothing_placed_body'),
      title: tr('seating_exceptions.nothing_placed_title'),
    );
  }

  /// Deliberately HOLD an overflow passenger on the waitlist. The engine then
  /// skips them on the next fill (no phantom overflow), and the filter in
  /// [build] drops their card immediately — no re-generate needed.
  Future<void> _onHold(SeatingException ex) async {
    final pid = ex.passengerId;
    if (pid == null) return;
    await _ctrl.setWaitlisted(tourId, pid, true);
    AppSnackBar.success(tr('seating_exceptions.held_toast'));
  }

  /// Open the edit sheet for an overflow passenger so the agent can shrink or
  /// retype the request to make it fit, then re-generate the plan.
  void _onEdit(BuildContext context, SeatingException ex) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == ex.passengerId);
    if (p == null) return;
    EditRequestSheet.show(context: context, tour: tour, passenger: p);
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
                // getTour reads the reactive `tours` list, so holding a
                // passenger (which mutates that list) also rebuilds here.
                final tour = _ctrl.getTour(tourId);
                // An overflow passenger the agent has since HELD no longer
                // needs a decision — drop their card instantly, before any
                // re-generate, so "Hold" feels immediate.
                final exceptions =
                    _ctrl.exceptionsForTour(tourId).where((ex) {
                  if (ex.type != SeatingExceptionType.overflowWaitlist) {
                    return true;
                  }
                  final p = tour?.passengers
                      .firstWhereOrNull((x) => x.id == ex.passengerId);
                  return !(p?.isWaitlisted ?? false);
                }).toList();

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
                      // The Priority section is pinned first (see
                      // _groupByCategory order) and rendered as a prominent,
                      // danger-toned alert so a priority passenger who missed a
                      // lower berth can't be overlooked.
                      _SectionHeader(
                        label: _categoryLabel(section.label),
                        count: section.items.length,
                        alert: section.label == _Category.priority,
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      for (final ex in section.items)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: UgamSpacing.md),
                          child: _ExceptionCard(
                            // Priority-no-lower-berth gets explicit alert copy
                            // (title + message) so the consequence is legible
                            // even without reading the engine's raw message.
                            message: ex.type ==
                                    SeatingExceptionType.priorityNoLowerBerth
                                ? tr('priority.no_lower_msg')
                                : ex.message,
                            title: ex.type ==
                                    SeatingExceptionType.priorityNoLowerBerth
                                ? tr('priority.no_lower_title')
                                : null,
                            passengerName: _passengerName(ex.passengerId),
                            groupLabel: ex.groupId,
                            // Priority misses are an ALERT, not a soft warm
                            // note — render the card in danger tones, pinned by
                            // the category order at the top of the list.
                            alert: ex.type ==
                                SeatingExceptionType.priorityNoLowerBerth,
                            onTap: () => _onExceptionTap(ex),
                            // Only overflow/waitlist items are resolvable
                            // inline — edit the request to fit, or hold them.
                            onEdit: ex.type ==
                                    SeatingExceptionType.overflowWaitlist
                                ? () => _onEdit(context, ex)
                                : null,
                            onHold: ex.type ==
                                    SeatingExceptionType.overflowWaitlist
                                ? () => _onHold(ex)
                                : null,
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
      case SeatingExceptionType.priorityNoLowerBerth:
        return _Category.priority;
      case SeatingExceptionType.groupWontFit:
      case SeatingExceptionType.brokenPair:
      case SeatingExceptionType.sharedDoubleNeedsReview:
        return _Category.groups;
      case SeatingExceptionType.seatTypeUnavailable:
        return _Category.seatType;
      case SeatingExceptionType.overflowWaitlist:
        return _Category.waitlist;
    }
  }
}

/// Internal category KEYS for grouping (stable, never shown verbatim — see
/// [_categoryLabel] for the localized display text).
class _Category {
  const _Category._();
  static const String priority = 'Priority';
  static const String groups = 'Groups';
  static const String seatType = 'Seat type';
  static const String waitlist = 'Waitlist';
}

/// Maps a [_Category] key to its localized section-header label.
String _categoryLabel(String key) {
  switch (key) {
    case _Category.priority:
      return tr('seating_exceptions.cat_priority');
    case _Category.groups:
      return tr('seating_exceptions.cat_groups');
    case _Category.seatType:
      return tr('seating_exceptions.cat_seat_type');
    case _Category.waitlist:
      return tr('seating_exceptions.cat_waitlist');
    default:
      return key;
  }
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
              tr('seating_exceptions.title'),
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

  /// When true the header is tinted danger and gains a leading alert glyph —
  /// used for the pinned Priority section so it reads as urgent.
  final bool alert;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.c,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = alert ? c.danger : c.ink3;
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          if (alert) ...[
            Icon(Icons.priority_high_rounded, size: 13, color: c.danger),
            const SizedBox(width: UgamSpacing.xs),
          ],
          Text(
            label.toUpperCase(),
            style: UgamText.micro.copyWith(color: labelColor),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            '$count',
            style: UgamText.tabular(
              UgamText.micro.copyWith(color: alert ? c.danger : c.ink2),
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

  /// Explicit alert headline shown ABOVE the passenger name (e.g. the priority
  /// "could not get a lower berth" title). Null on ordinary exceptions, which
  /// lean on the passenger name + engine message instead.
  final String? title;

  /// When true the card is rendered as a prominent danger-toned ALERT (red
  /// left rule, red icon badge, tinted background + border) rather than the
  /// default warm attention card. Used for priority-no-lower-berth misses.
  final bool alert;

  /// Inline remedies for a waitlist/overflow item. Null on every other
  /// exception category (those are resolved elsewhere).
  final VoidCallback? onEdit;
  final VoidCallback? onHold;
  final UgamColorSet c;

  const _ExceptionCard({
    required this.message,
    required this.passengerName,
    required this.groupLabel,
    required this.onTap,
    required this.c,
    this.title,
    this.alert = false,
    this.onEdit,
    this.onHold,
  });

  @override
  Widget build(BuildContext context) {
    final inner = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left rule = this is an attention item (red when an alert).
          Container(
            width: 4,
            decoration: BoxDecoration(
              color: alert ? c.danger : c.warm,
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
                      color: alert
                          ? c.danger.withValues(alpha: 0.14)
                          : c.warmFill,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      alert
                          ? Icons.report_problem_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: alert ? c.danger : c.warm,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (title != null) ...[
                          Text(
                            title!,
                            style: UgamText.titleS.copyWith(
                              color: alert ? c.danger : c.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                        ],
                        if (passengerName != null) ...[
                          Text(
                            passengerName!,
                            style: UgamText.titleS.copyWith(color: c.ink),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                        ],
                        Text(
                          message,
                          style: UgamText.body.copyWith(
                            color: (passengerName != null || title != null)
                                ? c.ink2
                                : c.ink,
                          ),
                        ),
                        if (groupLabel != null && groupLabel!.isNotEmpty) ...[
                          const SizedBox(height: UgamSpacing.sm),
                          _GroupChip(label: groupLabel!, c: c),
                        ],
                        if (onEdit != null || onHold != null) ...[
                          const SizedBox(height: UgamSpacing.md),
                          Row(
                            children: [
                              if (onHold != null)
                                _WaitlistAction(
                                  label: tr('seating_exceptions.action_hold'),
                                  icon: Icons.pause_circle_outline_rounded,
                                  onTap: onHold!,
                                  c: c,
                                ),
                              if (onHold != null && onEdit != null)
                                const SizedBox(width: UgamSpacing.sm),
                              if (onEdit != null)
                                _WaitlistAction(
                                  label: tr('seating_exceptions.action_edit'),
                                  icon: Icons.edit_note_rounded,
                                  onTap: onEdit!,
                                  c: c,
                                ),
                            ],
                          ),
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
    );

    // Alert items render as a prominent danger-tinted card (UgamCard has no
    // colour override, so the alert variant is a styled Container that mirrors
    // the same tap/haptic affordance); everything else keeps the calm warm
    // attention card.
    if (alert) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: c.danger.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(UgamRadius.row),
            border: Border.all(color: c.danger.withValues(alpha: 0.45)),
          ),
          clipBehavior: Clip.antiAlias,
          child: inner,
        ),
      );
    }

    return UgamCard.plain(
      onTap: onTap,
      radius: UgamRadius.row,
      padding: EdgeInsets.zero,
      child: inner,
    );
  }
}

/// A small warm-outline action button used inline on overflow/waitlist cards.
class _WaitlistAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _WaitlistAction({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: c.warmFill,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: c.warm.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: c.warm),
            const SizedBox(width: 5),
            Text(
              label,
              style: UgamText.caption.copyWith(
                color: c.warm,
                fontWeight: FontWeight.w700,
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
            tr('seating_exceptions.group_label', namedArgs: {'label': label}),
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
              tr('seating_exceptions.all_clear_title'),
              style: UgamText.titleM.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: UgamSpacing.sm),
            Text(
              tr('seating_exceptions.all_clear_body'),
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
