import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/seat_assignment.dart';
import '../models/seat_type.dart' show seatTypeLabel;
import '../routes/app_routes.dart';
import '../services/seating_engine.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/stranger_share_seat.dart';
import '../widgets/edit_request_sheet.dart';

part 'seating_exceptions/seating_exceptions_widgets.dart';

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
    existing.add(
      SeatAssignment(
        busId: target.busId,
        seatId: target.seatId,
        locked: true,
        leg: target.leg,
      ),
    );
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

  /// A group's name for the card chip: the label the agent typed, else its
  /// members ("Ramesh Patel +3") — never the raw [PassengerGroup.id] UUID.
  String? _groupDisplay(String? groupId) {
    final label = _groupLabel(groupId);
    if (label != null || groupId == null) return label;
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return null;
    final names = [
      for (final p in tour.passengers)
        if (p.groupId == groupId && p.name.trim().isNotEmpty) p.name.trim(),
    ];
    if (names.isEmpty) return null;
    if (names.length == 1) return names.first;
    return tr(
      'seating_exceptions.group_members',
      namedArgs: {'name': names.first, 'n': '${names.length - 1}'},
    );
  }

  /// The card's body copy, localized by exception KIND + its structured
  /// params. The engine's [SeatingException.message] is English-only (and
  /// for group kinds embeds the group UUID / bus ids), so it is used ONLY as
  /// the fallback for a kind this switch does not know. The passenger's name
  /// is already the card's title line, so the copy does not repeat it.
  String _messageFor(SeatingException ex) {
    final rl = ex.requestLine;
    switch (ex.type) {
      case SeatingExceptionType.priorityNoLowerBerth:
        return tr('priority.no_lower_msg');
      case SeatingExceptionType.sharedDoubleNeedsReview:
        return tr('seating_exceptions.msg_shared_double');
      case SeatingExceptionType.overflowWaitlist:
        if (rl == null) break;
        return tr(
          'seating_exceptions.msg_overflow',
          namedArgs: {'line': rl.label},
        );
      case SeatingExceptionType.seatTypeUnavailable:
        if (rl == null) break;
        return tr(
          'seating_exceptions.msg_seat_type',
          namedArgs: {
            'type': seatTypeLabel(rl.seatType, rl.position),
            'line': rl.label,
          },
        );
      case SeatingExceptionType.groupWontFit:
        return tr('seating_exceptions.msg_group_wont_fit');
      case SeatingExceptionType.brokenPair:
        return tr('seating_exceptions.msg_broken_pair');
    }
    return ex.message;
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
                        _exceptionCard(context, ex, c),
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

  /// One exception's card, wired to the remedies its kind allows.
  Widget _exceptionCard(
    BuildContext context,
    SeatingException ex,
    UgamColorSet c,
  ) {
    final isPriority = ex.type == SeatingExceptionType.priorityNoLowerBerth;
    final isShare = ex.type == SeatingExceptionType.sharedDoubleNeedsReview;
    // Overflow: Hold / Edit. Stranger-share: Approve /
    // Hold / Edit so the agent can broker without
    // rediscovering the pair in the grid.
    final canHoldOrEdit =
        ex.type == SeatingExceptionType.overflowWaitlist || isShare;
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: _ExceptionCard(
        // A bus-level exception resolves to no passenger,
        // so it gets neither the tap nor the chevron that
        // used to promise a destination and deliver a toast.
        tappable: _isTappable(ex),
        // Priority-no-lower-berth gets explicit alert copy
        // (title + message) so the consequence is legible
        // even without reading the engine's raw message.
        message: _messageFor(ex),
        title: isPriority ? tr('priority.no_lower_title') : null,
        passengerName: _passengerName(ex.passengerId),
        groupLabel: _groupDisplay(ex.groupId),
        // Priority misses are an ALERT, not a soft warm
        // note — render the card in danger tones, pinned by
        // the category order at the top of the list.
        alert: isPriority,
        onTap: () => _onExceptionTap(ex),
        onEdit: canHoldOrEdit ? () => _onEdit(context, ex) : null,
        onHold: canHoldOrEdit ? () => _onHold(ex) : null,
        onApproveShare: isShare ? () => _onApproveShare(context, ex) : null,
        c: c,
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

  static String _categoryFor(SeatingExceptionType type) => switch (type) {
    SeatingExceptionType.priorityNoLowerBerth => _Category.priority,
    SeatingExceptionType.groupWontFit ||
    SeatingExceptionType.brokenPair ||
    SeatingExceptionType.sharedDoubleNeedsReview => _Category.groups,
    SeatingExceptionType.seatTypeUnavailable => _Category.seatType,
    SeatingExceptionType.overflowWaitlist => _Category.waitlist,
  };
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
String _categoryLabel(String key) => switch (key) {
  _Category.priority => tr('seating_exceptions.cat_priority'),
  _Category.groups => tr('seating_exceptions.cat_groups'),
  _Category.seatType => tr('seating_exceptions.cat_seat_type'),
  _Category.waitlist => tr('seating_exceptions.cat_waitlist'),
  _ => key,
};

class _Section {
  final String label;
  final List<SeatingException> items;
  const _Section({required this.label, required this.items});
}
