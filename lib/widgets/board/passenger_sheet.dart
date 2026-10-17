/// **One sheet, opened from any lens, showing the whole passenger.**
///
/// Three surfaces do this job today and each does it differently:
///
///  * `widgets/occupant_action_sheet.dart` — the seating sheet: a person toggle
///    for a shared sofa, call, move/swap, edit request, priority, handler, seat
///    flags, free, cancel-return.
///  * `screens/seating_exceptions_screen.dart` — the decision list: the
///    passenger's name, their group, and inline remedies.
///  * `screens/requests_screen.dart` — the roster: name, phone, pickup, group,
///    priority and cancellation badges, one-tap call, edit request.
///
/// A handler chasing a no-show currently leaves the chart to find a number; an
/// agent fixing a seat opens a different sheet from the one that shows the
/// money. This is the single sheet all of that collapses into, and **the only
/// thing that changes between the five lenses is which action is under the
/// thumb** (spec §5): Call on occupancy and pickup, Collect on money, Check-in
/// on boarding, Move on group. Every other action stays available as a
/// secondary row, so switching lens never *removes* a capability — it only
/// re-ranks them.
///
/// Two rules the sheet enforces rather than trusting its callers with:
///
///  * **Money actions confirm first** (spec §8). Collecting cash and returning
///    change cannot be silently reversed downstream, so neither fires straight
///    off the tap.
///  * **Every mutation raises an undo** (spec §8). The mutation callbacks hand
///    back a [PassengerSheetUndo]; the sheet is what puts it on screen.
///
/// The sheet owns NO repository. Berth facts arrive as a [BoardBerth], identity
/// as a [Passenger], and the writes it cannot own (collect, check in) arrive as
/// callbacks — which is what keeps it testable and what lets the Board, the
/// handler shell and (later) the retired screens all mount the same widget.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../components/seat_chart_tile.dart';
import '../../controllers/tour_controller.dart';
import '../../design/components/ugam_tappable.dart';
import '../../design/ugam.dart';
import '../../models/board_lens.dart';
import '../../models/bus_details.dart';
import '../../models/passenger.dart';
import '../../models/seat_assignment.dart';
import '../../models/tour_status.dart';
import '../../models/trip_type.dart';
import '../../services/seat_move_flow.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import '../../utils/passenger_display.dart';
import '../../utils/seat_leg_cancel.dart';
import '../../utils/phone_dialer.dart';
import '../edit_request_sheet.dart';

part 'passenger_sheet_undo_toast.dart';
part 'passenger_sheet_actions.dart';
part 'passenger_sheet_sections.dart';
part 'passenger_sheet_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Value types
// ─────────────────────────────────────────────────────────────────────────────

/// What a completed Board mutation hands back: the sentence to show, and the
/// way to take it back.
///
/// Undo is not decoration here. Assign, move, collect and check-in all write
/// real operational state, at speed, usually by a tired person at 5am, and the
/// toast is the only place the write can be caught before it syncs (spec §8).
/// Message and undo travel together so "a toast with nothing to tap" is
/// unrepresentable.
@immutable
class PassengerSheetUndo {
  /// Already translated, already formatted. One line.
  final String message;

  /// Reverses the write. Called at most once — the toast dismisses itself the
  /// moment it fires.
  final FutureOr<void> Function() undo;

  /// Screen-reader label for the undo control. A bare "Undo" tells a TalkBack
  /// user nothing about *what*, so prefer "undo collecting ₹550 from Priti
  /// Patel".
  final String? semanticLabel;

  const PassengerSheetUndo({
    required this.message,
    required this.undo,
    this.semanticLabel,
  });
}

/// One person on the tapped berth.
///
/// A pair rather than a bare [Passenger] because a shared Double Sofa holds two
/// people with genuinely different money and boarding state — collapsing them
/// onto one [BoardBerth] is what made the old sheet show the first occupant's
/// balance against the second occupant's name.
///
/// [passenger] is nullable on purpose: an anonymised stranger-share berth is
/// occupied and has no roster row behind it. The sheet then renders every fact
/// the berth knows and quietly drops the actions that need a person.
@immutable
class PassengerSheetOccupant {
  final BoardBerth berth;
  final Passenger? passenger;

