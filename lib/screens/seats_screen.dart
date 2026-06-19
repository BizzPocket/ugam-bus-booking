import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';

import 'manage_buses_screen.dart';
import 'tour_overview_screen.dart';
import 'tour_seat_assignment_screen.dart';

/// The two faces of seating, unified behind one screen as a SUMMARY → GRID
/// relationship (NOT two peer modes):
///
///   * **Summary (primary)** — the auto-fill cockpit ([TourOverviewScreen]):
///     placed/total, requirements, capacity, per-bus cards, and the "Auto-fill
///     all" CTA. This is where the agent LANDS. A prominent "Edit seats by
///     hand" CTA drops them into the grid.
///   * **Grid (secondary)** — the seat workbench ([TourSeatAssignmentScreen]):
///     tap-to-place pending passengers, drag to move/swap seated ones, tap an
///     occupant to manage them (call / move / swap / priority / handler / free),
///     and clear a whole bus from the head bar.
///
/// Reaching the grid is a deliberate step OUT of the summary — the head bar
/// shows a "Summary" back-affordance while on the grid so the agent always has
/// a way back.
enum SeatsMode { summary, grid }

/// Unified per-tour "Seats" workspace — the single entry for everything
/// seating. The shell owns the chrome (back, tour title, manage-buses,
/// clear-bus) and switches between the summary and the workbench grid.
///
/// Both surfaces are **lazy-mounted** (an [IndexedStack] over visited
/// children) so the one the agent has actually opened keeps its local state
/// (selected passenger, bus, scroll) when switching.
class SeatsScreen extends StatefulWidget {
  final String tourId;
  final SeatsMode initialMode;

  /// Optional deep-link: lands the grid directly on this passenger (from the
  /// Requests "Assign Seats →" action).
  final String? initialPassengerId;

  /// Optional deep-link: lands the grid pre-selected to this bus (from an
  /// overview bus card or a seating exception). When set, [initialMode]
  /// usually wants to be [SeatsMode.grid].
  final String? initialBusId;

  const SeatsScreen({
    super.key,
    required this.tourId,
    this.initialMode = SeatsMode.summary,
    this.initialPassengerId,
    this.initialBusId,
  });

  @override
  State<SeatsScreen> createState() => _SeatsScreenState();
}

class _SeatsScreenState extends State<SeatsScreen> {
  late int _mode = widget.initialMode.index;

  /// The bus the grid should open on. Seeded from the deep-link, then updated
  /// when the agent taps a summary bus card to "edit" that bus by hand.
  late String? _gridBusId = widget.initialBusId;

  /// Surfaces the agent has actually opened — only these are built. Seeded with
  /// the initial mode so the first paint shows exactly one body.
  late final Set<int> _visited = {_mode};

  /// The "clear all assigned seats" action for the grid's currently selected
  /// bus (or null when nothing is assigned). The embedded
  /// [TourSeatAssignmentScreen] pushes it here so the shell head bar — which
  /// owns the chrome in embedded mode — can surface it.
  final ValueNotifier<VoidCallback?> _clearAction = ValueNotifier(null);

  TourController get _ctrl => Get.find<TourController>();

  bool get _onGrid => _mode == SeatsMode.grid.index;

  @override
  void dispose() {
    _clearAction.dispose();
    super.dispose();
  }

  /// Switch to the workbench grid. [busId] optionally pre-selects a bus (from a
  /// summary bus-card tap). Changing [_gridBusId] flips the grid's [ValueKey]
  /// in [_modeBody], which remounts its State so the new bus's initState seed
  /// actually takes — even when the grid was already mounted on another bus.
  void _openGrid({String? busId}) {
    setState(() {
      if (busId != null) _gridBusId = busId;
      _mode = SeatsMode.grid.index;
      _visited.add(SeatsMode.grid.index);
    });
  }

  void _showSummary() {
    setState(() {
      _mode = SeatsMode.summary.index;
      _visited.add(SeatsMode.summary.index);
    });
  }

  Widget _modeBody(int i) {
    if (i == SeatsMode.summary.index) {
      return TourOverviewScreen(
        tourId: widget.tourId,
        embedded: true,
        onEditByHand: () => _openGrid(),
        onBusTap: (busId) => _openGrid(busId: busId),
      );
    }
    // A unique key per selected bus forces the State (and its initState bus
    // seed) to rebuild when the agent jumps from one bus card to another.
    return TourSeatAssignmentScreen(
      key: ValueKey('grid-${_gridBusId ?? 'first'}'),
      tourId: widget.tourId,
      initialPassengerId: widget.initialPassengerId,
      initialBusId: _gridBusId,
      embedded: true,
      clearActionSink: _clearAction,
    );
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
            _header(c),
            Expanded(
              child: IndexedStack(
                index: _mode,
                sizing: StackFit.expand,
                children: [
                  for (int i = 0; i < 2; i++)
                    if (_visited.contains(i))
                      _modeBody(i)
                    else
                      const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(UgamColorSet c) {
    final title = _ctrl.getTour(widget.tourId)?.title ?? tr('seats.title');
    // On the grid, the leading control becomes a "Summary" affordance so the
    // agent always reads the grid as a step OUT of the summary, with a way
    // back. On the summary, it's a plain back to the tour workspace.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          if (_onGrid)
            UgamIconButton(
              icon: Icons.arrow_back_rounded,
              onTap: _showSummary,
              semanticLabel: tr('seats.back_to_summary'),
            )
          else
            UgamIconButton(
              icon: Icons.arrow_back_rounded,
              onTap: () => Get.back(),
            ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _onGrid
                      ? tr('seats.grid_subtitle')
                      : tr('seats.summary_subtitle'),
                  style: UgamText.caption.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // Clear-all-assigned-seats — lives on the head bar. Only shows on the
          // grid when the selected bus actually has seats to free.
          ValueListenableBuilder<VoidCallback?>(
            valueListenable: _clearAction,
            builder: (context, clearAction, _) {
              if (!_onGrid || clearAction == null) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(right: UgamSpacing.sm),
                child: UgamIconButton(
                  icon: Icons.layers_clear_rounded,
                  tone: UgamIconButtonTone.danger,
                  onTap: clearAction,
                  semanticLabel: tr('seat_assignment.clear_bus.confirm'),
                ),
              );
            },
          ),
          UgamIconButton(
            icon: Icons.directions_bus_filled_rounded,
            onTap: () => Get.to(() => ManageBusesScreen(tourId: widget.tourId)),
          ),
        ],
      ),
    );
  }
}
