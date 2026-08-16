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
// The undo toast host
// ─────────────────────────────────────────────────────────────────────────────

/// Puts a [UgamSnackbar] carrying an undo action into the ROOT overlay.
///
/// TEMPORARY, AND DELIBERATELY SMALL. The app's imperative toast API
/// (`lib/utils/app_snackbar.dart`) has no `action:` parameter yet — it predates
/// [UgamSnackAction], so there is currently no way to raise an undoable toast
/// through it. Rather than block the Board on that file (owned elsewhere this
/// run), this hosts the same widget in the same place with the same dwell.
/// **When `AppSnackBar` grows an action parameter, delete this class and call
/// it instead** — the two must not both exist for long, or a Board toast and an
/// app toast will stack on top of each other.
///
/// The root overlay is used so the toast outlives the sheet that raised it: the
/// mutation pops the sheet, and the undo has to still be reachable after that.
class BoardUndoToast {
  const BoardUndoToast._();

  static OverlayEntry? _live;
  static Timer? _timer;

  /// [overlay] is captured by the caller BEFORE its `await`, so no
  /// [BuildContext] crosses an async gap.
  ///
  /// [onUndo] null renders a plain confirmation with no action — used when the
  /// write genuinely cannot be reversed, which the caller has to say out loud
  /// rather than us guessing.
  static void show(
    OverlayState? overlay, {
    required String message,
    FutureOr<void> Function()? onUndo,
    String? semanticLabel,
  }) {
    if (overlay == null || !overlay.mounted) return;
    // One toast at a time. A collection round fires these several a minute and
    // a stack of them would bury the chart.
    dismiss();

    final entry = OverlayEntry(
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        // Above the keyboard when it is up, above the floating dock when it is
        // down — the same arithmetic AppSnackBar uses, from the same token.
        final lift = media.viewInsets.bottom > 0
            ? media.viewInsets.bottom
            : media.padding.bottom + UgamSnackbar.dockClearance;
        return Positioned(
          left: UgamSpacing.gutter,
          right: UgamSpacing.gutter,
          bottom: lift + UgamSpacing.md,
          child: UgamSnackbar(
            message: message,
            tone: UgamSnackTone.success,
            action: onUndo == null
                ? null
                : UgamSnackAction.undo(
                    onUndo: () {
                      dismiss();
                      onUndo();
                    },
                    semanticLabel: semanticLabel,
                  ),
          ),
        );
      },
    );
    _live = entry;
    overlay.insert(entry);
    // An actionable toast gets the doubled dwell: reading it, realising it is
    // wrong, and reaching for undo is three steps, not one.
    _timer = Timer(
      onUndo == null ? UgamMotion.snackbar : UgamSnackbar.actionDuration,
      dismiss,
    );
  }

  /// Safe to call at any time, including from a test `tearDown`.
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _live;
    _live = null;
    if (entry != null && entry.mounted) entry.remove();
  }
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

  /// Takes [amount] in rupees and records it. Confirmed first, always.
  final Future<PassengerSheetUndo?> Function(double amount)? onCollect;

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
    Future<PassengerSheetUndo?> Function(double amount)? onCollect,
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

  // ── Actions ─────────────────────────────────────────────────

  void _runAction(BoardAction action) {
    switch (action) {
      case BoardAction.call:
        _call();
      case BoardAction.collect:
        unawaited(_collect());
      case BoardAction.move:
        _move();
      case BoardAction.checkIn:
        unawaited(_checkIn(true));
    }
  }

  /// One tap, from any lens. This is the whole reason the sheet exists for a
  /// handler chasing a no-show.
  void _call() {
    final phone = _occ.phone;
    if (phone.isEmpty) return;
    HapticFeedback.selectionClick();
    unawaited(PhoneDialer.call(phone));
  }

  /// Money confirms first (spec §8) — a collection cannot be silently reversed
  /// downstream, so it never fires straight off the tap.
  Future<void> _collect() async {
    final amount = _berth.outstanding;
    final collect = widget.onCollect;
    if (collect == null || amount <= 0) return;

    final ok = await UgamDialog.confirm(
      context,
      title: tr('passenger_sheet.confirm_collect_title'),
      message: tr(
        'passenger_sheet.confirm_collect_body',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('passenger_sheet.confirm_collect_action'),
      confirmIcon: Icons.payments_rounded,
    );
    if (!ok || !mounted) return;

    await _write(
      BoardAction.collect,
      () => collect(amount),
      fallback: tr(
        'passenger_sheet.collected_toast',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
    );
  }

  /// The other money action: the handler is holding change that belongs to the
  /// rider. Same confirm rule.
  Future<void> _returnChange() async {
    final amount = _berth.changeOwed;
    final give = widget.onReturnChange;
    if (give == null || amount <= 0) return;

    final ok = await UgamDialog.confirm(
      context,
      title: tr('passenger_sheet.confirm_return_title'),
      message: tr(
        'passenger_sheet.confirm_return_body',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('passenger_sheet.confirm_return_action'),
      confirmIcon: Icons.undo_rounded,
    );
    if (!ok || !mounted) return;

    await _write(
      BoardAction.collect,
      () => give(amount),
      fallback: tr(
        'passenger_sheet.returned_toast',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
    );
  }

  Future<void> _checkIn(bool boarded) async {
    final tick = widget.onCheckIn;
    if (tick == null) return;
    await _write(
      BoardAction.checkIn,
      () => tick(boarded),
      fallback: tr(
        boarded
            ? 'passenger_sheet.checked_in_toast'
            : 'passenger_sheet.checked_out_toast',
        namedArgs: {'name': _displayName},
      ),
    );
  }

  /// The move/swap flow spans two screens today. Reuse it rather than
  /// reimplementing: destination-bus picker → swap assistant → move/swap,
  /// including across buses, with the group cascade already handled.
  void _move() {
    final mover = _occ.passenger;
    if (mover == null || _ctrl == null) return;
    // Anchor the flow to the ROOT navigator BEFORE popping. Our own context is
    // being torn down by the pop, and [SeatMoveFlow.start] opens its picker
    // against whatever it is handed — the same "deactivated widget's ancestor
    // is unsafe" trap that file documents at length.
    final root = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).maybePop(
      const PassengerSheetResult(action: BoardAction.move, completed: true),
    );
    SeatMoveFlow.start(
      root.context,
      tourId: widget.tourId,
      sourceBusId: widget.busId,
      mover: mover,
      fromSeatId: widget.seatId,
      onRelocateToBus: widget.onRelocateToBus,
    );
  }

  /// Free this occupant's berth(s) — they keep their request and drop back into
  /// the pending pool, ready to be re-seated. The undo puts the exact previous
  /// allocation back, which is why it is built here from the list we replaced
  /// rather than being re-derived later.
  Future<void> _free() async {
    final override = widget.onFree;
    if (override != null) {
      await _write(
        BoardAction.move,
        override,
        fallback: tr(
          'passenger_sheet.freed_toast',
          namedArgs: {'name': _displayName, 'seat': _berth.code},
        ),
      );
      return;
    }

    final ctrl = _ctrl;
    final occ = _occ.passenger;
    if (ctrl == null || occ == null) return;

    final before = List<SeatAssignment>.from(occ.assignedSeats);
    final after = before
        .where((a) => !(a.busId == widget.busId && a.seatId == widget.seatId))
        .toList();
    if (after.length == before.length) return;

    await _write(
      BoardAction.move,
      () async {
        await ctrl.assignSeats(widget.tourId, occ.id, after);
        return PassengerSheetUndo(
          message: tr(
            'passenger_sheet.freed_toast',
            namedArgs: {'name': _displayName, 'seat': _berth.code},
          ),
          semanticLabel: tr(
            'passenger_sheet.undo_free_semantic',
            namedArgs: {'name': _displayName, 'seat': _berth.code},
          ),
          undo: () => ctrl.assignSeats(widget.tourId, occ.id, before),
        );
      },
      fallback: tr(
        'passenger_sheet.freed_toast',
        namedArgs: {'name': _displayName, 'seat': _berth.code},
      ),
    );
  }

  /// The one path every mutation goes through: run it, buzz, close the sheet so
  /// the Board can auto-advance the aisle walk, and raise the undo.
  Future<void> _write(
    BoardAction action,
    PassengerSheetWrite body, {
    required String fallback,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);

    // Captured BEFORE the await: no BuildContext crosses the async gap, and the
    // toast still lands after the sheet has popped.
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final navigator = Navigator.of(context);

    PassengerSheetUndo? undo;
    var ok = true;
    try {
      undo = await body();
    } catch (_) {
      ok = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!ok) {
      AppSnackBar.error(tr('passenger_sheet.write_failed'));
      return;
    }

    HapticFeedback.lightImpact();
    navigator.maybePop(
      PassengerSheetResult(action: action, completed: true),
    );
    BoardUndoToast.show(
      overlay,
      message: undo?.message ?? fallback,
      onUndo: undo?.undo,
      semanticLabel: undo?.semanticLabel,
    );
  }

  Future<void> _editRequest() async {
    final tour = _ctrl?.getTour(widget.tourId);
    final p = _occ.passenger;
    if (tour == null || p == null) return;
    // Same root-navigator anchoring as [_move]: the editor is opened AFTER this
    // sheet has been popped, so it cannot be hung off our dying context.
    final root = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).maybePop();
    await EditRequestSheet.show(
      context: root.context,
      tour: tour,
      passenger: p,
    );
  }

  Future<void> _togglePriority() async {
    final ctrl = _ctrl;
    final p = _livePassenger;
    if (ctrl == null || p == null) return;
    final approved = p.isPriorityApproved;
    if (!approved) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('priority.alert_title'),
        message: tr('priority.alert_msg'),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('priority.alert_confirm'),
        confirmIcon: Icons.star_rounded,
      );
      if (!ok) return;
    }
    await ctrl.setPassengerPriority(widget.tourId, p.id, !approved);
    if (mounted) setState(() {});
  }

  Future<void> _toggleHandler() async {
    final ctrl = _ctrl;
    final p = _occ.passenger;
    if (ctrl == null || p == null) return;
    if (_isHandlerOfThisBus) {
      await ctrl.removeBusHandler(widget.tourId, widget.busId);
    } else {
      await ctrl.setBusHandler(widget.tourId, widget.busId, p.id);
    }
    if (mounted) setState(() {});
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
    switch (p.effectiveTripType) {
      case TripType.roundTrip:
        return tr('seat_detail.indicator.round_trip');
      case TripType.outboundOnly:
        return tr('seat_detail.indicator.go_outbound');
      case TripType.returnOnly:
        return tr('seat_detail.indicator.ret_return');
    }
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

  // ── Pieces ──────────────────────────────────────────────────

  /// Initial disc + name + berth code/type + the lens's word for this berth.
  ///
  /// The whole block carries ONE semantic node holding the full spec §11 label
  /// ("DL3, Priti Patel, paid, double sofa, boarding at Adajan") rather than
  /// four nodes a screen reader would read as disconnected fragments.
  Widget _header(BuildContext context, UgamColorSet c) {
    final berth = _berth;
    final paint = widget.lens.paint(berth, c);
    final name = _displayName;

    return Semantics(
      container: true,
      label: _semanticLabel,
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: UgamScale.px(context, 46),
              height: UgamScale.px(context, 46),
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                SeatChartTile.initials(name),
                style: UgamText.bodyStrong.copyWith(color: c.onAccent),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: UgamText.titleM.copyWith(color: c.ink),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr(
                      'occupant_sheet.seat_on',
                      namedArgs: {
                        'seat': berth.code,
                        'bus': widget.busName,
                      },
                    ),
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  // The scannable identity row: code · type · state. The berth
                  // CODE is a chip of its own rather than only living inside
                  // the sentence above — it is the one string a handler reads
                  // out loud ("DL3?"), and it must survive at a glance.
                  //
                  // Colour is never the only signal: the state chip carries the
                  // lens's glyph as well as its fill.
                  Wrap(
                    spacing: UgamSpacing.sm,
                    runSpacing: UgamSpacing.xs,
                    children: [
                      UgamReqChip(
                        label: berth.code,
                        variant: UgamChipVariant.accent,
                      ),
                      _GlyphChip(
                        glyph: paint.glyph,
                        label: widget.lens.stateLabel(berth),
                        fill: paint.fill,
                        ink: paint.ink,
                      ),
                      // The same `♀` the occupancy lens paints, carried across
                      // the other four lenses so the fact survives the switch.
                      if (_ladiesIsHidden)
                        _GlyphChip(
                          glyph: '♀',
                          label: tr('board_lens.state_ladies'),
                          fill: c.warmFill,
                          ink: c.warm,
                          variant: UgamChipVariant.warm,
                        ),
                      if (berth.seatTypeLabel != null &&
                          berth.seatTypeLabel!.trim().isNotEmpty)
                        UgamReqChip(
                          label: berth.seatTypeLabel!,
                          variant: UgamChipVariant.neutral,
                          leading: Icons.event_seat_rounded,
                        ),
                      if (_livePassenger?.isPriorityApproved ?? false)
                        UgamReqChip(
                          label: tr('requests.chip.priority').toUpperCase(),
                          variant: UgamChipVariant.warm,
                          leading: Icons.star_rounded,
                        ),
                      if (_occ.passenger?.isCancelRequested ?? false)
                        UgamReqChip(
                          label: tr(
                            'requests.chip.cancel_requested',
                          ).toUpperCase(),
                          variant: UgamChipVariant.danger,
                          leading: Icons.report_problem_rounded,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Leg, pickup, group, fare — everything the three old surfaces each showed
  /// some of. Two columns where there is room, one where a Gujarati value needs
  /// the whole width.
  Widget _facts(BuildContext context, UgamColorSet c) {
    final berth = _berth;
    final leg = _legLabel;

    final facts = <(String, String)>[
      if (leg != null) (tr('passenger_sheet.field_leg'), leg),
      (tr('passenger_sheet.field_payment'), _paymentLabel),
      (
        tr('passenger_sheet.field_pickup'),
        (berth.pickupStopName?.trim().isNotEmpty ?? false)
            ? berth.pickupStopName!
            : tr('board_lens.state_no_stop'),
      ),
      (
        tr('passenger_sheet.field_group'),
        (berth.groupName?.trim().isNotEmpty ?? false)
            ? berth.groupName!
            : tr('board_lens.state_no_group'),
      ),
      (
        tr('passenger_sheet.field_fare'),
        Formatters.formatMoneyInr(berth.fareDue),
      ),
      (tr('passenger_sheet.field_paid'), Formatters.formatMoneyInr(berth.paid)),
      if (berth.outstanding > 0)
        (
          tr('passenger_sheet.field_due'),
          Formatters.formatMoneyInr(berth.outstanding),
        ),
      if (berth.changeOwed > 0)
        (
          tr('passenger_sheet.field_change'),
          Formatters.formatMoneyInr(berth.changeOwed),
        ),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        // Below this a Gujarati label + its value cannot share a line with a
        // second column without both truncating.
        const twoColumnFloor = 280.0;
        final columns = box.maxWidth >= twoColumnFloor ? 2 : 1;
        final width = columns == 1
            ? box.maxWidth
            : (box.maxWidth - UgamSpacing.md) / 2;
        return Wrap(
          spacing: UgamSpacing.md,
          runSpacing: UgamSpacing.md,
          children: [
            for (final (label, value) in facts)
              SizedBox(
                width: width,
                child: _Fact(label: label, value: value, c: c),
              ),
          ],
        );
      },
    );
  }

  static IconData _iconFor(BoardAction action) {
    switch (action) {
      case BoardAction.call:
        return Icons.call_rounded;
      case BoardAction.collect:
        return Icons.payments_rounded;
      case BoardAction.move:
        return Icons.swap_horiz_rounded;
      case BoardAction.checkIn:
        return Icons.how_to_reg_rounded;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small parts
// ─────────────────────────────────────────────────────────────────────────────

/// The number, visible and dialable in one tap.
///
/// Visible rather than hidden behind a "Call" button on purpose: a handler at a
/// pickup point often wants to read the number out to somebody, and going back
/// to a list screen to find it is the pattern the Board exists to delete.
class _PhoneRow extends StatelessWidget {
  final String phone;
  final VoidCallback onCall;

  const _PhoneRow({required this.phone, required this.onCall});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final has = phone.isNotEmpty;

    final body = Container(
      constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: has ? c.accentFill : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(
          color: has ? c.accent.withValues(alpha: 0.28) : c.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            has ? Icons.call_rounded : Icons.phone_disabled_rounded,
            size: UgamScale.px(context, 20),
            color: has ? c.accent : c.ink3,
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              has ? phone : tr('seat_detail.roster.no_mobile'),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: has ? c.ink : c.ink3),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (!has) return body;
    return UgamTappable(
      onTap: onCall,
      semanticLabel: tr('seat_detail.call_a11y', namedArgs: {'phone': phone}),
      child: ExcludeSemantics(child: body),
    );
  }
}

/// A state chip that carries its glyph as well as its fill — spec §11's "colour
/// is never the only signal", applied inside the sheet as well as on the tile.
class _GlyphChip extends StatelessWidget {
  final String glyph;
  final String label;
  final Color fill;
  final Color ink;

  /// The chip's own ground. Neutral by default — the glyph and the word carry
  /// the meaning, and a chip per lens state would put five competing colours in
  /// one header. [UgamChipVariant.warm] is used for the one fact that IS a
  /// colour in the app's vocabulary everywhere else: a lady seated here.
  final UgamChipVariant variant;

  const _GlyphChip({
    required this.glyph,
    required this.label,
    required this.fill,
    required this.ink,
    this.variant = UgamChipVariant.neutral,
  });

  @override
  Widget build(BuildContext context) {
    return UgamReqChip(
      label: label.toUpperCase(),
      variant: variant,
      leadingWidget: Text(
        glyph,
        style: UgamText.micro.copyWith(color: ink, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The rider's note, quoted.
///
/// Same shape as the box `requests_screen` renders on an expanded row, so the
/// one fact that is free text reads the same in both places while both exist.
/// Unlike that one it is NOT clipped to two lines: a note that matters ("uses a
/// wheelchair", "boarding at Kim, not Adajan") is exactly the sentence a
/// truncation would eat the end of.
class _NoteBox extends StatelessWidget {
  final String note;

  const _NoteBox({required this.note});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Semantics(
      container: true,
      label: '${tr('chart.note_label')}: $note',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.tight,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: UgamScale.px(context, 16),
                color: c.ink3,
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  '"$note"',
                  style: UgamText.body.copyWith(
                    color: c.ink2,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One label/value pair. Stacked, not side by side: a Gujarati label runs ~30%
/// longer than its English source and would squeeze the value off the line.
class _Fact extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _Fact({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: UgamText.bodyStrong.copyWith(color: c.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// A secondary action. Same geometry as the occupant sheet's row so the two
/// read identically while both exist, but built on [UgamTappable] for the
/// press feedback the remediation pass added, and floored at the 44pt target.
class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Null renders the row inert AND visibly muted — an action that is not
  /// available must not look tappable.
  final VoidCallback? onTap;

  /// A figure the action carries (the amount to collect, the change to hand
  /// back). Tabular so a column of them lines up.
  final String? trailing;

  final bool danger;
  final bool accent;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.danger = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final enabled = onTap != null;
    final fg = !enabled
        ? c.ink3
        : danger
        ? c.danger
        : accent
        ? c.accent
        : c.ink;
    final bg = !enabled
        ? c.card
        : danger
        ? c.dangerFill
        : accent
        ? c.accentFill
        : c.cardElev;

    final body = Container(
      constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        children: [
          Icon(icon, size: UgamScale.px(context, 20), color: fg),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: fg),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: UgamSpacing.sm),
            Text(
              trailing!,
              style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: fg)),
              maxLines: 1,
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: enabled
          ? UgamTappable(onTap: onTap, child: body)
          : Semantics(enabled: false, child: body),
    );
  }
}