  const PassengerSheetOccupant({required this.berth, this.passenger});

  /// The contact-directory name where one exists, the roster name otherwise,
  /// and the berth's own recorded name as the last resort.
  String get name {
    final p = passenger;
    if (p != null && p.name.trim().isNotEmpty) return p.displayName;
    final onBerth = berth.occupantName?.trim();
    if (onBerth != null && onBerth.isNotEmpty) return onBerth;
    return '';
  }

  String get phone => passenger?.phone.trim() ?? '';
}

/// What the sheet popped with, so the Board knows whether to auto-advance the
/// aisle walk (spec §4: "completing the action auto-advances to the next one").
@immutable
class PassengerSheetResult {
  final BoardAction action;

  /// False when the sheet was dismissed or the write failed — the walk must
  /// then stay where it is rather than skipping somebody.
  final bool completed;

  const PassengerSheetResult({required this.action, required this.completed});
}

// ─────────────────────────────────────────────────────────────────────────────
// The sheet
// ─────────────────────────────────────────────────────────────────────────────

/// Signature of a Board write. Returns the undo, or null when the write cannot
/// be reversed (the sheet then shows a plain confirmation instead of lying
/// about an undo that does nothing).
typedef PassengerSheetWrite = Future<PassengerSheetUndo?> Function();

class PassengerSheet extends StatefulWidget {
  /// One entry, or two for a shared sofa. Never empty — [show] returns early
  /// rather than presenting a sheet about nobody.
  final List<PassengerSheetOccupant> occupants;

  /// The active lens. The ONLY thing it changes here is which action is
  /// primary — every other action stays in the secondary list.
  final BoardLens lens;

  final String tourId;
  final String busId;
  final String busName;

  /// The berth this sheet was opened from, as the layout knows it. Distinct
  /// from [BoardBerth.code], which is what is printed on the coach.
  final String seatId;

  /// Takes [amount] in rupees and records it against `rider` — the occupant
  /// the sheet is showing, which on a shared sofa is the one the agent picked.
  /// Confirmed first, always.
  final Future<PassengerSheetUndo?> Function(double amount, Passenger? rider)?
  onCollect;

  /// Hands [amount] of over-collected cash back. Confirmed first, always.
  final Future<PassengerSheetUndo?> Function(double amount)? onReturnChange;

  /// Marks the occupant aboard (`true`) or back to expected (`false`).
  final Future<PassengerSheetUndo?> Function(bool boarded)? onCheckIn;

  /// Overrides the built-in "free this berth" write. Without it the sheet frees
  /// the berth through [TourController] and builds its own undo.
  final PassengerSheetWrite? onFree;

  /// Forwarded to [SeatMoveFlow.start]: when set, picking a destination bus
  /// hands control back to the canvas so the agent taps the target berth by
  /// hand instead of the auto swap-assistant opening.
  final void Function(
    Bus destination,
    Passenger mover,
    String sourceBusId,
    String fromSeatId,
  )?
  onRelocateToBus;

  /// Strike ONE leg from THIS berth for this occupant. The caller owns the
  /// confirm + cancel + guided-rebook flow, exactly as the occupant sheet does,
  /// and [cancellableSeatLegs] decides which legs are offerable on both.
  final void Function(Passenger occupant, TripType strike)? onCancelSeatLeg;

  /// Opens the Hold / Premium flag sheet for THIS berth (not the occupant).
  final VoidCallback? onSeatFlags;

  const PassengerSheet({
    super.key,
    required this.occupants,
    required this.lens,
    required this.tourId,
    required this.busId,
    required this.busName,
    required this.seatId,
    this.onCollect,
    this.onReturnChange,
    this.onCheckIn,
    this.onFree,
    this.onRelocateToBus,
    this.onCancelSeatLeg,
    this.onSeatFlags,
  });

