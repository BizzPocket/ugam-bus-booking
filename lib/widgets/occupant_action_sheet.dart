import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/seat_chart_tile.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../services/seat_move_flow.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

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
  final String tourId;
  final String busId;
  final String seatId;
  final String busName;

  /// A passenger currently being placed (optional). When set together with
  /// [onSeatHere], the sheet offers "seat [placing] here" so the agent can
  /// share this seat with them.
  final Passenger? placing;
  final VoidCallback? onSeatHere;

  const OccupantActionSheet({
    super.key,
    required this.occupants,
    required this.tourId,
    required this.busId,
    required this.seatId,
    required this.busName,
    this.placing,
    this.onSeatHere,
  });

  static Future<void> show(
    BuildContext context, {
    required List<Passenger> occupants,
    required String tourId,
    required String busId,
    required String seatId,
    required String busName,
    Passenger? placing,
    VoidCallback? onSeatHere,
  }) {
    if (occupants.isEmpty) return Future.value();
    final c = UgamColors.of(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (_) => OccupantActionSheet(
        occupants: occupants,
        tourId: tourId,
        busId: busId,
        seatId: seatId,
        busName: busName,
        placing: placing,
        onSeatHere: onSeatHere,
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

    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: UgamSpacing.md),
              decoration: BoxDecoration(
                color: c.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

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
                    Text(
                      occ.displayName,
                      style: UgamText.titleM.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

          // Actions for the selected occupant.
          if (phone.isNotEmpty)
            _ActionRow(
              icon: Icons.call_rounded,
              label: tr('occupant_sheet.call'),
              c: c,
              onTap: () => PhoneDialer.call(phone),
            ),
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
              );
            },
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
        ],
      ),
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
