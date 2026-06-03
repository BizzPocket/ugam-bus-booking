import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../controllers/tour_controller.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/trip_type.dart';
import '../services/group_cascade.dart';
import '../services/swap_candidate_finder.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

/// SLICE 3a of the smart-seat UI: the per-bus seat-detail screen.
///
/// Renders ONE bus of a tour as a single [CombinedSeatGrid] (the shared
/// 5-column placement engine) with a clean, purpose-built tile look:
///
///   * FREE seat   — dashed ink3 hairline, transparent fill, a faint seat
///     glyph + the seat id.
///   * RESERVED    — dimmed card fill, a struck-through lock glyph and a
///     "Held" label; never shows an occupant (the engine never auto-fills
///     reserved seats).
///   * BOOKED      — occupant initials centred on a card/cardElev fill. A
///     deterministic colour RING when the occupant has a [Passenger.groupId]
///     (so a glance reads who travels together). A WARM ring + badge when the
///     occupant [Passenger.isPriorityApproved] OR the cell is [SeatCell.forward]
///     (the premium/priority forward zone).
///   * SHARED double — two unrelated passengers on one `doubleSofa` seatId:
///     the tile is split left/right with each occupant's initials.
///
/// Tapping a booked seat opens a bottom sheet (UgamRadius.sheet) with the
/// occupant's name, phone, a Call button, the requested-lines summary, a
/// group/priority indicator, and a "Free seat" action wired to the existing
/// [TourController.cancelOneSeat]. Move/Swap is a later slice — only READ +
/// Free is exposed here.
///
/// All colour comes from [UgamColors.of] — nothing hardcoded — and the
/// screen is dark-first per the locked design DNA. The chart is reactive:
/// an Obx on the controller's `tours` repaints whenever an assignment
/// changes (e.g. after Free seat).
class SeatDetailScreen extends StatefulWidget {
  final String tourId;
  final String busId;

  const SeatDetailScreen({
    super.key,
    required this.tourId,
    required this.busId,
  });

  @override
  State<SeatDetailScreen> createState() => _SeatDetailScreenState();
}

class _SeatDetailScreenState extends State<SeatDetailScreen> {
  TourController get _ctrl => Get.find<TourController>();

  String get tourId => widget.tourId;
  String get busId => widget.busId;

  /// When true, the chart enters "Edit seats" mode: tapping any seat opens a
  /// small sheet to toggle the seat's Forward / Reserved flags instead of the
  /// occupant detail / move flow. Toggled from the app-bar action.
  bool _editMode = false;

  /// Grid (the seat chart) vs List (a readable roster of FULL name + mobile per
  /// occupied seat). Toggled from the header. Edit-seats only makes sense on the
  /// chart, so entering edit mode is ignored while in the list view (the toggle
  /// hides the Edit action there).
  _ViewMode _viewMode = _ViewMode.grid;

  /// Build a seatId → occupants map for [bus]. A `doubleSofa` cell may hold
  /// up to two DISTINCT passengers when the agent split the sofa between
  /// unrelated singles; every other seat holds at most one.
  ///
  /// Occupants are de-duplicated per passenger per seat: a WHOLE double is one
  /// passenger holding TWO `SeatAssignment` entries on the SAME seatId (see
  /// [TourController.consolidateOntoDouble]). Without de-duping it would read
  /// as a SHARED split tile with the same person on both halves and open a
  /// bogus chooser. After de-duping a whole double yields `[p]` (length 1 →
  /// booked tile) and a genuine shared double yields two distinct passengers
  /// (length 2 → split tile + chooser).
  static Map<String, List<Passenger>> _occupantsBySeat(dynamic tour, Bus bus) {
    final out = <String, List<Passenger>>{};
    for (final p in (tour.passengers as List<Passenger>)) {
      for (final a in p.assignedSeats) {
        if (a.busId == bus.id) {
          final list = out[a.seatId] ??= <Passenger>[];
          if (!list.any((x) => x.id == p.id)) list.add(p);
        }
      }
    }
    return out;
  }

  /// Build a stable group-colour resolver for [tour]. When the tour carries a
  /// [PassengerGroup] list each group's own [PassengerGroup.colorIndex] feeds
  /// the infinite [groupColor] generator (so the colour is stable per group,
  /// not per session-hash). Any groupId NOT present in that list — or when the
  /// tour exposes no groups at all — falls back to [groupColorForId], which
  /// hashes the id into the same golden-angle sequence.
  static GroupColorResolver _resolverFor(dynamic tour) {
    final byId = <String, int>{};
    final groups = tour.groups;
    if (groups is List) {
      for (final g in groups) {
        try {
          byId[g.id as String] = g.colorIndex as int;
        } catch (_) {
          // Defensive: a malformed group entry just falls back to id-hashing.
        }
      }
    }
    return GroupColorResolver(byId);
  }

  /// Count every booked berth on [bus] from the RAW assignment entries — a
  /// whole double contributes 2 berths even though it resolves to one
  /// occupant tile, so this must NOT be derived from the de-duped occupant
  /// map (that would undercount whole doubles as 1).
  static int _assignedBerths(dynamic tour, Bus bus) {
    var n = 0;
    for (final p in (tour.passengers as List<Passenger>)) {
      for (final a in p.assignedSeats) {
        if (a.busId == bus.id) n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final tour = _ctrl.getTour(tourId);
          final bus = tour?.buses.firstWhereOrNull((b) => b.id == busId);
          if (tour == null || bus == null) {
            return Column(
              children: [
                _Header(
                  title: 'Seat detail',
                  subtitle: null,
                  c: c,
                  editMode: false,
                  onToggleEdit: null,
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      'Bus not found.',
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  ),
                ),
              ],
            );
          }

          final layout = bus.layout;
          final occupants = _occupantsBySeat(tour, bus);
          final groupColors = _resolverFor(tour);
          final total = layout?.totalSeats ?? 0;
          // Count raw berths (a whole double = 2 berths, one tile) so the
          // subtitle never undercounts consolidated doubles.
          final assigned = _assignedBerths(tour, bus);

          final isList = _viewMode == _ViewMode.list;

          return Column(
            children: [
              _Header(
                title: bus.name,
                subtitle: _editMode
                    ? 'Editing seats · tap a seat'
                    : '$assigned/$total assigned',
                c: c,
                // Edit-seats only applies to the chart; hide it in list view.
                editMode: _editMode,
                onToggleEdit: isList
                    ? null
                    : () => setState(() => _editMode = !_editMode),
                viewMode: _viewMode,
                onSelectView: (m) => setState(() {
                  _viewMode = m;
                  // Leaving the chart cancels edit mode so it can't linger.
                  if (m == _ViewMode.list) _editMode = false;
                }),
              ),
              Expanded(
                child: layout == null || layout.totalCells == 0
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(UgamSpacing.huge),
                          child: Text(
                            'This bus has no seat layout yet.',
                            textAlign: TextAlign.center,
                            style: UgamText.body.copyWith(color: c.ink2),
                          ),
                        ),
                      )
                    : isList
                    ? _RosterList(
                        layout: layout,
                        occupants: occupants,
                        groupColors: groupColors,
                        c: c,
                        onTapSeat: (cell, seatOccupants) => _showOccupantSheet(
                          context,
                          cell: cell,
                          occupants: seatOccupants,
                          bus: bus,
                          tourTitle: tour.title,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.gutter,
                        ),
                        child: UgamCard.plain(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.md,
                            vertical: UgamSpacing.lg,
                          ),
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: CombinedSeatGrid(
                              layout: layout,
                              cellWidth: _tileW,
                              cellHeight: _tileH,
                              colGap: 6,
                              rowGap: 6,
                              tileBuilder: (ctx, cell) {
                                final seatOccupants = cell.seatId != null
                                    ? (occupants[cell.seatId] ??
                                          const <Passenger>[])
                                    : const <Passenger>[];
                                // In edit mode, every real seat routes to the
                                // forward/reserved flag sheet — occupant detail
                                // and free-info sheets are suppressed.
                                final VoidCallback? editTap =
                                    (_editMode && cell.seatId != null)
                                    ? () => _showSeatFlagsSheet(ctx, cell, bus)
                                    : null;
                                return RepaintBoundary(
                                  child: _SeatTile(
                                    cell: cell,
                                    occupants: seatOccupants,
                                    groupColors: groupColors,
                                    editMode: _editMode,
                                    onTapBooked:
                                        editTap ??
                                        () => _showOccupantSheet(
                                          ctx,
                                          cell: cell,
                                          occupants: seatOccupants,
                                          bus: bus,
                                          tourTitle: tour.title,
                                        ),
                                    onTapFree:
                                        editTap ??
                                        () => _showFreeSheet(ctx, cell, bus),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
              ),
              if (!isList) ...[
                const SizedBox(height: UgamSpacing.sm),
                _Legend(c: c),
                const SizedBox(height: UgamSpacing.md),
              ],
            ],
          );
        }),
      ),
    );
  }