  /// Presents the sheet on [UgamSheet], which now carries level-2 elevation and
  /// the stronger scrim. Returns null when dismissed without acting.
  static Future<PassengerSheetResult?> show(
    BuildContext context, {
    required List<PassengerSheetOccupant> occupants,
    required BoardLens lens,
    required String tourId,
    required String busId,
    required String busName,
    required String seatId,
    Future<PassengerSheetUndo?> Function(double amount, Passenger? rider)?
    onCollect,
    Future<PassengerSheetUndo?> Function(double amount)? onReturnChange,
    Future<PassengerSheetUndo?> Function(bool boarded)? onCheckIn,
    PassengerSheetWrite? onFree,
    void Function(
      Bus destination,
      Passenger mover,
      String sourceBusId,
      String fromSeatId,
    )?
    onRelocateToBus,
    void Function(Passenger occupant, TripType strike)? onCancelSeatLeg,
    VoidCallback? onSeatFlags,
  }) {
    if (occupants.isEmpty) return Future.value(null);
    return UgamSheet.show<PassengerSheetResult>(
      context,
      showClose: false,
      builder: (_) => PassengerSheet(
        occupants: occupants,
        lens: lens,
        tourId: tourId,
        busId: busId,
        busName: busName,
        seatId: seatId,
        onCollect: onCollect,
        onReturnChange: onReturnChange,
        onCheckIn: onCheckIn,
        onFree: onFree,
        onRelocateToBus: onRelocateToBus,
        onCancelSeatLeg: onCancelSeatLeg,
        onSeatFlags: onSeatFlags,
      ),
    );
  }

  @override
  State<PassengerSheet> createState() => _PassengerSheetState();
}

class _PassengerSheetState extends State<PassengerSheet> {
  /// Which occupant of a shared sofa is being acted on.
  int _idx = 0;

  /// Set while a write is in flight so a double tap cannot fire it twice — the
  /// exact failure mode of a cash round done at speed.
  bool _busy = false;

  PassengerSheetOccupant get _occ => widget.occupants[_idx];

  /// `setState` for the part-file extensions (it is protected on [State]).
  void _update(VoidCallback fn) => setState(fn);

  BoardBerth get _berth => _occ.berth;

  /// Null when the controller is not registered (a widget test, the customer
  /// app). Every row that needs it is dropped rather than throwing.
  TourController? get _ctrl =>
      Get.isRegistered<TourController>() ? Get.find<TourController>() : null;

  /// Which legs of THIS berth can be struck for [occ] — the same shared gate
  /// the seat chart's occupant sheet uses, so the two surfaces never disagree.
  ({bool go, bool ret}) _strikeable(Passenger occ) {
    final tour = _ctrl?.getTour(widget.tourId);
    // Locked only: before the tour locks, a rider who isn't travelling is an
    // ordinary request edit, not a leg strike.
    if (tour == null || tour.status != TourStatus.locked) {
      return (go: false, ret: false);
    }
    return cancellableSeatLegs(
      occ,
      busId: widget.busId,
      seatId: widget.seatId,
      goLegCompleted: tour.goLegCompleted,
    );
  }

  /// Re-read from the controller so an in-context priority / handler toggle
  /// shows immediately without closing the sheet.
  Passenger? get _livePassenger {
    final p = _occ.passenger;
    if (p == null) return null;
    final tour = _ctrl?.getTour(widget.tourId);
    return tour?.passengers.firstWhereOrNull((x) => x.id == p.id) ?? p;
  }

  bool get _isHandlerOfThisBus {
    final p = _occ.passenger;
    if (p == null) return false;
    final bus = _ctrl
        ?.getTour(widget.tourId)
        ?.buses
        .firstWhereOrNull((b) => b.id == widget.busId);
    return bus?.handlerPassengerId == p.id;
  }

  // ── Capability gates ────────────────────────────────────────

  bool _can(BoardAction action) {
    if (_busy) return false;
    switch (action) {
      case BoardAction.call:
        return _occ.phone.isNotEmpty;
      case BoardAction.collect:
        return widget.onCollect != null && _berth.outstanding > 0;
      case BoardAction.move:
        return _occ.passenger != null && _ctrl != null;
      case BoardAction.checkIn:
        return widget.onCheckIn != null &&
            _berth.isOccupied &&
            _berth.boarding != BerthBoarding.boarded;
    }
  }

  /// The amount a secondary/primary row advertises, or null when the action
  /// carries no figure.
  String? _trailingFor(BoardAction action) {
    if (action != BoardAction.collect) return null;
    final due = _berth.outstanding;
    return due > 0 ? Formatters.formatMoneyInr(due) : null;
  }

  // ── Copy helpers ────────────────────────────────────────────

