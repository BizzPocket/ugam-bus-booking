import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/seat_chart_tile.dart';
import '../controllers/pickup_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour_status.dart';
import '../models/trip_type.dart';
import '../services/seat_move_flow.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_leg_cancel.dart';
import '../utils/phone_dialer.dart';
import 'edit_request_sheet.dart';

/// How much the occupant sheet may do.
///
/// [action] is the full agent sheet (call / move-or-swap / edit / priority /
/// handler / free / seat-here). [readOnly] is the viewer sheet used by the
/// read-only Charts browser: the SAME header (drag handle, person toggle for a
/// shared sofa, avatar + name + seat subtitle) and the call row, but NO
/// mutating actions. Both render the identical header, which is what makes the
/// shared-double bug fix visible — a leg-shared/shared sofa surfaces BOTH names
/// via the person toggle on either mode.
enum OccupantSheetMode { readOnly, action }

/// The one occupant action sheet, shared by every seating screen.
///
/// Opens when a BOOKED seat is tapped. For a SHARED sofa (two distinct people)
/// it shows a person toggle at the top so the agent can act on EITHER occupant
/// — call, move/swap (incl. to another bus, via [SeatMoveFlow]), or free that
/// person's half. When a passenger is mid-placement, an "seat [name] here"
/// action lets the tapped seat be shared with them.
class OccupantActionSheet extends StatefulWidget {
  /// Distinct occupants on the tapped seat (1, or 2 for a shared sofa).
  final List<Passenger> occupants;

  /// Whether mutating actions are offered. Defaults to [OccupantSheetMode.action]
  /// so every existing caller keeps the full agent sheet unchanged.
  final OccupantSheetMode mode;
  final String tourId;
  final String busId;
  final String seatId;
  final String busName;

  /// A passenger currently being placed (optional). When set together with
  /// [onSeatHere], the sheet offers "seat [placing] here" so the agent can
  /// share this seat with them.
  final Passenger? placing;
  final VoidCallback? onSeatHere;

  /// Swap [placing] INTO this seat by bumping the leg-conflicting occupant back
  /// to the pending pool. Offered (with [placing]) only when the seat is full on
  /// [placing]'s leg so a plain share isn't possible — the dead-end that used to
  /// leave the agent stuck.
  final VoidCallback? onSwapIn;

  /// Forwarded to [SeatMoveFlow.start] from the "move or swap" action. When set,
  /// picking a destination bus hands control back to the seat chart (tap the
  /// target seat by hand) instead of opening the auto swap-assistant. See
  /// [SeatMoveFlow.start].
  final void Function(
    Bus destination,
    Passenger mover,
    String sourceBusId,
    String fromSeatId,
  )? onRelocateToBus;

  /// Strike ONE leg from THIS seat for this occupant so the freed half can be
  /// resold (the caller owns the confirm + cancel + guided-rebook flow). The
  /// leg is [TripType.returnOnly] (not riding home) or [TripType.outboundOnly]
  /// (not riding out). Which of the two is offered is decided by the shared
  /// [cancellableSeatLegs] gate, never by this sheet.
  final void Function(Passenger occupant, TripType strike)? onCancelSeatLeg;

  /// Opens the seat's Hold/Premium flag sheet for THIS seat (not the occupant).
  /// Offered as an action row when set (action mode) — the tap-menu home for
  /// seat flags now that the standalone "edit seats" mode is gone.
  final VoidCallback? onSeatFlags;

  const OccupantActionSheet({
    super.key,
    required this.occupants,
    required this.tourId,
    required this.busId,
    required this.seatId,
    required this.busName,
    this.mode = OccupantSheetMode.action,
    this.placing,
    this.onSeatHere,
    this.onSwapIn,
    this.onRelocateToBus,
    this.onCancelSeatLeg,
    this.onSeatFlags,
  });