  // ── Sheets ────────────────────────────────────────────────────────────

  /// Booked-seat bottom sheet: occupant name + phone + Call, requested
  /// lines, a group/priority indicator, and a "Free seat" action. A shared
  /// double surfaces a per-occupant chooser first, then opens this sheet for
  /// the chosen occupant.
  void _showOccupantSheet(
    BuildContext context, {
    required SeatCell cell,
    required List<Passenger> occupants,
    required Bus bus,
    required String tourTitle,
  }) {
    if (occupants.isEmpty) return;

    void open(Passenger occupant) {
      final c = UgamColors.of(context);
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: c.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(UgamRadius.sheet),
          ),
        ),
        builder: (sheetCtx) => _OccupantSheet(
          occupant: occupant,
          cell: cell,
          bus: bus,
          tourTitle: tourTitle,
          isShared: occupants.length > 1,
          onFreeSeat: () async {
            Navigator.of(sheetCtx).pop();
            await _ctrl.cancelOneSeat(
              tourId: tourId,
              passengerId: occupant.id,
              busId: bus.id,
              seatId: cell.seatId!,
            );
          },
          onMove: () {
            Navigator.of(sheetCtx).pop();
            _startMoveOrSwap(context, mover: occupant, fromCell: cell);
          },
          onSwap: () {
            Navigator.of(sheetCtx).pop();
            _startMoveOrSwap(context, mover: occupant, fromCell: cell);
          },
        ),
      );
    }

    // Leg reuse (GO outbound-only + RET return-only on disjoint legs) → list
    // BOTH holders with their own name / phone / Call and a leg badge; the
    // agent taps one to open its full detail sheet.
    final legShare = _legShareOf(occupants);
    if (legShare != null) {
      final c = UgamColors.of(context);
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: c.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(UgamRadius.sheet),
          ),
        ),
        builder: (sheetCtx) => _LegHoldersSheet(
          go: legShare.go,
          ret: legShare.ret,
          seatId: cell.seatId!,
          onPick: (p) {
            Navigator.of(sheetCtx).pop();
            open(p);
          },
        ),
      );
      return;
    }

    // Shared double → let the agent pick which of the two berth-holders to act
    // on before opening the detail sheet.
    if (occupants.length > 1) {
      final c = UgamColors.of(context);
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: c.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(UgamRadius.sheet),
          ),
        ),
        builder: (sheetCtx) => _SharedChooserSheet(
          occupants: occupants,
          seatId: cell.seatId!,
          onPick: (p) {
            Navigator.of(sheetCtx).pop();
            open(p);
          },
        ),
      );
      return;
    }

    open(occupants.first);
  }

  /// Classify a seat's [occupants] as a disjoint GO/RETURN leg reuse — exactly
  /// one outbound-only and one return-only passenger. Mirrors the tile's
  /// `_SeatTile._legShare`; kept here so the sheet routing agrees with the tile.
  static ({Passenger go, Passenger ret})? _legShareOf(
    List<Passenger> occupants,
  ) {
    if (occupants.length != 2) return null;
    final a = occupants[0];
    final b = occupants[1];
    if (a.tripType == TripType.outboundOnly &&
        b.tripType == TripType.returnOnly) {
      return (go: a, ret: b);
    }
    if (a.tripType == TripType.returnOnly &&
        b.tripType == TripType.outboundOnly) {
      return (go: b, ret: a);
    }
    return null;
  }

  /// Free-seat tap → a brief info sheet. No assignment happens here yet.
  void _showFreeSheet(BuildContext context, SeatCell cell, Bus bus) {
    final c = UgamColors.of(context);
    final held = cell.reserved;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.sm + 4,
          UgamSpacing.gutter,
          UgamSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetGrabber(),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: held ? c.cardElev : c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.input),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    held
                        ? Icons.lock_outline_rounded
                        : Icons.event_seat_rounded,
                    size: 18,
                    color: held ? c.ink3 : c.accent,
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        held
                            ? 'Seat ${cell.seatId} is held'
                            : 'Seat ${cell.seatId} is free',
                        style: UgamText.titleM.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        held
                            ? 'Reserved by you — the auto-fill skips it.'
                            : '${cell.typeLabel} · ${bus.name}',
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
            Text(
              held
                  ? 'Free this seat from the seat-assignment workbench to open '
                        'it up for booking.'
                  : 'Open the seat-assignment workbench to place a passenger '
                        'here.',
              style: UgamText.body.copyWith(color: c.ink2),
            ),
          ],
        ),
      ),
    );
  }

  // ── Move / Swap flow ────────────────────────────────────────────────────

  /// Entry point for the Move/Swap actions on a booked occupant. Picks a
  /// destination bus (skips a single-bus tour straight through), then runs the
  /// swap assistant for that bus and surfaces its options.
  void _startMoveOrSwap(
    BuildContext context, {
    required Passenger mover,
    required SeatCell fromCell,
  }) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final buses = tour.buses;
    if (buses.isEmpty) return;

    void run(Bus destination) => _openSwapAssist(
      context,
      mover: mover,
      fromCell: fromCell,
      destination: destination,
    );

    // One bus → nothing to pick; go straight to that bus's swap assistant.
    if (buses.length == 1) {
      run(buses.first);
      return;
    }

    final c = UgamColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (sheetCtx) => _DestinationPickerSheet(
        mover: mover,
        buses: buses,
        currentBusId: busId,
        onPick: (b) {
          Navigator.of(sheetCtx).pop();
          run(b);
        },
      ),
    );
  }

  /// Compute and present the [SwapAssist] for [mover] onto [destination]: free
  /// seats to take outright, ranked swap candidates, and blocked occupants.
  void _openSwapAssist(
    BuildContext context, {
    required Passenger mover,
    required SeatCell fromCell,
    required Bus destination,
  }) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final passengers = tour.passengers;

    final assist = SwapCandidateFinder.find(
      mover: mover,
      destinationBus: destination,
      passengers: passengers,
    );

    final c = UgamColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (sheetCtx) => _SwapAssistSheet(
        mover: mover,
        destination: destination,
        assist: assist,
        onTakeFree: (freeSeatId) {
          Navigator.of(sheetCtx).pop();
          _moveMoverTo(
            context,
            mover: mover,
            fromCell: fromCell,
            destination: destination,
            toSeatId: freeSeatId,
          );
        },
        onSwap: (candidate) {
          Navigator.of(sheetCtx).pop();
          _swapWith(
            context,
            mover: mover,
            fromCell: fromCell,
            destination: destination,
            candidate: candidate,
          );
        },
      ),
    );
  }

  /// Place [mover] onto a FREE seat of [destination]. If the mover belongs to a
  /// group, the whole group cascades (after a confirm) via [GroupCascade];
  /// otherwise only the mover moves. A whole-double mover keeps both berths
  /// because [TourController.moveSeat] replicates the source berth count.
  Future<void> _moveMoverTo(
    BuildContext context, {
    required Passenger mover,
    required SeatCell fromCell,
    required Bus destination,
    required String toSeatId,
  }) async {
    final fromSeatId = fromCell.seatId;
    if (fromSeatId == null) return;

    final hasGroup = mover.groupId != null && mover.groupId!.isNotEmpty;
    if (hasGroup) {
      await _moveGroup(
        context,
        mover: mover,
        destination: destination,
        anchorToSeatId: toSeatId,
      );
      return;
    }

    await _ctrl.moveSeat(
      tourId: tourId,
      passengerId: mover.id,
      busId: destination.id,
      fromSeatId: fromSeatId,
      toSeatId: toSeatId,
    );
  }

  /// Swap [mover] with a chosen movable [candidate] on [destination]. Group
  /// movers cascade the whole group instead of a one-for-one swap (a group
  /// can't be split across a swap), so we route them through the group planner.
  Future<void> _swapWith(
    BuildContext context, {
    required Passenger mover,
    required SeatCell fromCell,
    required Bus destination,
    required SwapCandidate candidate,
  }) async {
    final fromSeatId = fromCell.seatId;
    if (fromSeatId == null) return;

    final hasGroup = mover.groupId != null && mover.groupId!.isNotEmpty;
    if (hasGroup) {
      await _moveGroup(
        context,
        mover: mover,
        destination: destination,
        anchorToSeatId: candidate.seatId,
      );
      return;
    }

    await _ctrl.swapSeats(
      tourId: tourId,
      busId: destination.id,
      passengerAId: mover.id,
      seatAId: fromSeatId,
      passengerBId: candidate.passengerId,
      seatBId: candidate.seatId,
    );
  }

  /// Cascade a grouped mover and all siblings onto [destination] via
  /// [GroupCascade.planMove]. Confirms "Move whole group (N people)?" when the
  /// group is more than one; aborts with the planner's reason when it doesn't
  /// fit. The anchor mover lands on [anchorToSeatId]; siblings keep whichever
  /// seats they already hold (a full re-seat is the workbench's job).
  Future<void> _moveGroup(
    BuildContext context, {
    required Passenger mover,
    required Bus destination,
    required String anchorToSeatId,
  }) async {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final passengers = tour.passengers;

    final plan = GroupCascade.planMove(
      mover: mover,
      destinationBus: destination,
      passengers: passengers,
    );

    final memberCount = plan.memberPassengerIds.length;

    // Single-member "group" → just move the mover, no confirm needed.
    if (memberCount <= 1) {
      if (!plan.destinationFits) {
        _showBlockedDialog(context, plan.blockedReason);
        return;
      }
      await _moveAnchorAndSiblings(
        mover: mover,
        destination: destination,
        anchorToSeatId: anchorToSeatId,
        memberIds: plan.memberPassengerIds,
        passengers: passengers,
      );
      return;
    }

    final confirmed = await _confirmGroupMove(context, count: memberCount);
    if (confirmed != true) return;
    if (!context.mounted) return;

    if (!plan.destinationFits) {
      _showBlockedDialog(context, plan.blockedReason);
      return;
    }

    await _moveAnchorAndSiblings(
      mover: mover,
      destination: destination,
      anchorToSeatId: anchorToSeatId,
      memberIds: plan.memberPassengerIds,
      passengers: passengers,
    );
  }

  /// Move every member of the group onto [destination]. The anchor mover lands
  /// on [anchorToSeatId]; each sibling moves from its current seat (wherever it
  /// is) onto the destination bus. Members already on the destination bus are
  /// left in place. [TourController.moveSeat] preserves each member's berth
  /// count, so whole doubles stay whole.
  Future<void> _moveAnchorAndSiblings({
    required Passenger mover,
    required Bus destination,
    required String anchorToSeatId,
    required List<String> memberIds,
    required List<Passenger> passengers,
  }) async {
    // Anchor first onto the chosen target seat.
    final anchorFrom = mover.assignedSeats.firstWhereOrNull((a) => true);
    if (anchorFrom != null) {
      await _ctrl.moveSeat(
        tourId: tourId,
        passengerId: mover.id,
        busId: destination.id,
        fromSeatId: anchorFrom.seatId,
        toSeatId: anchorToSeatId,
      );
    }

    // Siblings: move each onto the destination bus from wherever they sit. We
    // can't compute exact engine targets here, so each sibling lands on its
    // own current seatId on the destination bus — the workbench re-seats them
    // precisely. The key invariant the cascade guarantees (via the planner) is
    // that the bus HAS room; placement detail is the auto-fill's job afterward.
    for (final id in memberIds) {
      if (id == mover.id) continue;
      final sibling = passengers.firstWhereOrNull((p) => p.id == id);
      if (sibling == null) continue;
      final from = sibling.assignedSeats.firstWhereOrNull((a) => true);
      if (from == null) continue;
      // Already on the destination bus → leave in place.
      if (from.busId == destination.id) continue;
      await _ctrl.moveSeat(
        tourId: tourId,
        passengerId: sibling.id,
        busId: destination.id,
        fromSeatId: from.seatId,
        toSeatId: from.seatId,
      );
    }
  }

  Future<bool?> _confirmGroupMove(BuildContext context, {required int count}) {
    final c = UgamColors.of(context);
    return showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        title: Text(
          'Move whole group?',
          style: UgamText.titleM.copyWith(color: c.ink),
        ),
        content: Text(
          'This booking travels with $count people. They sit together on one '
          'bus, so all $count will move.',
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            style: TextButton.styleFrom(foregroundColor: c.ink2),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            style: TextButton.styleFrom(foregroundColor: c.accent),
            child: Text('Move $count people'),
          ),
        ],
      ),
    );
  }

  void _showBlockedDialog(BuildContext context, String? reason) {
    final c = UgamColors.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        title: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 20, color: c.warm),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              "Can't move here",
              style: UgamText.titleM.copyWith(color: c.ink),
            ),
          ],
        ),
        content: Text(
          reason ?? 'The destination bus does not have room for this booking.',
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            style: TextButton.styleFrom(foregroundColor: c.accent),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── Edit seats: Forward / Reserved flags ────────────────────────────────

  /// Edit-mode tap on a seat → a small sheet with two switches:
  /// "Forward / premium seat" ([TourController.setSeatForward]) and
  /// "Hold / reserved" ([TourController.setSeatReserved]). The chart repaints
  /// reactively once the controller mutates the bus layout.
  void _showSeatFlagsSheet(BuildContext context, SeatCell cell, Bus bus) {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final c = UgamColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (sheetCtx) => _SeatFlagsSheet(
        seatId: seatId,
        typeLabel: cell.typeLabel,
        busName: bus.name,
        forward: cell.forward,
        reserved: cell.reserved,
        onForward: (v) => _ctrl.setSeatForward(tourId, bus.id, seatId, v),
        onReserved: (v) => _ctrl.setSeatReserved(tourId, bus.id, seatId, v),
      ),
    );
  }
}

