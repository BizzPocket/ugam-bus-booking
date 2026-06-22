import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import '../utils/app_snackbar.dart';
import '../utils/tour_capacity.dart';
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
/// warm/danger-toned [UgamCard] showing the engine's message, the affected
/// passenger name (resolved from the tour via [passengerId]), and the group
/// label when [groupId] is set. Tapping a card routes into the unified seat
/// grid — pre-selected to the affected passenger so the agent lands exactly
/// where the fix is made.
///
/// When there are NO exceptions the screen shows a calm "All clear"
/// [UgamEmpty] — never an attention tone, because an empty state is not an
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

  /// Open the unified seat grid pre-selected to the affected passenger. When
  /// that passenger already holds a seat we also jump to their bus; otherwise
  /// (the common case for an unfit group / overflow) we still hand the grid the
  /// passenger id so it opens with them pre-selected — the existing
  /// [AppRoutes.seatAssignment] arg supports this, so a not-yet-placed tap is
  /// no longer a dead end. Only when there is no resolvable passenger at all do
  /// we surface a gentle hint.
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

    // Prefer a passenger that already holds a seat (we can jump to their bus);
    // otherwise fall back to the first resolvable passenger so the grid still
    // opens pre-selected to them.
    String? firstPassengerId;
    for (final pid in candidates) {
      if (pid == null) continue;
      final p = tour.passengers.where((x) => x.id == pid).firstOrNull;
      if (p == null) continue;
      firstPassengerId ??= p.id;
      final seat = p.assignedSeats.firstOrNull;
      if (seat != null) {
        Get.toNamed(
          AppRoutes.seatAssignment,
          arguments: {
            'tourId': tourId,
            'busId': seat.busId,
            'passengerId': p.id,
          },
        );
        return;
      }
    }

    // Nobody is placed yet — route into the grid pre-selected to the affected
    // passenger so the agent can place them directly.
    if (firstPassengerId != null) {
      Get.toNamed(
        AppRoutes.seatAssignment,
        arguments: {'tourId': tourId, 'passengerId': firstPassengerId},
      );
      return;
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
            UgamAppBar(title: tr('seating_exceptions.title')),
            Expanded(
              child: Obx(() {
                // getTour reads the reactive `tours` list, so holding a
                // passenger (which mutates that list) rebuilds here.
                final tour = _ctrl.getTour(tourId);
                // SINGLE SOURCE with the Dashboard/Requests badge — the same
                // live, non-mutating helper the needsDecision count uses, so the
                // number you see on those surfaces equals the cards here. Pure:
                // never fillTour (which would assign + persist seats just to
                // view), and an overflow rider already HELD is dropped instantly.
                final exceptions = tour == null
                    ? const <SeatingException>[]
                    : seatingDecisionExceptions(tour);

                if (exceptions.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.check_circle_outline_rounded,
                    title: tr('seating_exceptions.all_clear_title'),
                    body: tr('seating_exceptions.all_clear_body'),
                  );
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: alert ? c.danger.withValues(alpha: 0.14) : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            child: Text(
              '$count',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: alert ? c.danger : c.ink2),
              ),
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

  /// When true the card is rendered in danger tones (a prominent ALERT) rather
  /// than the default warm attention card. Used for priority-no-lower-berth
  /// misses.
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
    // The attention colour drives the icon badge + accents; the card surface
    // itself is toned by [UgamCard] (warm vs danger).
    final Color toneInk = alert ? c.danger : c.warm;
    final Color toneFill =
        alert ? c.danger.withValues(alpha: 0.14) : c.warmFill;

    return UgamCard.plain(
      onTap: onTap,
      tone: alert ? UgamCardTone.danger : UgamCardTone.warm,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: toneFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              alert
                  ? Icons.report_problem_rounded
                  : Icons.error_outline_rounded,
              size: 18,
              color: toneInk,
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
                  const SizedBox(height: UgamSpacing.xs - 1),
                ],
                if (passengerName != null) ...[
                  Text(
                    passengerName!,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.xs - 1),
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
                        Expanded(
                          child: UgamButton(
                            label: tr('seating_exceptions.action_hold'),
                            icon: Icons.pause_circle_outline_rounded,
                            kind: UgamButtonKind.neutral,
                            onPressed: onHold,
                          ),
                        ),
                      if (onHold != null && onEdit != null)
                        const SizedBox(width: UgamSpacing.sm),
                      if (onEdit != null)
                        Expanded(
                          child: UgamButton(
                            label: tr('seating_exceptions.action_edit'),
                            icon: Icons.edit_note_rounded,
                            kind: UgamButtonKind.tonal,
                            onPressed: onEdit,
                          ),
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
        vertical: UgamSpacing.xs,
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
          Flexible(
            child: Text(
              tr('seating_exceptions.group_label', namedArgs: {'label': label}),
              style: UgamText.micro.copyWith(color: c.ink2, letterSpacing: 0.2),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
