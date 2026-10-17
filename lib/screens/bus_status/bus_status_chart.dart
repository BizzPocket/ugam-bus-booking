part of '../bus_status_screen.dart';

/// The rounded card containing the bus chart. Renders the CANONICAL
/// [SeatChartTile] (read-only) so the status chart reads identically to the
/// auto-fill / assign / handler charts — same tile look, same group/priority
/// rings, same one-way leg colours — just without the drag/drop wiring.
class _SeatChartCard extends StatelessWidget {
  final BusLayout layout;
  final Map<String, List<Passenger>> assignments;
  final GroupColorResolver groupColors;

  /// The tapped seat's id + its occupants (berth-accurate, so a whole double
  /// held solo arrives as the rider twice) — the handler de-dupes and shows one
  /// or all.
  final void Function(String seatId, List<Passenger> occupants) onSeatTap;

  const _SeatChartCard({
    required this.layout,
    required this.assignments,
    required this.groupColors,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    if (layout.totalCells == 0) {
      return UgamCard.plain(
        child: Center(
          child: Text(
            tr('bus_status.no_layout'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
        ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.lg,
      ),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        child: CombinedSeatGrid(
          layout: layout,
          cellWidth: kSeatTileW,
          cellHeight: kSeatTileH,
          colGap: 6,
          rowGap: 6,
          driverLabel: tr('bus_status.driver_label'),
          // Header band so the top-left expand button clears the first seat.
          reserveTopAction: true,
          tileBuilder: (ctx, cell) {
            final occupants = cell.seatId != null
                ? (assignments[cell.seatId] ?? const <Passenger>[])
                : const <Passenger>[];
            return RepaintBoundary(
              child: SeatChartTile(
                cell: cell,
                occupants: occupants,
                groupColors: groupColors,
                markHalfDouble: true,
                // Read-only: a booked seat surfaces the passenger sheet; a free
                // seat is inert here (re-seating lives in the unified grid).
                onTapBooked: occupants.isEmpty
                    ? null
                    : () => onSeatTap(cell.seatId!, occupants),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;

  const _SheetRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            flex: 2,
            child: Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            flex: 3,
            child: Text(
              value.isEmpty ? '—' : value,
              style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Below-the-grid actions, two rows: Edit bus · Open seat assignment, then the
/// ONE money door (opens the same Collect / Bus-money sheet as the app-bar
/// icon) beside "Operate as handler" when that applies. There used to be five
/// stacked buttons, two of them near-identical money links ("Collect" and
/// "Collection & money") that each opened half of that sheet.
class _BottomActions extends StatelessWidget {
  final Tour tour;
  final Bus bus;
  final bool showOperateAsHandler;
  final VoidCallback onMoney;

  const _BottomActions({
    required this.tour,
    required this.bus,
    required this.showOperateAsHandler,
    required this.onMoney,
  });

  @override
  Widget build(BuildContext context) {
    final tourId = tour.id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.edit_rounded,
                  label: tr('bus_status.action.edit_bus'),
                  onPressed: () => Get.to(
                    () => AddBusScreen(tourId: tourId, existing: bus),
                    transition: Transition.cupertino,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.grid_view_rounded,
                  label: tr('bus_status.action.open_seat_assignment'),
                  onPressed: () => Get.to(
                    () => SeatsScreen(
                      tourId: tourId,
                      initialMode: SeatsMode.grid,
                      initialBusId: bus.id,
                    ),
                    transition: Transition.cupertino,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.payments_rounded,
                  label: tr('bus_status.action.collection_money'),
                  onPressed: onMoney,
                ),
              ),
              if (showOperateAsHandler) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: UgamButton(
                    kind: UgamButtonKind.tonal,
                    expand: true,
                    icon: Icons.manage_accounts_rounded,
                    label: tr('bus_status.action_operate_as_handler'),
                    onPressed: () =>
                        openAdminHandlerOperate(tour: tour, busId: bus.id),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _HandlerBadge extends StatelessWidget {
  const _HandlerBadge();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded, size: 14, color: c.warm),
          const SizedBox(width: 6),
          Text(
            tr('bus_status.handler_badge'),
            style: UgamText.micro.copyWith(
              color: c.warm,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