// Tile sizing — a touch larger than the read-only chart so initials read
// cleanly. The grid FittedBox scales the whole chart down to fit width.
const double _tileW = 60;
const double _tileH = 60;

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final UgamColorSet c;

  /// Whether the chart is in "Edit seats" mode (forward/reserved toggling).
  final bool editMode;

  /// Toggles edit mode. Null hides the action (e.g. the bus-not-found state or
  /// the list view, where seat-flag editing doesn't apply).
  final VoidCallback? onToggleEdit;

  /// Current Grid | List view, and its setter. Null hides the segmented toggle
  /// (the bus-not-found state has nothing to view either way).
  final _ViewMode? viewMode;
  final ValueChanged<_ViewMode>? onSelectView;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.c,
    required this.editMode,
    required this.onToggleEdit,
    this.viewMode,
    this.onSelectView,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title.isEmpty ? 'Seat detail' : title,
                      style: UgamText.titleL.copyWith(
                        color: c.ink,
                        fontSize: 20,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink2),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (onToggleEdit != null) ...[
                const SizedBox(width: UgamSpacing.sm),
                Semantics(
                  button: true,
                  toggled: editMode,
                  label: editMode ? 'Done editing seats' : 'Edit seats',
                  child: GestureDetector(
                    onTap: onToggleEdit,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.md,
                      ),
                      decoration: BoxDecoration(
                        color: editMode ? c.accent : c.cardElev,
                        borderRadius: BorderRadius.circular(UgamRadius.chip),
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            editMode ? Icons.check_rounded : Icons.tune_rounded,
                            size: 16,
                            color: editMode ? c.onAccent : c.ink,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            editMode ? 'Done' : 'Edit seats',
                            style: UgamText.caption.copyWith(
                              color: editMode ? c.onAccent : c.ink,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          // Grid | List segmented toggle. The List view is the readable roster
          // (FULL name + tappable mobile) the agent asked for; Grid is the seat
          // chart. Hidden when there's nothing to view (bus-not-found).
          if (viewMode != null && onSelectView != null) ...[
            const SizedBox(height: UgamSpacing.md),
            _ViewToggle(mode: viewMode!, onSelect: onSelectView!, c: c),
          ],
        ],
      ),
    );
  }
}