  static Future<void> show(
    BuildContext context, {
    required List<Passenger> occupants,
    required String tourId,
    required String busId,
    required String seatId,
    required String busName,
    OccupantSheetMode mode = OccupantSheetMode.action,
    Passenger? placing,
    VoidCallback? onSeatHere,
    VoidCallback? onSwapIn,
    void Function(
      Bus destination,
      Passenger mover,
      String sourceBusId,
      String fromSeatId,
    )? onRelocateToBus,
    void Function(Passenger occupant, TripType strike)? onCancelSeatLeg,
    VoidCallback? onSeatFlags,
  }) {
    if (occupants.isEmpty) return Future.value();
    // Root-navigator presentation (escaping the shell's nested tab Navigator so
    // the sheet paints above the bottom dock nav), the top-radius card
    // background and the drag handle all come from the shared UgamSheet shell.
    return UgamSheet.show<void>(
      context,
      showClose: false,
      builder: (_) => OccupantActionSheet(
        occupants: occupants,
        tourId: tourId,
        busId: busId,
        seatId: seatId,
        busName: busName,
        mode: mode,
        placing: placing,
        onSeatHere: onSeatHere,
        onSwapIn: onSwapIn,
        onRelocateToBus: onRelocateToBus,
        onCancelSeatLeg: onCancelSeatLeg,
        onSeatFlags: onSeatFlags,
      ),
    );
  }

  @override
  State<OccupantActionSheet> createState() => _OccupantActionSheetState();
}

class _OccupantActionSheetState extends State<OccupantActionSheet> {
  int _idx = 0;
  TourController get _ctrl => Get.find<TourController>();
  Passenger get _occ => widget.occupants[_idx];

  /// Global pickup-code lookup for the header tag; null (degrade to name-only)
  /// when the controller isn't registered.
  final PickupController? _pickup = Get.isRegistered<PickupController>()
      ? Get.find<PickupController>()
      : null;

  @override
  void initState() {
    super.initState();
    // Warm the global pickup list once so the header code tag can resolve.
    _pickup?.ensureLoaded();
  }

  /// Live occupant — re-read from the controller so an in-context priority /
  /// handler toggle reflects immediately without closing the sheet.
  Passenger get _liveOcc {
    final tour = _ctrl.getTour(widget.tourId);
    return tour?.passengers.firstWhereOrNull((p) => p.id == _occ.id) ?? _occ;
  }

  /// True when [_occ] is currently the handler of the bus this seat sits on.
  bool get _isHandlerOfThisBus {
    final tour = _ctrl.getTour(widget.tourId);
    final bus = tour?.buses.firstWhereOrNull((b) => b.id == widget.busId);
    return bus?.handlerPassengerId == _occ.id;
  }

