import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/seat_assignment.dart';
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/stranger_share_seat.dart';
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
/// Each section has a header with a count badge ([UgamReqChip] — the app's one
/// badge); each exception is a warm/danger-toned [UgamCard] showing the
/// engine's message, the affected passenger name (resolved from the tour via
/// [passengerId]) and, when [groupId] is set, that group's human label —
/// resolved through the roster, never the raw id.
///
/// A card that resolves to a passenger routes into the unified seat grid,
/// pre-selected to them, so the agent lands exactly where the fix is made. A
/// bus-level exception resolves to nobody, so it renders WITHOUT a tap or a
/// chevron rather than promising a destination it cannot reach.
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

    // Defensive only. The card is now wired with `onTap` at all only when
    // [_isTappable] proved a passenger resolves, so this is reachable just if
    // the roster changed between the frame that built the card and the tap.
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

  /// Agent confirms a stranger share on a half-double: place the blocked
  /// passenger onto the free berth of the occupied double, locked so fillTour
  /// won't undo it.
  Future<void> _onApproveShare(
    BuildContext context,
    SeatingException ex,
  ) async {
    final pid = ex.passengerId;
    if (pid == null) return;
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == pid);
    if (p == null) return;

    final ok = await UgamDialog.confirm(
      context,
      title: tr('seating_exceptions.approve_share_title'),
      message: tr(
        'seating_exceptions.approve_share_body',
        namedArgs: {'name': p.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('seating_exceptions.action_approve_share'),
      confirmIcon: Icons.people_alt_rounded,
    );
    if (!ok) return;

    final target = findStrangerShareSeat(tour, p);
    if (target == null) {
      // Seat state moved — fall back to the grid so the agent can place by hand.
      AppSnackBar.info(tr('seating_exceptions.approve_share_missing'));
      _onExceptionTap(ex);
      return;
    }

    final existing = List<SeatAssignment>.from(p.assignedSeats);
    existing.add(SeatAssignment(
      busId: target.busId,
      seatId: target.seatId,
      locked: true,
      leg: target.leg,
    ));
    await _ctrl.assignSeats(tourId, pid, existing);
    AppSnackBar.success(
      tr(
        'seating_exceptions.approve_share_done',
        namedArgs: {'name': p.displayName, 'seat': target.seatId},
      ),
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

  /// Resolve a group id to the human label the agent typed.
  ///
  /// [SeatingException.groupId] carries a [PassengerGroup.id] (a v4 UUID), not
  /// the `label` field — rendering it raw leaked "Group 3f2a1c9e-…" onto the
  /// card. Resolved exactly as `requests_screen.dart` already does, so both
  /// screens name the same group identically.
  String? _groupLabel(String? groupId) {
    if (groupId == null) return null;
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return null;
    final g = tour.groups.firstWhereOrNull((g) => g.id == groupId);
    final label = g?.label;
    return (label == null || label.isEmpty) ? null : label;
  }

  /// True when tapping this exception will actually navigate.
  ///
  /// Mirrors [_onExceptionTap]'s candidate resolution exactly (the named
  /// passenger, else any member of the exception's group), so the card's
  /// chevron is shown if and only if there is somewhere to go. A bus-level
  /// exception ([SeatingException.passengerId] is documented null for those)
  /// resolves to nothing and therefore renders as a flat, un-tappable note
  /// instead of advertising a destination it can't reach.
  bool _isTappable(SeatingException ex) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return false;
    if (ex.passengerId != null &&
        tour.passengers.any((p) => p.id == ex.passengerId)) {
      return true;
    }
    if (ex.groupId != null &&
        tour.passengers.any((p) => p.groupId == ex.groupId)) {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Layouts deferred on cold start — needed before share/hold actions that
    // open the seat grid.
    // ignore: unawaited_futures
    _ctrl.ensureTourReadyForSeating(tourId);
    return UgamScaffold(
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
                // "Not loaded yet" is NOT "nothing needs you". On a cold start
                // / deep link the roster has not arrived, and this used to
                // resolve to an empty exception list and paint the calm green
                // "All clear" — the one message on the screen an agent acts on
                // by walking away. Show the shape of the list instead; the Obx
                // repaints the moment the tour lands.
                if (tour == null) return const _ExceptionsSkeleton();
                // SINGLE SOURCE with the Dashboard/Requests badge — the same
                // live, non-mutating helper the needsDecision count uses, so the
                // number you see on those surfaces equals the cards here. Pure:
                // never fillTour (which would assign + persist seats just to
                // view), and an overflow rider already HELD is dropped instantly.
                // Read off the memoized capacity snapshot: the badge count on
                // Dashboard/Requests and these cards are now literally the same
                // list from the same engine run, not two runs that agree.
                final exceptions = _ctrl.capacityFor(tour).decisions;

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
                            // A bus-level exception resolves to no passenger,
                            // so it gets neither the tap nor the chevron that
                            // used to promise a destination and deliver a toast.
                            tappable: _isTappable(ex),
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
                            groupLabel: _groupLabel(ex.groupId),
                            // Priority misses are an ALERT, not a soft warm
                            // note — render the card in danger tones, pinned by
                            // the category order at the top of the list.
                            alert: ex.type ==
                                SeatingExceptionType.priorityNoLowerBerth,
                            onTap: () => _onExceptionTap(ex),
                            // Overflow: Hold / Edit. Stranger-share: Approve /
                            // Hold / Edit so the agent can broker without
                            // rediscovering the pair in the grid.
                            onEdit: ex.type ==
                                        SeatingExceptionType.overflowWaitlist ||
                                    ex.type ==
                                        SeatingExceptionType
                                            .sharedDoubleNeedsReview
                                ? () => _onEdit(context, ex)
                                : null,
                            onHold: ex.type ==
                                        SeatingExceptionType.overflowWaitlist ||
                                    ex.type ==
                                        SeatingExceptionType
                                            .sharedDoubleNeedsReview
                                ? () => _onHold(ex)
                                : null,
                            onApproveShare: ex.type ==
                                    SeatingExceptionType.sharedDoubleNeedsReview
                                ? () => _onApproveShare(context, ex)
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

// ─── Loading ─────────────────────────────────────────────────────────────

/// The list's own shape while the roster loads — a section eyebrow followed by
/// three exception-card blocks, on the same gutters and rhythm as the real
/// [ListView] above. A centred spinner would have told the agent nothing about
/// what is arriving; this holds the layout still so the real cards drop into
/// place instead of shoving the page around.
class _ExceptionsSkeleton extends StatelessWidget {
  const _ExceptionsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const UgamSkeleton.text(width: 96),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < 3; i++) ...[
          const UgamSkeleton(height: 92, radius: UgamRadius.row),
          const SizedBox(height: UgamSpacing.md),
        ],
      ],
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
    // ink2, not ink3 — with caps and tracking gone from the eyebrow, colour is
    // the emphasis that actually lands (ink3 is 3.69:1 on the dark ground and
    // reads as disabled next to a count badge).
    final labelColor = alert ? c.danger : c.ink2;
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          if (alert) ...[
            Icon(
              Icons.priority_high_rounded,
              size: UgamScale.px(context, 13),
              color: c.danger,
            ),
            const SizedBox(width: UgamSpacing.xs),
          ],
          // [UgamText.label], not [UgamSectionLabel]. The shared eyebrow still
          // uppercases onto `micro`, and every one of these categories is a
          // translated string: in Gujarati the caps do nothing, micro's 1.4
          // tracking splits conjuncts, and its 10px lands at 8.5 on a small
          // phone. Flagged for the owner of lib/design; switched here because
          // this screen is in the wave.
          //
          // Flexible: the label was an unbounded Row child sitting in front of
          // a count badge, so a long Gujarati category had nowhere to give.
          Flexible(
            child: Text(
              label,
              style: UgamText.label.copyWith(color: labelColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // THE app badge — the count no longer renders as a private
          // 999-radius lozenge while the identical count on Requests uses a
          // 6-radius chip.
          UgamReqChip(
            label: '$count',
            variant:
                alert ? UgamChipVariant.danger : UgamChipVariant.neutral,
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

  /// Whether [onTap] actually leads somewhere. False for a bus-level
  /// exception, which resolves to no passenger — the card then drops BOTH the
  /// tap and the chevron rather than advertising a destination and answering
  /// with a toast.
  final bool tappable;

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

  /// Approve stranger share on a half-double (sharedDoubleNeedsReview only).
  final VoidCallback? onApproveShare;
  final UgamColorSet c;

  const _ExceptionCard({
    required this.message,
    required this.passengerName,
    required this.groupLabel,
    required this.onTap,
    required this.tappable,
    required this.c,
    this.title,
    this.alert = false,
    this.onEdit,
    this.onHold,
    this.onApproveShare,
  });

  @override
  Widget build(BuildContext context) {
    // The attention colour drives the icon badge; the card surface itself is
    // toned by [UgamCard] (warm vs danger).
    //
    // `dangerFill` instead of a hand-mixed `danger.withValues(alpha: 0.14)` —
    // the token exists precisely so this alpha stops drifting per call site
    // (see [UgamColorSet.dangerFill]), and the hand-mixed one sat lighter than
    // the real token in Daylight, where dangerFill is an opaque tint rather
    // than 14% of the ink.
    final Color toneInk = alert ? c.danger : c.warm;
    final Color toneFill = alert ? c.dangerFill : c.warmFill;

    return UgamCard.plain(
      // UgamCard.plain accepts a null onTap and then skips the press
      // animation, so an unresolvable card reads as a flat note.
      onTap: tappable ? onTap : null,
      tone: alert ? UgamCardTone.danger : UgamCardTone.warm,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: UgamScale.px(context, 38),
            height: UgamScale.px(context, 38),
            decoration: BoxDecoration(
              color: toneFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              alert
                  ? Icons.report_problem_rounded
                  : Icons.error_outline_rounded,
              size: UgamScale.px(context, 18),
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
                  const SizedBox(height: UgamSpacing.xs),
                ],
                if (passengerName != null) ...[
                  Text(
                    passengerName!,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.xs),
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
                  // Same chip the Requests card uses for the same concept, so
                  // the group tag stops changing size between the two screens.
                  UgamReqChip(
                    label: tr(
                      'seating_exceptions.group_label',
                      namedArgs: {'label': groupLabel!},
                    ),
                    variant: UgamChipVariant.neutral,
                    leading: Icons.group_rounded,
                  ),
                ],
                // Card actions sit as compact buttons aligned to the trailing
                // edge, never full-bleed: a stack of edge-to-edge buttons under
                // every card is a web card-footer, and it made each exception
                // read as its own page rather than an item in a list. Labels
                // stay — "Approve share" and "Hold" are not actions an icon
                // alone can carry. Wrap so a third action or a long
                // translation folds to the next line instead of overflowing.
                if (onEdit != null ||
                    onHold != null ||
                    onApproveShare != null) ...[
                  const SizedBox(height: UgamSpacing.md),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: UgamSpacing.sm,
                      runSpacing: UgamSpacing.sm,
                      children: [
                        if (onHold != null)
                          UgamButton(
                            label: tr('seating_exceptions.action_hold'),
                            icon: Icons.pause_circle_outline_rounded,
                            kind: UgamButtonKind.neutral,
                            onPressed: onHold,
                          ),
                        if (onEdit != null)
                          UgamButton(
                            label: tr('seating_exceptions.action_edit'),
                            icon: Icons.edit_note_rounded,
                            kind: UgamButtonKind.tonal,
                            onPressed: onEdit,
                          ),
                        // Primary last: on a trailing-aligned action row the
                        // rightmost button is the one the thumb reaches first.
                        if (onApproveShare != null)
                          UgamButton(
                            label: tr('seating_exceptions.action_approve_share'),
                            icon: Icons.people_alt_rounded,
                            kind: UgamButtonKind.tonal,
                            onPressed: onApproveShare,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: UgamSpacing.sm),
            Icon(
              Icons.chevron_right_rounded,
              size: UgamScale.px(context, 20),
              color: c.ink3,
            ),
          ],
        ],
      ),
    );
  }
}