// ─── Grid | List view toggle ────────────────────────────────────────────

/// The two ways to read one bus: the seat [_ViewMode.grid] chart, or a
/// [_ViewMode.list] roster (one row per occupied seat with the FULL passenger
/// name + tappable mobile).
enum _ViewMode { grid, list }

/// A two-segment pill toggle. The selected segment fills with `accent`; the
/// other stays on `cardElev`. Lives below the title row so it never competes
/// with the title / Edit-seats action for horizontal space.
class _ViewToggle extends StatelessWidget {
  final _ViewMode mode;
  final ValueChanged<_ViewMode> onSelect;
  final UgamColorSet c;

  const _ViewToggle({
    required this.mode,
    required this.onSelect,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          _segment(
            label: 'Grid',
            icon: Icons.grid_view_rounded,
            selected: mode == _ViewMode.grid,
            onTap: () => onSelect(_ViewMode.grid),
          ),
          _segment(
            label: 'List',
            icon: Icons.format_list_bulleted_rounded,
            selected: mode == _ViewMode.list,
            onTap: () => onSelect(_ViewMode.list),
          ),
        ],
      ),
    );
  }

  Widget _segment({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label view',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: selected ? c.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: selected ? c.onAccent : c.ink2),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: UgamText.caption.copyWith(
                    color: selected ? c.onAccent : c.ink2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Group colour resolver ─────────────────────────────────────────────

/// Resolves a [Passenger.groupId] to its ring colour via the infinite
/// golden-angle generator in `design/group_color.dart`.
///
/// Groups have no upper bound, so the old fixed 6-hue [_GroupPalette] (keyed by
/// `groupId.hashCode % 6`) eventually recycled and two unrelated groups read as
/// one. This resolver instead feeds the unbounded [groupColor] / [groupColorForId]
/// sequence:
///
///   * When the tour carries a [PassengerGroup] list, each group's own stable
///     [PassengerGroup.colorIndex] drives [groupColor(index)] — so the colour is
///     deterministic per group across sessions, not a session-local hash.
///   * Any id NOT in that map (or a tour with no groups) falls back to
///     [groupColorForId], which hashes the id into the same sequence.
class GroupColorResolver {
  /// groupId → stable palette index (from [PassengerGroup.colorIndex]).
  final Map<String, int> _indexById;

  const GroupColorResolver(this._indexById);

  Color colorFor(String groupId) {
    final idx = _indexById[groupId];
    if (idx != null) return groupColor(idx);
    return groupColorForId(groupId);
  }
}

// ─── Seat tile ─────────────────────────────────────────────────────────

/// A single clean seat tile. Draws its own look (no DragTarget / Draggable —
/// those gestures belong to the assignment workbench) and shares only the
/// grid's placement. States: free / held (reserved) / booked / shared-double.
class _SeatTile extends StatelessWidget {
  final SeatCell cell;
  final List<Passenger> occupants;

  /// Resolves a [Passenger.groupId] to its ring colour (infinite golden-angle
  /// generator, stable per group).
  final GroupColorResolver groupColors;

  final VoidCallback onTapBooked;
  final VoidCallback onTapFree;

  /// When true the tile draws a small edit affordance and an empty seat in the
  /// forward zone still gets a warm ring so the agent sees the flag take.
  final bool editMode;

  const _SeatTile({
    required this.cell,
    required this.occupants,
    required this.groupColors,
    required this.onTapBooked,
    required this.onTapFree,
    this.editMode = false,
  });

  bool get _isBooked => occupants.isNotEmpty;

  /// A genuine SHARED-double split: two DISTINCT passengers on one seatId that
  /// is NOT a clean disjoint GO/RETURN leg reuse. Leg reuse is rendered by the
  /// leg-aware path instead.
  bool get _isShared => occupants.length > 1 && _legShare == null;

  /// When this seat is reused across disjoint legs — exactly one outbound-only
  /// GO holder and one return-only RETURN holder — returns that pair. Otherwise
  /// null. A round-trip occupant holds BOTH legs exclusively, so its presence
  /// rules out leg reuse.
  ({Passenger go, Passenger ret})? get _legShare {
    if (occupants.length != 2) return null;
    final a = occupants[0];
    final b = occupants[1];
    // Both must be one-way and on opposite legs.
    if (a.tripType == TripType.outboundOnly &&
        b.tripType == TripType.returnOnly) {
      return (go: a, ret: b);
    }
    if (a.tripType == TripType.returnOnly &&
        b.tripType == TripType.outboundOnly) {
      return (go: b, ret: a);
    }
    return null;
  }

  static String initials(String displayName) {
    final n = displayName.trim();
    if (n.isEmpty) return '?';
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  /// Short leg badge for a one-way occupant: "GO" (outbound-only) or "RET"
  /// (return-only). Null for round-trip (no badge).
  static String? legBadge(TripType t) {
    switch (t) {
      case TripType.outboundOnly:
        return 'GO';
      case TripType.returnOnly:
        return 'RET';
      case TripType.roundTrip:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final legShare = _legShare;
    final Widget tile;
    final VoidCallback onTap;
    if (legShare != null) {
      tile = _legShareTile(c, legShare.go, legShare.ret);
      onTap = onTapBooked;
    } else if (_isShared) {
      tile = _sharedTile(c);
      onTap = onTapBooked;
    } else if (_isBooked) {
      tile = _bookedTile(c, occupants.first);
      onTap = onTapBooked;
    } else if (cell.reserved) {
      tile = _heldTile(c);
      onTap = onTapFree;
    } else {
      tile = _freeTile(c);
      onTap = onTapFree;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: editMode ? _withEditAffordance(c, tile) : tile,
    );
  }

  /// In edit mode, overlay a tiny tune glyph and (for an empty forward seat) a
  /// warm ring so toggling a flag is visibly reflected on every seat state.
  Widget _withEditAffordance(UgamColorSet c, Widget tile) {
    final showForwardRing = !_isBooked && cell.forward;
    return Stack(
      children: [
        if (showForwardRing)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(UgamRadius.seat),
                border: Border.all(color: c.warm, width: 2),
              ),
            ),
          ),
        tile,
        Positioned(
          bottom: 3,
          right: 3,
          child: Icon(Icons.tune_rounded, size: 11, color: c.ink3),
        ),
      ],
    );
  }

  // FREE — dashed ink3 hairline, transparent fill, faint glyph + seat id.
  Widget _freeTile(UgamColorSet c) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: c.ink3.withValues(alpha: 0.55),
        radius: UgamRadius.seat,
      ),
      child: SizedBox(
        width: _tileW,
        height: _tileH,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_seat_outlined, size: 16, color: c.ink3),
            const SizedBox(height: 3),
            Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 9.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // RESERVED — dimmed fill, struck lock glyph, "Held" label.
  Widget _heldTile(UgamColorSet c) {
    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        color: c.cardElev.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: c.ink3),
          const SizedBox(height: 3),
          Text(
            'Held',
            style: UgamText.micro.copyWith(
              color: c.ink3,
              decoration: TextDecoration.lineThrough,
              decorationColor: c.ink3,
            ),
          ),
        ],
      ),
    );
  }

  // BOOKED — initials on card fill; group ring + warm priority ring/badge.
  // A one-way occupant (outbound-only / return-only) also gets a kOneWayTint
  // corner triangle + a "GO" / "RET" badge — a treatment distinct from the
  // group ring and the warm priority ring.
  Widget _bookedTile(UgamColorSet c, Passenger p) {
    final priority = p.isPriorityApproved || cell.forward;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    final oneWay = p.tripType.isOneWay;
    final badge = legBadge(p.tripType);

    // The outer ring colour signals belonging. Priority (warm) is attention,
    // so it always wins the ring; a group then shows as a small dot badge.
    final Color ringColor;
    final double ringWidth;
    if (priority) {
      ringColor = c.warm;
      ringWidth = 2;
    } else if (groupColor != null) {
      ringColor = groupColor;
      ringWidth = 2;
    } else {
      ringColor = c.border;
      ringWidth = 1;
    }

    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: ringColor, width: ringWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // One-way cool-cyan corner triangle (bottom-left) — never collides
          // with the warm priority star (top-right) or the group ring colour.
          if (oneWay)
            Positioned(
              left: 0,
              bottom: 0,
              child: CustomPaint(
                size: const Size(16, 16),
                painter: _OneWayCornerPainter(tint: kOneWayTint),
              ),
            ),
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                initials(p.displayName),
                style: UgamText.bodyStrong.copyWith(
                  color: c.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          // Seat id, top-left.
          Positioned(
            top: 4,
            left: 5,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
              ),
            ),
          ),
          // Priority warm badge, top-right.
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            ),
          // One-way GO/RET pill, bottom-centre — reads the leg at a glance.
          if (oneWay && badge != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 3,
              child: Center(
                child: _LegPill(label: badge, tint: kOneWayTint),
              ),
            ),
          // Group dot badge (only when not already the ring colour, i.e. a
          // priority booking that ALSO belongs to a group).
          if (priority && groupColor != null)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  color: groupColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // LEG-SHARED — one GO holder + one RETURN holder reuse the same physical seat
  // across disjoint legs. Stacked top (GO) / bottom (RET), each with its initial
  // + leg badge, a kOneWayTint divider, and a one-way corner accent.
  Widget _legShareTile(UgamColorSet c, Passenger go, Passenger ret) {
    final priority =
        go.isPriorityApproved || ret.isPriorityApproved || cell.forward;
    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(
          color: priority ? c.warm : kOneWayTint.withValues(alpha: 0.7),
          width: priority ? 2 : 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _legHalf(c, go, 'GO')),
              Container(height: 1, color: kOneWayTint.withValues(alpha: 0.7)),
              Expanded(child: _legHalf(c, ret, 'RET')),
            ],
          ),
          // Seat id, top-left (over the GO half).
          Positioned(
            top: 3,
            left: 4,
            child: Text(
              cell.seatId ?? '',
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink3, fontSize: 7.5),
              ),
            ),
          ),
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 11, color: c.warm),
            ),
        ],
      ),
    );
  }

  Widget _legHalf(UgamColorSet c, Passenger p, String badge) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    return Container(
      color: c.cardElev,
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _LegPill(label: badge, tint: kOneWayTint),
          const SizedBox(width: 4),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                initials(p.displayName),
                style: UgamText.bodyStrong.copyWith(
                  color: c.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          if (groupColor != null) ...[
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: groupColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // SHARED double — split left/right, both initials.
  Widget _sharedTile(UgamColorSet c) {
    final a = occupants[0];
    final b = occupants[1];
    final priority =
        a.isPriorityApproved || b.isPriorityApproved || cell.forward;
    return Container(
      width: _tileW,
      height: _tileH,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(
          color: priority ? c.warm : c.border,
          width: priority ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(child: _half(c, a)),
              Container(width: 1, color: c.border),
              Expanded(child: _half(c, b)),
            ],
          ),
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                cell.seatId ?? '',
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3, fontSize: 8),
                ),
              ),
            ),
          ),
          if (priority)
            Positioned(
              top: 3,
              right: 3,
              child: Icon(Icons.star_rounded, size: 12, color: c.warm),
            ),
        ],
      ),
    );
  }

  Widget _half(UgamColorSet c, Passenger p) {
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;
    final badge = legBadge(p.tripType);
    return Container(
      color: c.cardElev,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              initials(p.displayName),
              style: UgamText.bodyStrong.copyWith(
                color: c.ink,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (badge != null) ...[
            const SizedBox(height: 2),
            _LegPill(label: badge, tint: kOneWayTint),
          ] else if (groupColor != null) ...[
            const SizedBox(height: 3),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: groupColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A tiny pill stamp for the one-way leg — "GO" / "RET" in [kOneWayTint]. Used
/// on the booked tile, the leg-shared split, and the shared-double halves so a
/// one-way leg reads the same everywhere.
class _LegPill extends StatelessWidget {
  final String label;
  final Color tint;

  const _LegPill({required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        border: Border.all(color: tint.withValues(alpha: 0.85), width: 0.8),
      ),
      child: Text(
        label,
        style: UgamText.micro.copyWith(
          color: tint,
          fontSize: 7.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Paints a small filled corner triangle in the one-way [tint] — the
/// bottom-left accent on a one-way booked tile.
class _OneWayCornerPainter extends CustomPainter {
  final Color tint;

  _OneWayCornerPainter({required this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = tint.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _OneWayCornerPainter old) => old.tint != tint;
}

/// Paints a dashed rounded-rectangle border for the FREE tile. Kept local so
/// the free look stays distinct from the solid-bordered booked/held tiles.
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 4.0;
    const gap = 3.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

// ─── Legend ────────────────────────────────────────────────────────────

class _Legend extends StatelessWidget {
  final UgamColorSet c;
  const _Legend({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Wrap(
        spacing: UgamSpacing.md,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          _LegendItem(swatch: _LegendSwatch.dashed, label: 'Free', c: c),
          _LegendItem(swatch: _LegendSwatch.filled, label: 'Booked', c: c),
          _LegendItem(
            swatch: _LegendSwatch.warmRing,
            label: 'Priority / forward',
            c: c,
          ),
          _LegendItem(
            swatch: _LegendSwatch.oneWay,
            label: 'One-way (GO/RET)',
            c: c,
          ),
          _LegendItem(swatch: _LegendSwatch.held, label: 'Held', c: c),
        ],
      ),
    );
  }
}

enum _LegendSwatch { dashed, filled, warmRing, oneWay, held }

class _LegendItem extends StatelessWidget {
  final _LegendSwatch swatch;
  final String label;
  final UgamColorSet c;

  const _LegendItem({
    required this.swatch,
    required this.label,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    Widget dot;
    switch (swatch) {
      case _LegendSwatch.dashed:
        dot = CustomPaint(
          painter: _DashedBorderPainter(
            color: c.ink3.withValues(alpha: 0.7),
            radius: 3,
          ),
          child: const SizedBox(width: 12, height: 12),
        );
      case _LegendSwatch.filled:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
        );
      case _LegendSwatch.warmRing:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.warm, width: 2),
          ),
        );
      case _LegendSwatch.oneWay:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kOneWayTint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kOneWayTint, width: 1.5),
          ),
        );
      case _LegendSwatch.held:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.lock_outline_rounded, size: 8, color: c.ink3),
        );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
      ],
    );
  }
}