  /// Which legs of the TAPPED seat can be struck for [occ]. Delegates to the
  /// shared gate so this sheet and the Board's passenger sheet offer exactly
  /// the same actions on the same seat.
  ({bool go, bool ret}) _strikeable(Passenger occ) {
    final tour = _ctrl.getTour(widget.tourId);
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

  /// Free this occupant's berth(s) on the tapped seat — keeps their request so
  /// they drop back into the pending pool, ready to be re-seated.
  Future<void> _free() async {
    final occ = _occ;
    final next = occ.assignedSeats
        .where((a) => !(a.busId == widget.busId && a.seatId == widget.seatId))
        .toList();
    try {
      await _ctrl.assignSeats(widget.tourId, occ.id, next);
    } catch (_) {}
  }

  /// Open the full edit-request sheet for this occupant so the agent can fix
  /// their name, quantities or trip type without first making them the active
  /// passenger. Closes this sheet, then opens the editor on the live tour.
  Future<void> _editRequest() async {
    final tour = _ctrl.getTour(widget.tourId);
    if (tour == null) return;
    Navigator.of(context).pop();
    await EditRequestSheet.show(
      context: context,
      tour: tour,
      passenger: _occ,
    );
  }

  /// Toggle this occupant's approved priority. Turning priority ON confirms
  /// first (reuses the shared priority alert); turning it OFF is direct. The
  /// sheet stays open and re-renders the new state via [setState].
  Future<void> _togglePriority() async {
    final occ = _liveOcc;
    final approved = occ.isPriorityApproved;
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
    await _ctrl.setPassengerPriority(widget.tourId, occ.id, !approved);
    if (mounted) setState(() {});
  }

  /// Make this occupant the handler of the bus the seat sits on, or step them
  /// down if they already handle it. The sheet stays open and re-renders.
  Future<void> _toggleHandler() async {
    final occ = _occ;
    if (_isHandlerOfThisBus) {
      await _ctrl.removeBusHandler(widget.tourId, widget.busId);
    } else {
      await _ctrl.setBusHandler(widget.tourId, widget.busId, occ.id);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final shared = widget.occupants.length > 1;
    final occ = _occ;
    final phone = occ.phone;
    final priorityOn = _liveOcc.isPriorityApproved;
    final handlerOfThisBus = _isHandlerOfThisBus;
    final pickup = _pickup;

    // Padding, the drag handle and the bottom-inset spacing are all provided by
    // the shared UgamSheet shell; this content is a plain min-height column.
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Person toggle — only for a genuinely shared sofa.
          if (shared) ...[
            UgamTabPills(
              currentIndex: _idx,
              onChanged: (i) => setState(() => _idx = i),
              items: [
                for (final p in widget.occupants)
                  UgamTabItem(label: p.displayName),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
          ],

          // Occupant header: avatar + name + phone.
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  SeatChartTile.initials(occ.displayName),
                  style: UgamText.bodyStrong.copyWith(color: c.onAccent),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Name stays flexible + ellipsised so a long name can never
                    // overflow; the pickup-CODE tag is a fixed trailing chip.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        // 2 lines before ellipsis — app-wide name rule, see
                        // UgamRequestRow.
                        Flexible(
                          child: Text(
                            occ.displayName,
                            style: UgamText.titleM.copyWith(color: c.ink),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Built only when the pickup controller exists: with no
                        // controller there is nothing observable to watch, and
                        // an Obx whose closure reads no observable throws (and
                        // paints a 100000px error box that blows out this Row).
                        if (pickup != null)
                          Obx(() {
                            final code = pickup.codeFor(occ.pickupLocationId);
                            if (code == null || code.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(
                                left: UgamSpacing.sm,
                              ),
                              child: UgamReqChip(
                                label: code,
                                variant: UgamChipVariant.neutral,
                              ),
                            );
                          }),
                      ],
                    ),
                    Text(
                      tr(
                        'occupant_sheet.seat_on',
                        namedArgs: {
                          'seat': widget.seatId,
                          'bus': widget.busName,
                        },
                      ),
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),

          // Call row — offered in BOTH modes (Charts is tap-to-call too). The
          // markup/padding is reused identically across read-only and action.
          if (phone.isNotEmpty)
            _ActionRow(
              icon: Icons.call_rounded,
              label: tr('occupant_sheet.call'),
              c: c,
              onTap: () => PhoneDialer.call(phone),
            ),

          // Mutating actions — ACTION mode only. Gated as one block so the
          // read-only Charts sheet can never expose an edit affordance.
          if (widget.mode == OccupantSheetMode.action) ...[
            _ActionRow(
              icon: Icons.swap_horiz_rounded,
              label: tr('occupant_sheet.move_or_swap'),
              c: c,
              onTap: () {
                Navigator.of(context).pop();
                SeatMoveFlow.start(
                  context,
                  tourId: widget.tourId,
                  sourceBusId: widget.busId,
                  mover: occ,
                  fromSeatId: widget.seatId,
                  onRelocateToBus: widget.onRelocateToBus,
                );
              },
            ),

            // Edit the underlying booking request (name / quantities / trip).
            _ActionRow(
              icon: Icons.edit_outlined,
              label: tr('occupant_sheet.edit_request'),
              c: c,
              onTap: _editRequest,
            ),

            // In-context ★ priority toggle — stays open so the agent can keep
            // working on the same occupant.
            _ActionRow(
              icon: priorityOn
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              label: priorityOn
                  ? tr('occupant.remove_priority')
                  : tr('occupant.make_priority'),
              c: c,
              accent: priorityOn,
              onTap: _togglePriority,
            ),

            // In-context handler toggle for the bus this seat sits on.
            _ActionRow(
              icon: handlerOfThisBus
                  ? Icons.verified_user_rounded
                  : Icons.shield_outlined,
              label: handlerOfThisBus
                  ? tr('occupant.is_handler')
                  : tr('occupant.make_handler'),
              c: c,
              accent: handlerOfThisBus,
              onTap: _toggleHandler,
            ),

            // Seat-level flags (Hold / Premium) for THIS seat — the tap-menu
            // home for what the removed "edit seats" mode used to do. The caller
            // owns the flag sheet; we just hand control to it.
            if (widget.onSeatFlags != null)
              _ActionRow(
                icon: Icons.tune_rounded,
                label: tr('occupant_sheet.seat_flags'),
                c: c,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onSeatFlags!();
                },
              ),

            _ActionRow(
              icon: Icons.person_remove_rounded,
              label: tr('occupant_sheet.free'),
              c: c,
              danger: true,
              onTap: () {
                Navigator.of(context).pop();
                _free();
              },
            ),

            // Strike ONE leg from THIS seat, so the freed half can be resold
            // while the leg they DID travel stays on the chart. Seat-scoped:
            // a party holding a double plus a single cancels one of them
            // without the other vanishing. The caller owns the confirm +
            // cancel + guided-rebook flow; [cancellableSeatLegs] owns which of
            // the two is offerable.
            if (widget.onCancelSeatLeg != null) ...[
              if (_strikeable(occ).ret) ...[
                const SizedBox(height: UgamSpacing.sm),
                _ActionRow(
                  icon: Icons.event_busy_rounded,
                  label: tr('tour_detail.cancel_return_seat'),
                  c: c,
                  danger: true,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onCancelSeatLeg!(occ, TripType.returnOnly);
                  },
                ),
              ],
              if (_strikeable(occ).go) ...[
                const SizedBox(height: UgamSpacing.sm),
                _ActionRow(
                  icon: Icons.logout_rounded,
                  label: tr('tour_detail.cancel_go_seat'),
                  c: c,
                  danger: true,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onCancelSeatLeg!(occ, TripType.outboundOnly);
                  },
                ),
              ],
            ],

            // Share with the passenger currently being placed.
            if (widget.placing != null && widget.onSeatHere != null) ...[
              const SizedBox(height: UgamSpacing.sm),
              _ActionRow(
                icon: Icons.person_add_alt_1_rounded,
                label: tr(
                  'occupant_sheet.seat_here',
                  namedArgs: {'name': widget.placing!.displayName},
                ),
                c: c,
                accent: true,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onSeatHere!();
                },
              ),
            ],

            // Swap the placing passenger IN — the seat is full on their leg so a
            // share isn't possible; this bumps the leg-conflicting occupant back
            // to pending and seats the placing passenger here instead.
            if (widget.placing != null && widget.onSwapIn != null) ...[
              const SizedBox(height: UgamSpacing.sm),
              _ActionRow(
                icon: Icons.swap_vert_rounded,
                label: tr(
                  'occupant_sheet.swap_in',
                  namedArgs: {'name': widget.placing!.displayName},
                ),
                c: c,
                accent: true,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onSwapIn!();
                },
              ),
            ],
          ],
        ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool danger;
  final bool accent;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.c,
    required this.onTap,
    this.danger = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? c.danger : (accent ? c.accent : c.ink);
    final bg = danger
        ? c.danger.withValues(alpha: 0.12)
        : (accent ? c.accentFill : c.cardElev);
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.md),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(UgamRadius.row),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: UgamText.bodyStrong.copyWith(color: fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