  /// `board_berth.unnamed` is the berth tile's own word for an occupant with no
  /// name on file — reused so a de-anonymised stranger-share berth reads the
  /// same in the sheet as it does on the canvas.
  String get _displayName {
    final n = _occ.name;
    return n.isEmpty ? tr('board_berth.unnamed') : n;
  }

  /// Round trip / one-way. Read from the request LINES via
  /// [Passenger.effectiveTripType], never the raw `tripType` column, which
  /// defaults to round-trip and is never stamped for a request-mode booking.
  String? get _legLabel {
    final p = _occ.passenger;
    if (p == null) return null;
    return tr(switch (p.effectiveTripType) {
      TripType.roundTrip => 'seat_detail.indicator.round_trip',
      TripType.outboundOnly => 'seat_detail.indicator.go_outbound',
      TripType.returnOnly => 'seat_detail.indicator.ret_return',
    });
  }

  /// Payment state in words, from the money lens, whichever lens is active —
  /// "paid" is a fact about the passenger, not about how you are looking at
  /// them.
  String get _paymentLabel => const MoneyLens().stateLabel(_berth);

  /// Spec §11's full berth label — *"DL3, Priti Patel, paid, double sofa,
  /// boarding at Adajan"* — plus the two facts the lens cannot know about and
  /// which are otherwise carried by a coloured chip alone: an approved priority
  /// and a pending cancellation. The bus name is appended because on a two-bus
  /// tour "DL3" names two different berths.
  String get _semanticLabel {
    final p = _livePassenger;
    return <String>[
      widget.lens.semanticLabel(_berth),
      widget.busName,
      if (_ladiesIsHidden) tr('board_lens.state_ladies'),
      if (p?.isPriorityApproved ?? false) tr('requests.chip.priority'),
      if (_occ.passenger?.isCancelRequested ?? false)
        tr('requests.chip.cancel_requested'),
    ].where((s) => s.trim().isNotEmpty).join(', ');
  }

  /// The rider's own note — "travelling with elder parents", "wants the front
  /// berth". `requests_screen` shows this on the expanded row and nothing on
  /// the seating side ever has, which is exactly the split the Board closes:
  /// the person who needs it is the handler standing at the door, not the agent
  /// reading the roster a week earlier. Null when there is nothing to say.
  String? get _noteText {
    final note = _occ.passenger?.note?.trim();
    return (note == null || note.isEmpty) ? null : note;
  }