// ─── Sheets ────────────────────────────────────────────────────────────

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// The booked-seat detail sheet. Name + phone + Call, the seat context, the
/// requested lines, a group/priority indicator, and a "Free seat" action.
class _OccupantSheet extends StatelessWidget {
  final Passenger occupant;
  final SeatCell cell;
  final Bus bus;
  final String tourTitle;
  final bool isShared;
  final Future<void> Function() onFreeSeat;

  /// Move / Swap entry points. Both open the destination-bus picker → swap
  /// assistant; null renders disabled placeholders (e.g. a shared half-double
  /// whose move semantics aren't supported here yet).
  final VoidCallback? onMove;
  final VoidCallback? onSwap;

  const _OccupantSheet({
    required this.occupant,
    required this.cell,
    required this.bus,
    required this.tourTitle,
    required this.isShared,
    required this.onFreeSeat,
    required this.onMove,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final priority = occupant.isPriorityApproved || cell.forward;
    final hasGroup = occupant.groupId != null && occupant.groupId!.isNotEmpty;
    final requestSummary = occupant.requestSummary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          // Name + phone + Call.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      occupant.displayName,
                      style: UgamText.titleM.copyWith(color: c.ink),
                    ),
                    if (occupant.phone.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        occupant.phone,
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (occupant.phone.isNotEmpty) ...[
                const SizedBox(width: UgamSpacing.sm),
                Semantics(
                  button: true,
                  label: 'Call ${occupant.phone}',
                  child: GestureDetector(
                    onTap: () => PhoneDialer.call(occupant.phone),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: c.accentFill,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.phone_rounded,
                        size: 18,
                        color: c.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // Seat context chip.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.md,
              vertical: UgamSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
              border: Border.all(color: c.accent.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.event_seat_rounded, size: 18, color: c.accent),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Seat ${cell.seatId}'
                        '${isShared ? ' (shared)' : ''}',
                        style: UgamText.titleS.copyWith(color: c.accent),
                      ),
                      Text(
                        '${bus.name} · $tourTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.caption.copyWith(
                          color: c.accent.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Requested lines summary.
          const SizedBox(height: UgamSpacing.md),
          _SheetRow(label: 'Requested', value: requestSummary, c: c),
          // Group / priority / trip indicators.
          if (priority || hasGroup || occupant.tripType.isOneWay) ...[
            const SizedBox(height: UgamSpacing.sm + 2),
            Wrap(
              spacing: UgamSpacing.sm,
              runSpacing: UgamSpacing.sm,
              children: [
                if (priority)
                  _IndicatorChip(
                    icon: Icons.star_rounded,
                    label: occupant.isPriorityApproved
                        ? 'Priority'
                        : 'Forward zone',
                    fill: c.warmFill,
                    tint: c.warm,
                  ),
                // Trip leg — one-way occupants read as GO / RET in kOneWayTint.
                _IndicatorChip(
                  icon: occupant.tripType == TripType.returnOnly
                      ? Icons.south_west_rounded
                      : occupant.tripType == TripType.outboundOnly
                      ? Icons.north_east_rounded
                      : Icons.sync_alt_rounded,
                  label: switch (occupant.tripType) {
                    TripType.roundTrip => 'Round trip',
                    TripType.outboundOnly => 'GO · outbound only',
                    TripType.returnOnly => 'RET · return only',
                  },
                  fill: occupant.tripType.isOneWay
                      ? kOneWayTint.withValues(alpha: 0.16)
                      : c.cardElev,
                  tint: occupant.tripType.isOneWay ? kOneWayTint : c.ink2,
                ),
                if (hasGroup)
                  _IndicatorChip(
                    icon: Icons.group_rounded,
                    label: 'Group ${occupant.groupId}',
                    fill: c.cardElev,
                    tint: c.ink2,
                    dot: groupColorForId(occupant.groupId!),
                  ),
              ],
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          // Move / Swap — open the destination-bus picker → swap assistant.
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onMove,
                  icon: const Icon(Icons.open_with_rounded, size: 16),
                  label: const Text('Move'),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: c.onAccent,
                    disabledBackgroundColor: c.cardElev,
                    disabledForegroundColor: c.ink3,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(UgamRadius.input),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onSwap,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                  label: const Text('Swap'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.accent,
                    disabledForegroundColor: c.ink3,
                    side: BorderSide(
                      color: (onSwap == null ? c.border : c.accent).withValues(
                        alpha: 0.5,
                      ),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(UgamRadius.input),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          // Free seat — release the berth (and decrement the request line).
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onFreeSeat,
              icon: const Icon(Icons.event_seat_outlined, size: 16),
              label: const Text('Free seat'),
              style: OutlinedButton.styleFrom(
                foregroundColor: c.danger,
                side: BorderSide(color: c.danger.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
          // Close.
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: c.ink2),
              child: const Text('Close'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A shared-double picker: lists the two berth-holders so the agent chooses
/// whom to act on before the detail sheet opens.
class _SharedChooserSheet extends StatelessWidget {
  final List<Passenger> occupants;
  final String seatId;
  final ValueChanged<Passenger> onPick;

  const _SharedChooserSheet({
    required this.occupants,
    required this.seatId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          Text(
            'Seat $seatId is shared',
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'Two passengers share this Double Sofa. Pick one to view.',
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (final p in occupants)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: GestureDetector(
                onTap: () => onPick(p),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.accent,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _SeatTile.initials(p.displayName),
                          style: UgamText.bodyStrong.copyWith(
                            color: c.onAccent,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: Text(
                          p.displayName,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: c.ink3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Roster (List view) ─────────────────────────────────────────────────

/// The readable roster the agent asked for: one row per OCCUPIED seat showing
/// the seat id, the FULL passenger name, the mobile number (tappable to call
/// via [PhoneDialer]), a trip badge (Round / GO / RET) and the group-colour dot
/// — instead of the chart's terse initials. A leg-reused seat (GO + RET on one
/// seatId) yields a row PER holder so both names + mobiles are visible.
///
/// Tapping a row's body opens the same occupant sheet the chart uses, so Move /
/// Swap / Free stay reachable from the list.
class _RosterList extends StatelessWidget {
  final BusLayout layout;
  final Map<String, List<Passenger>> occupants;
  final GroupColorResolver groupColors;
  final UgamColorSet c;

  /// Opens the occupant sheet for a tapped seat. Passes the seat's full
  /// occupant list so a shared / leg-reused seat still routes correctly.
  final void Function(SeatCell cell, List<Passenger> seatOccupants) onTapSeat;

  const _RosterList({
    required this.layout,
    required this.occupants,
    required this.groupColors,
    required this.c,
    required this.onTapSeat,
  });

  @override
  Widget build(BuildContext context) {
    // Occupied seats in a stable reading order (row, then column).
    final occupiedCells =
        layout.grid
            .where(
              (cell) =>
                  cell.seatId != null &&
                  (occupants[cell.seatId]?.isNotEmpty ?? false),
            )
            .toList()
          ..sort((a, b) {
            final r = a.row.compareTo(b.row);
            return r != 0 ? r : a.col.compareTo(b.col);
          });

    // Flatten to one entry per (seat, holder) so a leg-reused seat lists both.
    final rows = <_RosterEntry>[];
    for (final cell in occupiedCells) {
      final seatOccupants = occupants[cell.seatId] ?? const <Passenger>[];
      for (final p in seatOccupants) {
        rows.add(_RosterEntry(cell: cell, passenger: p, all: seatOccupants));
      }
    }

    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.huge),
          child: Text(
            'No seats are booked on this bus yet.',
            textAlign: TextAlign.center,
            style: UgamText.body.copyWith(color: c.ink2),
          ),
        ),
      );
    }

    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.sm),
      itemBuilder: (_, i) {
        final e = rows[i];
        return _RosterRow(
          entry: e,
          groupColors: groupColors,
          c: c,
          onTap: () => onTapSeat(e.cell, e.all),
        );
      },
    );
  }
}

/// One flattened roster line: a seat cell + the single holder this row is for,
/// plus the seat's full occupant list (so a tap can route a shared/leg seat).
class _RosterEntry {
  final SeatCell cell;
  final Passenger passenger;
  final List<Passenger> all;

  const _RosterEntry({
    required this.cell,
    required this.passenger,
    required this.all,
  });
}

class _RosterRow extends StatelessWidget {
  final _RosterEntry entry;
  final GroupColorResolver groupColors;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _RosterRow({
    required this.entry,
    required this.groupColors,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = entry.passenger;
    final cell = entry.cell;
    final priority = p.isPriorityApproved || cell.forward;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColors.colorFor(p.groupId!) : null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(
            color: priority ? c.warm.withValues(alpha: 0.55) : c.border,
          ),
        ),
        child: Row(
          children: [
            // Seat id pill.
            Container(
              width: 46,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Text(
                cell.seatId ?? '',
                style: UgamText.tabular(
                  UgamText.caption.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            // Full name + mobile + badges.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (groupColor != null) ...[
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: groupColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          p.displayName,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _TripBadge(tripType: p.tripType, c: c),
                      if (priority) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.star_rounded, size: 14, color: c.warm),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    p.phone.isEmpty ? 'No mobile on file' : p.phone,
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ),
                ],
              ),
            ),
            // Call button.
            if (p.phone.isNotEmpty) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: 'Call ${p.phone}',
                child: GestureDetector(
                  onTap: () => PhoneDialer.call(p.phone),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.phone_rounded, size: 17, color: c.accent),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact trip badge: "Round" (neutral) or "GO" / "RET" in [kOneWayTint].
class _TripBadge extends StatelessWidget {
  final TripType tripType;
  final UgamColorSet c;

  const _TripBadge({required this.tripType, required this.c});

  @override
  Widget build(BuildContext context) {
    final isOneWay = tripType.isOneWay;
    final label = switch (tripType) {
      TripType.roundTrip => 'Round',
      TripType.outboundOnly => 'GO',
      TripType.returnOnly => 'RET',
    };
    final tint = isOneWay ? kOneWayTint : c.ink2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: isOneWay ? kOneWayTint.withValues(alpha: 0.16) : c.bg,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        border: Border.all(
          color: isOneWay ? kOneWayTint.withValues(alpha: 0.85) : c.border,
        ),
      ),
      child: Text(
        label,
        style: UgamText.micro.copyWith(
          color: tint,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Leg-reuse sheet: one seat reused across disjoint legs. Lists BOTH holders —
/// the GO (outbound-only) and RET (return-only) passenger — each with name,
/// phone, a Call button, and a leg badge. Tapping a row opens that holder's
/// full detail sheet (Move / Swap / Free).
class _LegHoldersSheet extends StatelessWidget {
  final Passenger go;
  final Passenger ret;
  final String seatId;
  final ValueChanged<Passenger> onPick;

  const _LegHoldersSheet({
    required this.go,
    required this.ret,
    required this.seatId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          Text(
            'Seat $seatId — two legs',
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'This seat is reused across legs: one passenger rides out (GO), a '
            'different passenger rides back (RET). Tap one to manage.',
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          _LegHolderRow(
            passenger: go,
            badge: 'GO',
            c: c,
            onTap: () => onPick(go),
          ),
          const SizedBox(height: UgamSpacing.sm),
          _LegHolderRow(
            passenger: ret,
            badge: 'RET',
            c: c,
            onTap: () => onPick(ret),
          ),
        ],
      ),
    );
  }
}

class _LegHolderRow extends StatelessWidget {
  final Passenger passenger;
  final String badge;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _LegHolderRow({
    required this.passenger,
    required this.badge,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(color: kOneWayTint.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            _LegPill(label: badge, tint: kOneWayTint),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    passenger.displayName,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (passenger.phone.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      passenger.phone,
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink2),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (passenger.phone.isNotEmpty) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: 'Call ${passenger.phone}',
                child: GestureDetector(
                  onTap: () => PhoneDialer.call(passenger.phone),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.phone_rounded, size: 16, color: c.accent),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _SheetRow({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _IndicatorChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color fill;
  final Color tint;
  final Color? dot;

  const _IndicatorChip({
    required this.icon,
    required this.label,
    required this.fill,
    required this.tint,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ] else ...[
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: UgamText.micro.copyWith(
              color: tint,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Destination-bus picker ──────────────────────────────────────────────

/// Lists the tour's buses so the agent picks where to move [mover]. The bus
/// the mover currently sits on is tagged so it reads as a deliberate choice.
class _DestinationPickerSheet extends StatelessWidget {
  final Passenger mover;
  final List<Bus> buses;
  final String currentBusId;
  final ValueChanged<Bus> onPick;

  const _DestinationPickerSheet({
    required this.mover,
    required this.buses,
    required this.currentBusId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          Text(
            'Move ${mover.displayName} to…',
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'Pick the destination bus.',
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (final b in buses)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: GestureDetector(
                onTap: () => onPick(b),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.directions_bus_rounded,
                        size: 20,
                        color: c.accent,
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: Text(
                          b.name,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (b.id == currentBusId)
                        _IndicatorChip(
                          icon: Icons.place_rounded,
                          label: 'Current',
                          fill: c.cardElev,
                          tint: c.ink2,
                        ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: c.ink3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Swap assistant ──────────────────────────────────────────────────────

/// Surfaces a [SwapAssist] for moving [mover] onto [destination]:
///   * Free seats — tap to place the mover there outright.
///   * Can swap — ranked occupants the mover can exchange seats with.
///   * Cannot move — greyed occupants with the blocking reason.
class _SwapAssistSheet extends StatelessWidget {
  final Passenger mover;
  final Bus destination;
  final SwapAssist assist;
  final ValueChanged<String> onTakeFree;
  final ValueChanged<SwapCandidate> onSwap;

  const _SwapAssistSheet({
    required this.mover,
    required this.destination,
    required this.assist,
    required this.onTakeFree,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasAnything =
        assist.freeSeatIds.isNotEmpty ||
        assist.movable.isNotEmpty ||
        assist.blocked.isNotEmpty;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetGrabber(),
            Text(
              'Move ${mover.displayName} → ${destination.name}',
              style: UgamText.titleM.copyWith(color: c.ink),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              mover.requestSummary,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
            const SizedBox(height: UgamSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!hasAnything)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: UgamSpacing.lg,
                        ),
                        child: Text(
                          'No room on ${destination.name} — every seat is taken '
                          'by a grouped or priority passenger.',
                          style: UgamText.body.copyWith(color: c.ink2),
                        ),
                      ),
                    // (a) Free seats.
                    if (assist.freeSeatIds.isNotEmpty) ...[
                      _SwapSectionLabel(
                        label: 'Free seats',
                        count: assist.freeSeatIds.length,
                        c: c,
                      ),
                      Wrap(
                        spacing: UgamSpacing.sm,
                        runSpacing: UgamSpacing.sm,
                        children: [
                          for (final seatId in assist.freeSeatIds)
                            GestureDetector(
                              onTap: () => onTakeFree(seatId),
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UgamSpacing.md,
                                  vertical: UgamSpacing.sm + 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.accentFill,
                                  borderRadius: BorderRadius.circular(
                                    UgamRadius.chip,
                                  ),
                                  border: Border.all(
                                    color: c.accent.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.event_seat_rounded,
                                      size: 14,
                                      color: c.accent,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      seatId,
                                      style: UgamText.tabular(
                                        UgamText.caption.copyWith(
                                          color: c.accent,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: UgamSpacing.md),
                    ],
                    // (b) Movable / can-swap candidates.
                    if (assist.movable.isNotEmpty) ...[
                      _SwapSectionLabel(
                        label: 'Can swap',
                        count: assist.movable.length,
                        c: c,
                      ),
                      for (final cand in assist.movable)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: GestureDetector(
                            onTap: () => onSwap(cand),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: const EdgeInsets.all(UgamSpacing.md),
                              decoration: BoxDecoration(
                                color: c.cardElev,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.row,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: c.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      _SeatTile.initials(cand.passengerName),
                                      style: UgamText.bodyStrong.copyWith(
                                        color: c.onAccent,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: UgamSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          cand.passengerName,
                                          style: UgamText.bodyStrong.copyWith(
                                            color: c.ink,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Seat ${cand.seatId} · ${cand.reason}',
                                          style: UgamText.micro.copyWith(
                                            color: c.ink2,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: UgamSpacing.sm),
                                  Icon(
                                    Icons.swap_horiz_rounded,
                                    size: 18,
                                    color: c.accent,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.md),
                    ],
                    // (c) Blocked occupants — greyed, with the reason.
                    if (assist.blocked.isNotEmpty) ...[
                      _SwapSectionLabel(
                        label: 'Cannot move',
                        count: assist.blocked.length,
                        c: c,
                      ),
                      for (final b in assist.blocked)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: Opacity(
                            opacity: 0.55,
                            child: Container(
                              padding: const EdgeInsets.all(UgamSpacing.md),
                              decoration: BoxDecoration(
                                color: c.cardElev.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.row,
                                ),
                                border: Border.all(color: c.border),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 18,
                                    color: c.ink3,
                                  ),
                                  const SizedBox(width: UgamSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          b.passengerName,
                                          style: UgamText.bodyStrong.copyWith(
                                            color: c.ink2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          b.reason,
                                          style: UgamText.micro.copyWith(
                                            color: c.ink3,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: UgamSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(foregroundColor: c.ink2),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwapSectionLabel extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _SwapSectionLabel({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: Row(
        children: [
          Text(label, style: UgamText.titleS.copyWith(color: c.ink)),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: UgamText.tabular(UgamText.caption.copyWith(color: c.ink3)),
          ),
        ],
      ),
    );
  }
}

// ─── Edit-mode seat flags sheet ──────────────────────────────────────────

/// Two-switch sheet for an individual seat in edit mode: "Forward / premium
/// seat" and "Hold / reserved". Each switch fires its controller setter as it
/// flips, so the chart repaints reactively (and a still-open sheet keeps the
/// live state via the local mirror).
class _SeatFlagsSheet extends StatefulWidget {
  final String seatId;
  final String typeLabel;
  final String busName;
  final bool forward;
  final bool reserved;
  final ValueChanged<bool> onForward;
  final ValueChanged<bool> onReserved;

  const _SeatFlagsSheet({
    required this.seatId,
    required this.typeLabel,
    required this.busName,
    required this.forward,
    required this.reserved,
    required this.onForward,
    required this.onReserved,
  });

  @override
  State<_SeatFlagsSheet> createState() => _SeatFlagsSheetState();
}

class _SeatFlagsSheetState extends State<_SeatFlagsSheet> {
  late bool _forward = widget.forward;
  late bool _reserved = widget.reserved;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.tune_rounded, size: 18, color: c.ink),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Seat ${widget.seatId}',
                      style: UgamText.titleM.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.typeLabel} · ${widget.busName}',
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          _FlagSwitch(
            icon: Icons.star_rounded,
            title: 'Forward / premium seat',
            subtitle: 'Priority passengers fill these first.',
            value: _forward,
            // Warm = attention; the forward zone is the priority/premium band.
            activeColor: c.warm,
            c: c,
            onChanged: (v) {
              setState(() => _forward = v);
              widget.onForward(v);
            },
          ),
          const SizedBox(height: UgamSpacing.sm),
          _FlagSwitch(
            icon: Icons.lock_outline_rounded,
            title: 'Hold / reserved',
            subtitle: 'Auto-fill skips a held seat.',
            value: _reserved,
            activeColor: c.accent,
            c: c,
            onChanged: (v) {
              setState(() => _reserved = v);
              widget.onReserved(v);
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: c.ink2),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlagSwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final Color activeColor;
  final UgamColorSet c;
  final ValueChanged<bool> onChanged;

  const _FlagSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.activeColor,
    required this.c,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(
          color: value ? activeColor.withValues(alpha: 0.5) : c.border,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: value ? activeColor : c.ink3),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: UgamText.bodyStrong.copyWith(color: c.ink)),
                const SizedBox(height: 1),
                Text(subtitle, style: UgamText.micro.copyWith(color: c.ink2)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: activeColor,
            activeThumbColor: c.onAccent,
          ),
        ],
      ),
    );
  }
}