  /// Whether "a lady is seated here" would otherwise be invisible.
  ///
  /// Ladies is a fact about the BERTH, not about the lens looking at it, but
  /// only [OccupancyLens] colours by it — so on the other four lenses the rose
  /// fill is gone from the canvas and the state chip says something else
  /// entirely. Surfacing it here is spec §11's "colour is never the only
  /// signal" applied across the lens switch: the fact must not disappear
  /// because the handler changed what they were looking at. Under occupancy the
  /// state chip already carries it, and a second chip would just be noise.
  bool get _ladiesIsHidden =>
      _berth.isLadies && widget.lens.id != BoardLensId.occupancy;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final berth = _berth;
    final shared = widget.occupants.length > 1;
    final primary = widget.lens.primaryAction;
    final p = _livePassenger;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A genuinely shared sofa surfaces BOTH people, and every action
          // below retargets to whoever is selected.
          if (shared) ...[
            UgamTabPills(
              currentIndex: _idx,
              onChanged: (i) => setState(() => _idx = i),
              items: [
                for (final o in widget.occupants)
                  UgamTabItem(label: o.name.isEmpty ? berth.code : o.name),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
          ],

          _header(context, c),
          const SizedBox(height: UgamSpacing.lg),

          // Phone: one tap, from any lens.
          _PhoneRow(phone: _occ.phone, onCall: _call),
          const SizedBox(height: UgamSpacing.md),

          // The lens's action, and the only thing that differs between lenses.
          UgamButton(
            label: primary.label,
            icon: _iconFor(primary),
            kind: UgamButtonKind.primary,
            expand: true,
            loading: _busy,
            onPressed: _can(primary) ? () => _runAction(primary) : null,
          ),

          const SizedBox(height: UgamSpacing.lg),
          _facts(context, c),

          // The rider's own words. Prose, so it sits below the fact grid rather
          // than being squeezed into a column beside "Fare".
          if (_noteText != null) ...[
            const SizedBox(height: UgamSpacing.md),
            _NoteBox(note: _noteText!),
          ],

          const SizedBox(height: UgamSpacing.lg),

          UgamSectionLabel(tr('passenger_sheet.more_actions'), color: c.ink3),
          const SizedBox(height: UgamSpacing.sm),

          // Every OTHER lens action stays available — this is what makes one
          // sheet serve five lenses without any of them losing a capability.
          for (final action in BoardAction.values)
            if (action != primary)
              _ActionRow(
                icon: _iconFor(action),
                label: action.label,
                trailing: _trailingFor(action),
                onTap: _can(action) ? () => _runAction(action) : null,
              ),

          // Boarding correction — the check-in that has already happened.
          if (widget.onCheckIn != null &&
              berth.boarding == BerthBoarding.boarded)
            _ActionRow(
              icon: Icons.remove_circle_outline_rounded,
              label: tr('passenger_sheet.action_undo_check_in'),
              onTap: _busy ? null : () => unawaited(_checkIn(false)),
            ),

          // The handler is holding change that belongs to the rider.
          if (widget.onReturnChange != null && berth.changeOwed > 0)
            _ActionRow(
              icon: Icons.currency_rupee_rounded,
              label: tr('passenger_sheet.action_return_change'),
              trailing: Formatters.formatMoneyInr(berth.changeOwed),
              onTap: _busy ? null : () => unawaited(_returnChange()),
            ),

          // Carried over from the occupant sheet + the requests roster.
          if (p != null && _ctrl != null) ...[
            _ActionRow(
              icon: Icons.edit_outlined,
              label: tr('occupant_sheet.edit_request'),
              onTap: _busy ? null : () => unawaited(_editRequest()),
            ),
            _ActionRow(
              icon: p.isPriorityApproved
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              label: p.isPriorityApproved
                  ? tr('occupant.remove_priority')
                  : tr('occupant.make_priority'),
              accent: p.isPriorityApproved,
              onTap: _busy ? null : () => unawaited(_togglePriority()),
            ),
            _ActionRow(
              icon: _isHandlerOfThisBus
                  ? Icons.verified_user_rounded
                  : Icons.shield_outlined,
              label: _isHandlerOfThisBus
                  ? tr('occupant.is_handler')
                  : tr('occupant.make_handler'),
              accent: _isHandlerOfThisBus,
              onTap: _busy ? null : () => unawaited(_toggleHandler()),
            ),
          ],

          if (widget.onSeatFlags != null)
            _ActionRow(
              icon: Icons.tune_rounded,
              label: tr('occupant_sheet.seat_flags'),
              onTap: _busy
                  ? null
                  : () {
                      Navigator.of(context).maybePop();
                      widget.onSeatFlags!();
                    },
            ),

          if (berth.isOccupied && (_occ.passenger != null || widget.onFree != null))
            _ActionRow(
              icon: Icons.person_remove_rounded,
              label: tr('occupant_sheet.free'),
              danger: true,
              onTap: _busy ? null : () => unawaited(_free()),
            ),

          // Strike ONE leg from THIS berth. Seat-scoped so a party keeps the
          // seats it is still travelling on; the gate is shared with the seat
          // chart's occupant sheet so both offer the same thing here.
          if (widget.onCancelSeatLeg != null && p != null) ...[
            if (_strikeable(p).ret)
              _ActionRow(
                icon: Icons.event_busy_rounded,
                label: tr('tour_detail.cancel_return_seat'),
                danger: true,
                onTap: _busy
                    ? null
                    : () {
                        Navigator.of(context).maybePop();
                        widget.onCancelSeatLeg!(p, TripType.returnOnly);
                      },
              ),
            if (_strikeable(p).go)
              _ActionRow(
                icon: Icons.logout_rounded,
                label: tr('tour_detail.cancel_go_seat'),
                danger: true,
                onTap: _busy
                    ? null
                    : () {
                        Navigator.of(context).maybePop();
                        widget.onCancelSeatLeg!(p, TripType.outboundOnly);
                      },
              ),
          ],
        ],
      ),
    );
  }
}
