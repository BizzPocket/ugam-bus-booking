import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../design/group_color.dart';
import '../design/price_band_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/expense.dart';
import '../models/handler_manifest.dart';
import '../models/passenger.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../services/whatsapp_cloud_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/time_format.dart';
import 'fullscreen_chart_screen.dart';

/// The passengers holding one seat, resolved by leg.
///
/// A single seat can now be LEG-SHARED: an `outboundOnly` passenger (the GO
/// leg) and a separate `returnOnly` passenger (the RETURN leg) can both hold
/// the same seatId on disjoint legs. A `roundTrip` passenger holds BOTH legs
/// exclusively (so [go] and [ret] are the same person). [primary] is the
/// passenger to show first / use for the single-occupant tile look.
class _SeatOccupants {
  /// The GO-leg occupant (outboundOnly or roundTrip), if any.
  final Passenger? go;

  /// The RETURN-leg occupant (returnOnly or roundTrip), if any.
  final Passenger? ret;

  const _SeatOccupants({this.go, this.ret});

  bool get isEmpty => go == null && ret == null;

  /// True when GO and RETURN are two DIFFERENT people sharing the seat across
  /// legs (an outbound-only + a return-only) — the leg-shared case.
  bool get isLegShared => go != null && ret != null && go!.id != ret!.id;

  /// The single passenger when the seat is held by one person (a round-trip,
  /// or a lone one-way leg); null when leg-shared or empty.
  Passenger? get sole {
    if (isEmpty) return null;
    if (isLegShared) return null;
    return go ?? ret;
  }

  /// Every DISTINCT passenger on this seat, GO first.
  List<Passenger> get all {
    final out = <Passenger>[];
    if (go != null) out.add(go!);
    if (ret != null && (go == null || ret!.id != go!.id)) out.add(ret!);
    return out;
  }
}

/// Builds a leg-resolved occupant view for [seatId] on [busId] from the
/// manifest's passengers. A whole-double (one passenger, two assignment
/// entries on the SAME seatId) still resolves to a single occupant; a
/// genuine leg-shared seat resolves to two distinct people on disjoint legs.
_SeatOccupants _occupantsForSeat(
  HandlerManifest manifest,
  String busId,
  String seatId,
) {
  Passenger? go;
  Passenger? ret;
  for (final p in manifest.passengers) {
    final holdsSeat = p.assignedSeats.any(
      (a) => a.busId == busId && a.seatId == seatId,
    );
    if (!holdsSeat) continue;
    if (p.tripType.usesOutbound && go == null) go = p;
    if (p.tripType.usesReturn && ret == null) ret = p;
  }
  return _SeatOccupants(go: go, ret: ret);
}

/// Resolves the leg-aware occupants for EVERY seat on [busId] in a single
/// O(passengers × assignedSeats) pass, keyed by seatId.
///
/// The grid and roster previously called [_occupantsForSeat] once per seat
/// cell — O(cells × passengers) — so a 50-seat / 50-passenger bus did ~2,500
/// passenger scans on every rebuild (bus switch, scroll, post-save setState),
/// all on the UI thread. This builds the lookup once per build and the hot
/// paths do an O(1) map read instead. "First passenger wins per leg" ordering
/// is preserved via [Map.putIfAbsent] over the same passenger iteration order
/// as [_occupantsForSeat].
Map<String, _SeatOccupants> _occupantsBySeatForBus(
  HandlerManifest manifest,
  String busId,
) {
  final go = <String, Passenger>{};
  final ret = <String, Passenger>{};
  for (final p in manifest.passengers) {
    for (final a in p.assignedSeats) {
      if (a.busId != busId) continue;
      if (p.tripType.usesOutbound) go.putIfAbsent(a.seatId, () => p);
      if (p.tripType.usesReturn) ret.putIfAbsent(a.seatId, () => p);
    }
  }
  final out = <String, _SeatOccupants>{};
  for (final seatId in {...go.keys, ...ret.keys}) {
    out[seatId] = _SeatOccupants(go: go[seatId], ret: ret[seatId]);
  }
  return out;
}

/// The two ways the handler reads the chart: the visual seat [grid] or the
/// call-first [list] (a roster of full name + mobile per seat).
enum _ViewMode { grid, list }

/// Read-only full bus chart for a tour "handler" (group coordinator).
///
/// The handler is a customer the agent has flagged as the on-the-ground
/// point of contact. Unlike a regular customer — who only sees their own
/// seats — the handler can pull the WHOLE manifest (every bus + every
/// passenger) so they can find any seatmate and call them. This screen is
/// strictly read-only: no drag, no edit, no assignment. It mirrors the
/// agent's `TourSeatAssignmentScreen` look (bus pills + Ugam seat tiles)
/// but every tap on an occupied seat opens a call sheet instead.
///
/// Data comes from `CustomerRequestsStore.handlerTourManifest`, the same
/// singleton store the customer seat-layout viewer uses.
class HandlerBusChartScreen extends StatefulWidget {
  final String requestId;

  const HandlerBusChartScreen({super.key, required this.requestId});

  @override
  State<HandlerBusChartScreen> createState() => _HandlerBusChartScreenState();
}

class _HandlerBusChartScreenState extends State<HandlerBusChartScreen> {
  final _store = CustomerRequestsStore();

  bool _loading = true;
  String? _error;
  HandlerManifest? _manifest;
  String? _selectedBusId;

  /// Chart vs roster. The handler most often needs full names + mobiles to
  /// call people, so the call-first List (roster) is the default view; the
  /// visual Grid sits alongside it.
  _ViewMode _viewMode = _ViewMode.list;

  /// Local, mutable collection cache keyed by '"$passengerId|$busId"'.
  /// Seeded from the manifest once loaded; updated in-place after each save so
  /// the chart recolors and the summary refreshes without a full reload.
  final Map<String, Collection> _collections = {};

  /// Local, mutable expense cache keyed by expense id. Seeded from the manifest
  /// and updated in-place after each add / delete so the per-bus expense ledger
  /// and the "spent / in hand" summary refresh without a full reload.
  final Map<String, Expense> _expenses = {};

  String _collectionKey(String passengerId, String busId, String seatId) =>
      '$passengerId|$busId|$seatId';

  /// Expenses logged against [busId], oldest first.
  List<Expense> _expensesForBus(String busId) {
    final list = _expenses.values.where((e) => e.busId == busId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  /// Reads the local cache first, falling back to the manifest. Returns null
  /// when no money has been collected for that passenger on that bus.
  Collection? _collectionFor(String passengerId, String busId, String seatId) {
    final cached = _collections[_collectionKey(passengerId, busId, seatId)];
    if (cached != null) return cached;
    return _manifest?.collectionFor(passengerId, busId, seatId);
  }

  /// Aggregates collection figures across every passenger holding a seat on
  /// [bus], mirroring collection_screen's per-bus summary.
  _BusSummary _summaryForBus(HandlerManifest manifest, Bus bus) {
    double collected = 0;
    double toReturn = 0;
    double toCollect = 0;
    double spent = 0;
    for (final e in _expensesForBus(bus.id)) {
      spent += e.amount;
    }
    for (final p in manifest.passengers) {
      // Distinct seats only: a whole double-sofa = TWO entries on one seatId,
      // already full-priced by amountDueForSeat — iterate per distinct seatId
      // (not per entry) so it isn't counted twice.
      final seatIds = p.assignedSeats
          .where((a) => a.busId == bus.id)
          .map((a) => a.seatId)
          .toSet();
      for (final seatId in seatIds) {
        final due = bus.amountDueForSeat(p, seatId);
        final col = _collectionFor(p.id, bus.id, seatId);
        if (col != null) {
          collected += col.netCollected;
          toReturn += col.changeToReturn;
          toCollect += col.stillToCollect;
        } else {
          // No collection yet → this seat's due is still to collect.
          toCollect += due;
        }
      }
    }
    return _BusSummary(
      collected: collected,
      toReturn: toReturn,
      toCollect: toCollect,
      spent: spent,
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final manifest = await _store.handlerTourManifest(widget.requestId);
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _collections
          ..clear()
          ..addEntries(
            (manifest?.collections ?? const <Collection>[]).map(
              (col) => MapEntry(
                _collectionKey(col.passengerId, col.busId, col.seatId),
                col,
              ),
            ),
          );
        _expenses
          ..clear()
          ..addEntries(
            (manifest?.expenses ?? const <Expense>[]).map(
              (e) => MapEntry(e.id, e),
            ),
          );
        _selectedBusId = manifest?.buses.isNotEmpty == true
            ? manifest!.buses.first.id
            : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr('handler_chart.error_load');
        _loading = false;
      });
    }
  }

  Bus? _selectedBus(HandlerManifest manifest) {
    if (manifest.buses.isEmpty) return null;
    final id = _selectedBusId;
    if (id != null) {
      final match = manifest.buses.where((b) => b.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    return manifest.buses.first;
  }

  void _onSeatTapped(Bus bus, String seatId, Passenger occupant) {
    final manifest = _manifest;
    // A leg-shared seat (a GO occupant + a different RETURN occupant) needs a
    // chooser: the handler picks which person to call / collect from. A single
    // occupant goes straight to the collect sheet.
    final occ = manifest == null
        ? const _SeatOccupants()
        : _occupantsForSeat(manifest, bus.id, seatId);
    if (occ.isLegShared) {
      _showLegSharedChooser(bus, seatId, occ);
      return;
    }
    _showOccupantSheet(bus, seatId, occupant);
  }

  /// Leg-shared seat → a small chooser listing the GO occupant and the RETURN
  /// occupant (each with phone + Call), so the handler picks whom to act on
  /// before the collect sheet opens.
  Future<void> _showLegSharedChooser(
    Bus bus,
    String seatId,
    _SeatOccupants occ,
  ) {
    return UgamSheet.show<void>(
      context,
      title: tr('handler_chart.seat_shared_title', namedArgs: {'seat': seatId}),
      builder: (sheetCtx) => _LegSharedChooserSheet(
        seatId: seatId,
        go: occ.go,
        ret: occ.ret,
        onPick: (p) {
          Navigator.of(sheetCtx).pop();
          _showOccupantSheet(bus, seatId, p);
        },
      ),
    );
  }

  Future<void> _showOccupantSheet(Bus bus, String seatId, Passenger passenger) {
    final due = bus.amountDueForSeat(passenger, seatId);
    final existing = _collectionFor(passenger.id, bus.id, seatId);
    // Resolve the tour id from the bus first, falling back to the passenger;
    // both manifest models carry tourId.
    final tourId = (bus.tourId?.isNotEmpty == true)
        ? bus.tourId!
        : passenger.tourId;

    return UgamSheet.show<void>(
      context,
      title: tr('handler_chart.collect_title'),
      builder: (sheetCtx) => _CollectSheet(
        passenger: passenger,
        seatId: seatId,
        due: due,
        existing: existing,
        onSave: (received, returned, collectedBy, note) async {
          final base =
              existing ??
              Collection(
                tourId: tourId,
                busId: bus.id,
                passengerId: passenger.id,
                seatId: seatId,
              );
          final updated = base.copyWith(
            seatId: seatId,
            amountDue: due,
            amountReceived: received,
            amountRefunded: returned,
            collectedBy: collectedBy.isEmpty ? null : collectedBy,
            note: note.isEmpty ? null : note,
          );
          final saved = await _store.handlerUpsertCollection(
            widget.requestId,
            updated,
          );
          if (saved == null) {
            throw StateError('Handler collection save was rejected.');
          }
          if (!mounted) return;
          // Cache the server-returned row so ids/timestamps stay aligned with
          // the database after insert or conflict update.
          setState(() {
            _collections[_collectionKey(
                  saved.passengerId,
                  saved.busId,
                  saved.seatId,
                )] =
                saved;
          });
        },
      ),
    );
  }

  /// Opens the add/edit expense sheet for [bus]. Pass [existing] to edit a
  /// logged expense. On save the server-returned row is cached so the ledger
  /// and the "spent / in hand" summary refresh without a reload.
  Future<void> _showExpenseSheet(Bus bus, {Expense? existing}) {
    final tourId = bus.tourId?.isNotEmpty == true ? bus.tourId! : '';
    return UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('handler_chart.add_expense')
          : tr('handler_chart.edit_expense'),
      builder: (sheetCtx) => _ExpenseSheet(
        existing: existing,
        onSave: (category, label, amount, paidBy) async {
          final base =
              existing ?? Expense(tourId: tourId, busId: bus.id, label: label);
          final updated = base.copyWith(
            busId: bus.id,
            category: category,
            label: label,
            amount: amount,
            paidBy: paidBy.isEmpty ? null : paidBy,
          );
          final saved = await _store.handlerUpsertExpense(
            widget.requestId,
            updated,
          );
          if (saved == null) {
            throw StateError('Handler expense save was rejected.');
          }
          if (!mounted) return;
          setState(() => _expenses[saved.id] = saved);
        },
      ),
    );
  }

  /// Confirms then removes a logged expense, both on the server and in the
  /// local cache.
  Future<void> _deleteExpense(Expense expense) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('handler_chart.delete_expense_title'),
      message: expense.label.isEmpty
          ? tr(
              'handler_chart.delete_expense_msg_category',
              namedArgs: {
                'category': expense.category.displayName.toLowerCase(),
                'amount': Formatters.formatMoneyInr(expense.amount),
              },
            )
          : tr(
              'handler_chart.delete_expense_msg_label',
              namedArgs: {
                'label': expense.label,
                'amount': Formatters.formatMoneyInr(expense.amount),
              },
            ),
      confirmLabel: tr('app.action.delete'),
      destructive: true,
    );
    if (ok != true) return;
    try {
      final removed = await _store.handlerDeleteExpense(
        widget.requestId,
        expense.id,
      );
      if (!removed) {
        AppSnackBar.error(tr('handler_chart.error_delete_expense'));
        return;
      }
      if (!mounted) return;
      setState(() => _expenses.remove(expense.id));
    } catch (_) {
      AppSnackBar.error(tr('handler_chart.error_delete_expense'));
    }
  }

  /// HANDLER per-bus announcement (F4). Opens a composer for the CURRENTLY
  /// selected bus and sends the typed free-text to every seated passenger on
  /// that bus via the `bus-message` Edge Function (which re-verifies the caller
  /// is this bus's handler). The handler only ever sees their own bus(es), so
  /// the composer is always scoped to [bus] — no bus picker.
  Future<void> _openBusMessageComposer(Bus bus) async {
    await UgamSheet.show<void>(
      context,
      title: tr('bus_message.composer_title'),
      builder: (sheetCtx) => _HandlerBusMessageSheet(
        busLabel: bus.name,
        onSend: (text) async {
          final result = await WhatsAppCloudService().sendBusMessageAsHandler(
            requestId: widget.requestId,
            busId: bus.id,
            message: text,
          );
          if (!mounted) return;
          if (result.allSent) {
            AppSnackBar.success(
              tr('bus_message.sent_body', namedArgs: {'count': '${result.sent}'}),
              title: tr('bus_message.sent_title'),
            );
          } else if (result.anySent) {
            AppSnackBar.warning(
              tr('bus_message.partial_body', namedArgs: {
                'sent': '${result.sent}',
                'failed': '${result.failed}',
              }),
              title: tr('bus_message.partial_title'),
            );
          } else {
            AppSnackBar.error(tr('bus_message.failed_body'));
          }
        },
      ),
    );
  }

  /// Opens the shared full-screen chart for the currently-shown bus. Reuses the
  /// exact per-seat occupant data the grid's tileBuilder builds (the leg-aware
  /// `_SeatOccupants` map flattened to the `List<Passenger>` shape the
  /// full-screen view expects: a leg-shared seat → both occupants, otherwise the
  /// sole occupant, else empty). Only wired up in grid view with a real chart on
  /// screen (see [build]).
  void _openFullscreenChart(Bus bus) {
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) return;
    final occupantsBySeat = _occupantsBySeatForBus(_manifest!, bus.id);
    final occupantsForFullscreen = <String, List<Passenger>>{};
    for (final entry in occupantsBySeat.entries) {
      final occ = entry.value;
      occupantsForFullscreen[entry.key] = occ.isLegShared
          ? <Passenger>[occ.go!, occ.ret!]
          : (occ.sole != null ? <Passenger>[occ.sole!] : const <Passenger>[]);
    }
    FullscreenChartScreen.open(
      context,
      layout: layout,
      occupantsBySeat: occupantsForFullscreen,
      title: bus.name,
      driverLabel: tr('handler_chart.driver'),
      bandColorFor: (cell) {
        final idx = bus.bandIndexForRow(cell.row);
        return idx == null ? null : priceBandWash(idx);
      },
      emphasizeOneWay: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Show the expand affordance only when a real chart is on screen: grid view,
    // a current bus, and a non-empty layout. Otherwise the top bar omits it.
    final manifest = _manifest;
    final bus = manifest != null ? _selectedBus(manifest) : null;
    final canExpand =
        !_loading &&
        _error == null &&
        _viewMode == _ViewMode.grid &&
        bus != null &&
        (bus.layout?.totalCells ?? 0) > 0;
    // The handler can broadcast a free-text message to their bus as soon as a
    // bus is loaded (regardless of grid/list view).
    final canMessage = !_loading && _error == null && bus != null;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              title: tr('handler_chart.bus_chart'),
              c: c,
              onExpand: canExpand ? () => _openFullscreenChart(bus) : null,
              onMessage:
                  canMessage ? () => _openBusMessageComposer(bus) : null,
            ),
            Expanded(child: _body(c)),
          ],
        ),
      ),
    );
  }

  Widget _body(UgamColorSet c) {
    if (_loading) {
      return const _LoadingSkeleton();
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.cloud_off_rounded,
            title: tr('handler_chart.error_load_title'),
            body: _error!,
          ),
        ),
      );
    }
    final manifest = _manifest;
    if (manifest == null || manifest.buses.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.event_seat_outlined,
            title: tr('handler_chart.no_bus_chart_title'),
            body: tr('handler_chart.no_bus_chart_body'),
          ),
        ),
      );
    }

    final bus = _selectedBus(manifest)!;
    final multiBus = manifest.buses.length > 1;
    final summary = _summaryForBus(manifest, bus);

    // Resolve occupants for the whole bus once, not per seat cell.
    final occupantsBySeat = _occupantsBySeatForBus(manifest, bus.id);

    final grid = _viewMode == _ViewMode.grid;

    return Column(
      children: [
        if (multiBus)
          _BusPills(
            buses: manifest.buses,
            selectedBusId: bus.id,
            onTapBus: (id) => setState(() => _selectedBusId = id),
            c: c,
          ),
        if (multiBus) const SizedBox(height: UgamSpacing.md),
        Padding(
          padding: EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            multiBus ? 0 : UgamSpacing.md,
            UgamSpacing.gutter,
            UgamSpacing.sm,
          ),
          child: UgamTabPills(
            items: [
              UgamTabItem(
                label: tr('handler_chart.view_list'),
                icon: Icons.format_list_bulleted_rounded,
              ),
              UgamTabItem(
                label: tr('handler_chart.view_grid'),
                icon: Icons.grid_view_rounded,
              ),
            ],
            currentIndex: _viewMode == _ViewMode.list ? 0 : 1,
            onChanged: (i) => setState(
              () => _viewMode = i == 0 ? _ViewMode.list : _ViewMode.grid,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              0,
              UgamSpacing.gutter,
              UgamSpacing.xl,
            ),
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                _BusDeparture(bus: bus, c: c),
                _SummaryHeader(
                  collected: summary.collected,
                  toReturn: summary.toReturn,
                  toCollect: summary.toCollect,
                  spent: summary.spent,
                  inHand: summary.inHand,
                ),
                const SizedBox(height: UgamSpacing.lg),
                if (grid) ...[
                  _SeatGrid(
                    bus: bus,
                    occupantsBySeat: occupantsBySeat,
                    collectionFor: (pId, seatId) =>
                        _collectionFor(pId, bus.id, seatId),
                    onTapOccupant: (seatId, p) => _onSeatTapped(bus, seatId, p),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  _Legend(c: c),
                ] else
                  _SeatRoster(
                    bus: bus,
                    occupantsBySeat: occupantsBySeat,
                    collectionFor: (pId, seatId) =>
                        _collectionFor(pId, bus.id, seatId),
                    onTapOccupant: (seatId, p) => _onSeatTapped(bus, seatId, p),
                  ),
                _PriceBandKey(bus: bus),
                const SizedBox(height: UgamSpacing.xl),
                _ExpensesSection(
                  busName: bus.name,
                  expenses: _expensesForBus(bus.id),
                  onAdd: () => _showExpenseSheet(bus),
                  onEdit: (e) => _showExpenseSheet(bus, existing: e),
                  onDelete: (e) => _deleteExpense(e),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: MediaQuery.of(context).padding.bottom + UgamSpacing.xs,
        ),
      ],
    );
  }
}

// ─── Loading skeleton ──────────────────────────────────────────────────

/// The initial-load placeholder for the chart body: the view toggle, the
/// money-summary tiles, and the roster card mocked as shimmering blocks so
/// the layout reads while the manifest fetches (replaces the bare spinner).
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const UgamSkeleton(height: 44, radius: UgamRadius.input),
          const SizedBox(height: UgamSpacing.lg),
          const UgamSkeleton.text(width: 140),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: const [
              Expanded(child: UgamSkeleton(height: 76, radius: UgamRadius.card)),
              SizedBox(width: UgamSpacing.md),
              Expanded(child: UgamSkeleton(height: 76, radius: UgamRadius.card)),
              SizedBox(width: UgamSpacing.md),
              Expanded(child: UgamSkeleton(height: 76, radius: UgamRadius.card)),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          for (var i = 0; i < 4; i++) ...[
            const UgamSkeleton.row(),
            const SizedBox(height: UgamSpacing.sm),
          ],
        ],
      ),
    );
  }
}

// ─── Top bar ───────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title;
  final UgamColorSet c;

  /// When non-null, shows an "expand to full screen chart" button that opens the
  /// shared [FullscreenChartScreen]. Null hides it (e.g. list view, or no real
  /// chart on screen).
  final VoidCallback? onExpand;

  /// When non-null, shows a "Message this bus" button that opens the per-bus
  /// announcement composer (F4 handler path). Null hides it (e.g. still loading
  /// or no bus resolved).
  final VoidCallback? onMessage;

  const _TopBar({
    required this.title,
    required this.c,
    this.onExpand,
    this.onMessage,
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
      child: Row(
        children: [
          UgamIconButton(
            icon: Icons.arrow_back_rounded,
            onTap: () => Get.back(),
            semanticLabel: tr('app.action.back'),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              title,
              style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onMessage != null) ...[
            UgamIconButton(
              icon: Icons.campaign_rounded,
              onTap: onMessage,
              semanticLabel: tr('bus_message.message_bus'),
            ),
            const SizedBox(width: UgamSpacing.sm),
          ],
          if (onExpand != null) ...[
            UgamIconButton(
              icon: Icons.open_in_full_rounded,
              onTap: onExpand,
              semanticLabel: tr('handler_chart.expand_chart'),
            ),
            const SizedBox(width: UgamSpacing.sm),
          ],
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.directions_bus_filled_rounded,
              size: 19,
              color: c.ink,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bus pills ─────────────────────────────────────────────────────────

class _BusPills extends StatelessWidget {
  final List<Bus> buses;
  final String selectedBusId;
  final ValueChanged<String> onTapBus;
  final UgamColorSet c;

  const _BusPills({
    required this.buses,
    required this.selectedBusId,
    required this.onTapBus,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
        itemCount: buses.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (ctx, i) {
          final bus = buses[i];
          final selected = bus.id == selectedBusId;
          return GestureDetector(
            onTap: () => onTapBus(bus.id),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selected ? c.accent : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              alignment: Alignment.center,
              child: Text(
                bus.name,
                style: UgamText.bodyStrong.copyWith(
                  color: selected ? c.onAccent : c.ink,
                  fontSize: 12,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Group colour ──────────────────────────────────────────────────────

// Group ring colours come from the shared `groupColorForId` util
// (lib/design/group_color.dart) — an infinite, golden-angle hue generator that
// never collides with the warm priority ring or the one-way tint. The old
// copied 6-hue `_GroupPalette` was deleted so the handler reads exactly the
// same colour the agent seat-detail screen shows for a given group.

/// The per-seat collection state, derived from the manifest's collection row
/// (if any) against what the seat owes. Drives a small corner indicator on the
/// occupied tile so the handler reads paid / owing / return-due at a glance —
/// the agent seat-detail tile has no money state, so this is the handler's
/// extra layer over the SAME tile look.
enum _MoneyState { uncollected, paid, owing, returnDue }

extension _MoneyStateView on _MoneyState {
  /// The dot colour for this money state. `uncollected` reads as a neutral
  /// hairline so it never competes with the group/priority ring.
  Color color(UgamColorSet c) {
    switch (this) {
      case _MoneyState.paid:
        return c.good;
      case _MoneyState.owing:
        return c.danger;
      case _MoneyState.returnDue:
        return c.warm;
      case _MoneyState.uncollected:
        return c.ink3;
    }
  }
}

// ─── Seat grid card ────────────────────────────────────────────────────

class _SeatGrid extends StatelessWidget {
  final Bus bus;
  final Map<String, _SeatOccupants> occupantsBySeat;
  final Collection? Function(String passengerId, String seatId) collectionFor;
  final void Function(String seatId, Passenger passenger) onTapOccupant;

  const _SeatGrid({
    required this.bus,
    required this.occupantsBySeat,
    required this.collectionFor,
    required this.onTapOccupant,
  });

  /// The collection state for an occupied seat, mirroring collection_screen's
  /// _PassengerRow chip logic: return-due (warm) wins, then a shortfall is
  /// owing (danger), then a squared-off collection with cash in is paid (good),
  /// otherwise nothing has been collected yet.
  _MoneyState _moneyState(Passenger passenger, String seatId) {
    final due = bus.amountDueForSeat(passenger, seatId);
    final col = collectionFor(passenger.id, seatId);
    if (col == null) return due > 0 ? _MoneyState.owing : _MoneyState.uncollected;
    if (col.isReturnDue) return _MoneyState.returnDue;
    if (col.balance < 0) return _MoneyState.owing;
    if (col.isSquare && col.amountReceived > 0) return _MoneyState.paid;
    return _MoneyState.uncollected;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
        alignment: Alignment.center,
        child: Text(
          tr('handler_chart.no_seat_layout'),
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: CombinedSeatGrid(
        layout: layout,
        cellWidth: kSeatTileW,
        cellHeight: kSeatTileH,
        colGap: 8,
        rowGap: 8,
        driverLabel: tr('handler_chart.driver'),
        tileBuilder: (ctx, cell) {
          // Leg-aware: a seat may hold a GO occupant and a DIFFERENT RETURN
          // occupant (an outbound-only + a return-only sharing the seat on
          // disjoint legs). Resolve both so the shared tile can split + badge
          // them. The canonical tile detects the GO/RET split itself by trip
          // type, so we just hand it the occupant list.
          final occ = cell.seatId == null
              ? const _SeatOccupants()
              : (occupantsBySeat[cell.seatId!] ?? const _SeatOccupants());
          final List<Passenger> occList = occ.isLegShared
              ? <Passenger>[occ.go!, occ.ret!]
              : (occ.sole != null
                  ? <Passenger>[occ.sole!]
                  : const <Passenger>[]);
          // The money dot follows the GO occupant first (then RETURN) — the
          // primary person whose due/collection drives the at-a-glance state.
          final primary = occ.go ?? occ.ret;
          final money = primary == null
              ? _MoneyState.uncollected
              : _moneyState(primary, cell.seatId!);
          // Price-band wash for this seat's row, so the rows read as price
          // stripes (booked AND free seats). Null when the row is unbanded.
          final bandIdx = bus.bandIndexForRow(cell.row);
          final bandColor = bandIdx == null ? null : priceBandWash(bandIdx);
          return SizedBox(
            width: kSeatTileW,
            height: kSeatTileH,
            child: RepaintBoundary(
              child: SeatChartTile(
                cell: cell,
                occupants: occList,
                // Handler is customer-side with no PassengerGroup colour index;
                // the empty resolver falls back to stable id-hash colours.
                groupColors: const GroupColorResolver({}),
                bandColor: bandColor,
                // Handler view: RET reads violet (distinct from GO cyan) and
                // one-way pills show "½" — the cue that this seat pays half fare.
                emphasizeOneWay: true,
                moneyDotColor: primary == null ? null : money.color(UgamColors.of(ctx)),
                onTapBooked: primary == null
                    ? null
                    : () => onTapOccupant(cell.seatId!, primary),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A small filled circle used for group / money badges on a seat tile.
class _Dot extends StatelessWidget {
  final Color color;
  final double size;

  const _Dot({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Paints a dashed rounded-rectangle border for the FREE tile. Kept local so
/// the free look stays distinct from the solid-bordered booked/held tiles —
/// mirrors the agent seat-detail screen's free-tile border.
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

/// Reads the chart for the handler: the seat-state swatches (matching the
/// agent seat-detail legend) plus the handler-only money dots.
class _Legend extends StatelessWidget {
  final UgamColorSet c;
  const _Legend({required this.c});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: UgamSpacing.md,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        _LegendItem(
          swatch: _LegendSwatch.dashed,
          label: tr('handler_chart.legend_free'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.filled,
          label: tr('handler_chart.legend_booked'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.warmRing,
          label: tr('handler_chart.legend_priority'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.held,
          label: tr('handler_chart.legend_held'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.go,
          label: tr('handler_chart.legend_go'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.ret,
          label: tr('handler_chart.legend_ret'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.halfFare,
          label: tr('handler_chart.legend_half'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.paidDot,
          label: tr('handler_chart.legend_paid'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.owingDot,
          label: tr('handler_chart.legend_owing'),
          c: c,
        ),
      ],
    );
  }
}

enum _LegendSwatch {
  dashed,
  filled,
  warmRing,
  held,
  go,
  ret,
  halfFare,
  paidDot,
  owingDot,
}

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
      case _LegendSwatch.go:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kOneWayTint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kOneWayTint, width: 1.6),
          ),
        );
      case _LegendSwatch.ret:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kReturnTint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kReturnTint, width: 1.6),
          ),
        );
      case _LegendSwatch.halfFare:
        dot = Container(
          width: 16,
          height: 12,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.ink3.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.ink3.withValues(alpha: 0.6), width: 0.8),
          ),
          child: Text(
            '½',
            style: UgamText.micro.copyWith(
              color: c.ink2,
              fontSize: 8,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
      case _LegendSwatch.paidDot:
        dot = _Dot(color: c.good, size: 12);
      case _LegendSwatch.owingDot:
        dot = _Dot(color: c.danger, size: 12);
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

// ─── Price-band key ────────────────────────────────────────────────────

/// The price-band legend: one row per effective band (precedence order) showing
/// the band's colour swatch — the SAME colour the grid washes that band's rows
/// with — its label, its row range, and its per-person price. Hidden entirely
/// when the bus has no bands configured. Each band's colour is keyed on its
/// index so the swatch and the row wash always agree (see `priceBandColor`).
class _PriceBandKey extends StatelessWidget {
  final Bus bus;

  const _PriceBandKey({required this.bus});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final bands = bus.effectiveBands;
    if (bands.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.lg),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sell_outlined, size: 16, color: c.ink2),
                const SizedBox(width: 6),
                Text(
                  tr('handler_chart.price_bands'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            for (var i = 0; i < bands.length; i++) ...[
              if (i > 0) const SizedBox(height: UgamSpacing.sm),
              _PriceBandRow(band: bands[i], color: priceBandColor(i), c: c),
            ],
          ],
        ),
      ),
    );
  }
}

/// One band line in the price-band key: colour swatch, label + row range, price.
class _PriceBandRow extends StatelessWidget {
  final PriceBand band;
  final Color color;
  final UgamColorSet c;

  const _PriceBandRow({
    required this.band,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // Normalise a band entered "backwards" and show 1-based, human row numbers.
    final lo = (band.fromRow <= band.toRow ? band.fromRow : band.toRow) + 1;
    final hi = (band.fromRow <= band.toRow ? band.toRow : band.fromRow) + 1;
    final raw = band.label.trim();
    // The legacy rear-zone band is synthesized with the hard-coded English
    // sentinel 'Rear' (see Bus.effectiveBands); localize it at render so the key
    // reads in the active language. Empty user labels fall back to band_unnamed.
    final label = raw.isEmpty
        ? tr('handler_chart.band_unnamed')
        : (raw == 'Rear' ? tr('handler_chart.band_rear') : raw);
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: UgamText.bodyStrong.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                lo == hi
                    ? tr('handler_chart.band_row', namedArgs: {'row': '$lo'})
                    : tr(
                        'handler_chart.band_rows',
                        namedArgs: {'from': '$lo', 'to': '$hi'},
                      ),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ],
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Text(
          tr('handler_chart.band_per_person', namedArgs: {'amount': Formatters.formatMoneyInr(band.price)}),
          style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}

// ─── Seat roster (List view) ────────────────────────────────────────────

/// The call-first roster: one row per booked berth in seat order, showing the
/// seat id, the occupant's FULL name + mobile (tap to call), a trip badge
/// (round-trip / GO / RET), a group dot, and the per-seat collection status.
/// A leg-shared seat emits TWO rows (the GO occupant and the RETURN occupant).
/// Read-only + collect: tapping the row (or the money chip) opens the same
/// collect sheet the grid uses.
class _SeatRoster extends StatelessWidget {
  final Bus bus;
  final Map<String, _SeatOccupants> occupantsBySeat;
  final Collection? Function(String passengerId, String seatId) collectionFor;
  final void Function(String seatId, Passenger passenger) onTapOccupant;

  const _SeatRoster({
    required this.bus,
    required this.occupantsBySeat,
    required this.collectionFor,
    required this.onTapOccupant,
  });

  _MoneyState _moneyState(Passenger passenger, String seatId) {
    final due = bus.amountDueForSeat(passenger, seatId);
    final col = collectionFor(passenger.id, seatId);
    if (col == null) {
      return due > 0 ? _MoneyState.owing : _MoneyState.uncollected;
    }
    if (col.isReturnDue) return _MoneyState.returnDue;
    if (col.balance < 0) return _MoneyState.owing;
    if (col.isSquare && col.amountReceived > 0) return _MoneyState.paid;
    return _MoneyState.uncollected;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
        alignment: Alignment.center,
        child: Text(
          tr('handler_chart.no_seat_layout'),
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    // Walk every seat cell in placement order; emit a row per distinct
    // occupant. `grid` is the flat seat list (only [hasSeat] cells stored).
    final rows = <Widget>[];
    for (final cell in layout.grid) {
      final seatId = cell.seatId;
      if (seatId == null) continue;
      final occ = occupantsBySeat[seatId] ?? const _SeatOccupants();
      if (occ.isEmpty) continue;
      for (final p in occ.all) {
        rows.add(
          _RosterRow(
            seatId: seatId,
            passenger: p,
            money: _moneyState(p, seatId),
            onTap: () => onTapOccupant(seatId, p),
            c: c,
          ),
        );
      }
    }

    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
        alignment: Alignment.center,
        child: Text(
          tr('handler_chart.no_passengers_on_bus', namedArgs: {'bus': bus.name}),
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
      child: Column(children: rows),
    );
  }
}

/// One roster line: seat id chip, full name + mobile + group dot + trip badge,
/// and a tap-to-call action plus the collection-status chip.
class _RosterRow extends StatelessWidget {
  final String seatId;
  final Passenger passenger;
  final _MoneyState money;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _RosterRow({
    required this.seatId,
    required this.passenger,
    required this.money,
    required this.onTap,
    required this.c,
  });

  String get _moneyLabel {
    switch (money) {
      case _MoneyState.paid:
        return tr('handler_chart.money_paid');
      case _MoneyState.owing:
        return tr('handler_chart.money_owing');
      case _MoneyState.returnDue:
        return tr('handler_chart.money_return_due');
      case _MoneyState.uncollected:
        return tr('handler_chart.money_not_collected');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColorForId(p.groupId!) : null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        child: Row(
          children: [
            // Seat id chip.
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
                border: Border.all(color: c.border),
              ),
              child: Text(
                seatId,
                style: UgamText.tabular(
                  UgamText.caption.copyWith(
                    color: c.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            // Name + mobile + badges.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.displayName,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (groupColor != null) ...[
                        const SizedBox(width: 6),
                        _Dot(color: groupColor, size: 8),
                      ],
                      const SizedBox(width: 6),
                      _TripBadge(tripType: p.tripType, c: c),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasPhone ? p.phone : tr('handler_chart.no_mobile'),
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(
                        color: hasPhone ? c.ink2 : c.ink3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _Dot(color: money.color(c), size: 7),
                      const SizedBox(width: 5),
                      Text(
                        _moneyLabel,
                        style: UgamText.micro.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Tap-to-call.
            if (hasPhone) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: tr('handler_chart.call_semantic', namedArgs: {'phone': p.phone}),
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
                    child: Icon(Icons.call_rounded, size: 17, color: c.accent),
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

/// A small trip-type pill. Round-trip is muted (the common case); a one-way leg
/// uses its leg tint — GO cyan [kOneWayTint], RET violet [kReturnTint] — with a
/// "½" half-fare marker so the roster matches the grid's leg badge and the
/// handler sees who pays a different amount.
class _TripBadge extends StatelessWidget {
  final TripType tripType;
  final UgamColorSet c;

  const _TripBadge({required this.tripType, required this.c});

  @override
  Widget build(BuildContext context) {
    final oneWay = tripType.isOneWay;
    final isRet = tripType.usesReturn && !tripType.usesOutbound;
    final tint = isRet ? kReturnTint : kOneWayTint;
    final base = !oneWay
        ? tr('handler_chart.badge_round_trip')
        : (isRet ? tr('handler_chart.badge_ret') : tr('handler_chart.badge_go'));
    final label = oneWay
        ? tr('handler_chart.badge_half_suffix', namedArgs: {'leg': base})
        : base;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: oneWay ? tint : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        border: oneWay ? null : Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: UgamText.micro.copyWith(
          // Dark ground on the bright leg tint; muted ink on the neutral pill.
          color: oneWay ? c.bg : c.ink2,
          fontSize: 8,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ─── Leg-shared chooser sheet ───────────────────────────────────────────

/// A chooser for a leg-shared seat: lists the GO occupant and the RETURN
/// occupant, each with phone + a Call button, so the handler picks whom to
/// collect from / call before the collect sheet opens.
class _LegSharedChooserSheet extends StatelessWidget {
  final String seatId;
  final Passenger? go;
  final Passenger? ret;
  final ValueChanged<Passenger> onPick;

  const _LegSharedChooserSheet({
    required this.seatId,
    required this.go,
    required this.ret,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('handler_chart.leg_shared_intro'),
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (go != null)
          _LegSharedTile(
            passenger: go!,
            leg: TripType.outboundOnly,
            onPick: () => onPick(go!),
            c: c,
          ),
        if (go != null && ret != null) const SizedBox(height: UgamSpacing.sm),
        if (ret != null)
          _LegSharedTile(
            passenger: ret!,
            leg: TripType.returnOnly,
            onPick: () => onPick(ret!),
            c: c,
          ),
      ],
    );
  }
}

class _LegSharedTile extends StatelessWidget {
  final Passenger passenger;
  final TripType leg;
  final VoidCallback onPick;
  final UgamColorSet c;

  const _LegSharedTile({
    required this.passenger,
    required this.leg,
    required this.onPick,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    return GestureDetector(
      onTap: onPick,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            _TripBadge(tripType: leg, c: c),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.displayName,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasPhone ? p.phone : tr('handler_chart.no_mobile'),
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(
                        color: hasPhone ? c.ink2 : c.ink3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (hasPhone) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: tr('handler_chart.call_semantic', namedArgs: {'phone': p.phone}),
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
                    child: Icon(Icons.call_rounded, size: 17, color: c.accent),
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

// ─── Bus departure header ──────────────────────────────────────────────

/// The selected bus's name plus its OWN departure: place + time, rendered as
/// `<boardingPoint> · <formatHhMm(departureTime)>` per the surfacing rule —
/// either half is omitted when empty/null, and the departure line is hidden
/// entirely when both are empty (the per-bus values override the tour-level /
/// chart-footer departure). Sits above the money summary so the handler reads
/// where and when THIS bus leaves at a glance.
class _BusDeparture extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;

  const _BusDeparture({required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    final place = bus.boardingPoint.trim();
    final time = formatHhMm(bus.departureTime);
    final parts = <String>[
      if (place.isNotEmpty) place,
      if (time != null && time.isNotEmpty) time,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            bus.name,
            style: UgamText.titleS.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (parts.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(Icons.place_outlined, size: 14, color: c.ink2),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    parts.join(' · '),
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Summary header ────────────────────────────────────────────────────

/// Aggregated collection figures for the selected bus.
class _BusSummary {
  final double collected;
  final double toReturn;
  final double toCollect;

  /// Total of every expense logged against this bus.
  final double spent;

  const _BusSummary({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
  });

  /// Net cash the handler should be holding for this bus — what was collected
  /// less what was spent. This is what they hand over to the admin.
  double get inHand => collected - spent;
}

class _SummaryHeader extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;
  final double spent;
  final double inHand;

  const _SummaryHeader({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.inHand,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.payments_rounded,
                value: Formatters.formatMoneyInr(collected),
                label: tr('handler_chart.stat_collected'),
                variant: UgamStatVariant.good,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.undo_rounded,
                value: Formatters.formatMoneyInr(toReturn),
                label: tr('handler_chart.stat_to_return'),
                variant: UgamStatVariant.warm,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.account_balance_wallet_rounded,
                value: Formatters.formatMoneyInr(toCollect),
                label: tr('handler_chart.stat_to_collect'),
                variant: UgamStatVariant.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.receipt_long_rounded,
                value: Formatters.formatMoneyInr(spent),
                label: tr('handler_chart.stat_spent'),
                variant: UgamStatVariant.warm,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.account_balance_rounded,
                value: Formatters.formatMoneyInr(inHand),
                label: tr('handler_chart.stat_in_hand'),
                variant: UgamStatVariant.neutral,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Collect sheet ─────────────────────────────────────────────────────

/// Per-passenger collect form, mirroring collection_screen._openCollectSheet.
/// Keeps the call header (name + handler chip + age + phone + Call) and adds
/// the money form below. [onSave] persists the collection and updates the
/// chart; this widget owns the field controllers and pops on success.
class _CollectSheet extends StatefulWidget {
  final Passenger passenger;
  final String seatId;
  final double due;
  final Collection? existing;
  final Future<void> Function(
    double received,
    double returned,
    String collectedBy,
    String note,
  )
  onSave;

  const _CollectSheet({
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.existing,
    required this.onSave,
  });

  @override
  State<_CollectSheet> createState() => _CollectSheetState();
}

class _CollectSheetState extends State<_CollectSheet> {
  late final TextEditingController _receivedCtrl;
  late final TextEditingController _returnedCtrl;
  late final TextEditingController _collectedByCtrl;
  late final TextEditingController _noteCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final col = widget.existing;
    _receivedCtrl = TextEditingController(
      text: (col?.amountReceived ?? 0) == 0
          ? ''
          : col!.amountReceived.toStringAsFixed(0),
    );
    _returnedCtrl = TextEditingController(
      text: (col?.amountRefunded ?? 0) == 0
          ? ''
          : col!.amountRefunded.toStringAsFixed(0),
    );
    _collectedByCtrl = TextEditingController(text: col?.collectedBy ?? '');
    _noteCtrl = TextEditingController(text: col?.note ?? '');
  }

  @override
  void dispose() {
    _receivedCtrl.dispose();
    _returnedCtrl.dispose();
    _collectedByCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double _parse(TextEditingController ctl) =>
      double.tryParse(ctl.text.trim()) ?? 0;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _parse(_receivedCtrl),
        _parse(_returnedCtrl),
        _collectedByCtrl.text.trim(),
        _noteCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr('handler_chart.error_save_collection'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = widget.passenger;
    final hasPhone = passenger.phone.trim().isNotEmpty;
    final due = widget.due;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: avatar, name, handler chip, age group ──
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  passenger.name.trim().isNotEmpty
                      ? passenger.name.trim()[0].toUpperCase()
                      : '?',
                  style: UgamText.titleL.copyWith(color: c.accent),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            passenger.name.trim().isNotEmpty
                                ? passenger.name
                                : tr('handler_chart.passenger_fallback'),
                            style: UgamText.titleL.copyWith(color: c.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (passenger.isHandler) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: c.warmFill,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              tr('handler_chart.handler_badge'),
                              style: UgamText.micro.copyWith(
                                color: c.warm,
                                fontSize: 9,
                                letterSpacing: 0.6,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      passenger.ageGroup.displayName,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Phone + Call ──
          Container(
            padding: const EdgeInsets.all(UgamSpacing.md),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.phone_outlined, size: 18, color: c.ink2),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    hasPhone ? passenger.phone : tr('handler_chart.no_phone'),
                    style: UgamText.body.copyWith(
                      color: hasPhone ? c.ink : c.ink3,
                    ),
                  ),
                ),
                if (hasPhone)
                  UgamButton(
                    label: tr('handler_chart.call'),
                    icon: Icons.call_rounded,
                    kind: UgamButtonKind.tonal,
                    onPressed: () => PhoneDialer.call(passenger.phone),
                  ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Collect form ──
          _ReadOnlyLine(label: tr('handler_chart.seat'), value: widget.seatId),
          const SizedBox(height: UgamSpacing.sm),
          _ReadOnlyLine(
            label: tr('handler_chart.amount_due'),
            value: Formatters.formatMoneyInr(due),
          ),
          // One-way leg → the due above is already HALVED. Spell that out so the
          // handler knows the amount differs from a full round-trip seat.
          if (passenger.tripType.isOneWay) ...[
            const SizedBox(height: UgamSpacing.sm),
            Builder(
              builder: (_) {
                final isRet = passenger.tripType.usesReturn &&
                    !passenger.tripType.usesOutbound;
                final tint = isRet ? kReturnTint : kOneWayTint;
                return Row(
                  children: [
                    SeatLegPill(
                      label: isRet
                          ? tr('handler_chart.badge_ret')
                          : tr('handler_chart.badge_go'),
                      tint: tint,
                      half: true,
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        tr('handler_chart.half_fare_note'),
                        style: UgamText.micro.copyWith(color: c.ink2),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('handler_chart.field_received'),
            controller: _receivedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.field_returned'),
            controller: _returnedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.field_collected_by'),
            controller: _collectedByCtrl,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.field_note'),
            controller: _noteCtrl,
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Live balance pill ──
          Builder(
            builder: (_) {
              final balance =
                  _parse(_receivedCtrl) - _parse(_returnedCtrl) - due;
              final (String balLabel, Color balColor) = balance > 0
                  ? (
                      tr(
                        'handler_chart.balance_change',
                        namedArgs: {'amount': Formatters.formatMoneyInr(balance)},
                      ),
                      c.warm,
                    )
                  : balance < 0
                  ? (
                      tr(
                        'handler_chart.balance_still_to_collect',
                        namedArgs: {'amount': Formatters.formatMoneyInr(-balance)},
                      ),
                      c.danger,
                    )
                  : (tr('handler_chart.balance_settled'), c.good);
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.lg,
                  vertical: UgamSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: balColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                ),
                child: Text(
                  balLabel,
                  style: UgamText.bodyStrong.copyWith(color: balColor),
                ),
              );
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('handler_chart.saving')
                : tr('app.action.save'),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyLine extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: UgamText.body.copyWith(color: c.ink2)),
        Text(
          value,
          style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}

// ─── Expenses section ──────────────────────────────────────────────────

/// The handler's per-bus expense ledger: a header with the running total + an
/// Add action, then one tappable row per logged expense (tap to edit, trash to
/// delete). Mirrors the agent's BusMoneyScreen expense list, scoped to the bus
/// the handler is currently viewing so they can log fuel / tolls / food on the
/// ground and keep the bus's cash reconciled.
class _ExpensesSection extends StatelessWidget {
  final String busName;
  final List<Expense> expenses;
  final VoidCallback onAdd;
  final ValueChanged<Expense> onEdit;
  final ValueChanged<Expense> onDelete;

  const _ExpensesSection({
    required this.busName,
    required this.expenses,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final total = expenses.fold<double>(0, (sum, e) => sum + e.amount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('handler_chart.bus_expenses'),
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  if (expenses.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr(
                        'handler_chart.bus_expenses_total',
                        namedArgs: {
                          'bus': busName,
                          'amount': Formatters.formatMoneyInr(total),
                        },
                      ),
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            Semantics(
              button: true,
              label: tr('handler_chart.add_expense'),
              child: GestureDetector(
                onTap: onAdd,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, size: 15, color: c.accent),
                      const SizedBox(width: 4),
                      Text(
                        tr('app.action.add'),
                        style: UgamText.caption.copyWith(
                          color: c.accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        if (expenses.isEmpty)
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(
              vertical: UgamSpacing.lg,
              horizontal: UgamSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 18, color: c.ink3),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('handler_chart.no_expenses'),
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ),
              ],
            ),
          )
        else
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
            child: Column(
              children: [
                for (final e in expenses)
                  _HandlerExpenseRow(
                    expense: e,
                    onTap: () => onEdit(e),
                    onDelete: () => onDelete(e),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One expense line: category chip, label (+ "paid by"), amount, and a delete
/// affordance. The whole row taps through to edit.
class _HandlerExpenseRow extends StatelessWidget {
  final Expense expense;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HandlerExpenseRow({
    required this.expense,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final paidBy = (expense.paidBy ?? '').trim();
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Text(
                expense.category.displayName,
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    expense.label.isEmpty
                        ? expense.category.displayName
                        : expense.label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (paidBy.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr('handler_chart.paid_by', namedArgs: {'name': paidBy}),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(expense.amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: tr('handler_chart.delete_expense'),
              child: GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: _DeleteGlyph(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteGlyph extends StatelessWidget {
  const _DeleteGlyph();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Icon(Icons.delete_outline_rounded, size: 18, color: c.ink3);
  }
}

// ─── Expense sheet ─────────────────────────────────────────────────────

/// Add / edit one bus expense. Category chips + label + amount + "paid by",
/// mirroring the agent's BusMoneyScreen expense form. [onSave] persists via the
/// handler RPC and updates the ledger; this widget owns the controllers and
/// pops on success.
class _ExpenseSheet extends StatefulWidget {
  final Expense? existing;
  final Future<void> Function(
    ExpenseCategory category,
    String label,
    double amount,
    String paidBy,
  )
  onSave;

  const _ExpenseSheet({required this.existing, required this.onSave});

  @override
  State<_ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends State<_ExpenseSheet> {
  late ExpenseCategory _category;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _paidByCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _category = e?.category ?? ExpenseCategory.fuel;
    _labelCtrl = TextEditingController(text: e?.label ?? '');
    _amountCtrl = TextEditingController(
      text: (e?.amount ?? 0) == 0 ? '' : e!.amount.toStringAsFixed(0),
    );
    _paidByCtrl = TextEditingController(text: e?.paidBy ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    _paidByCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      AppSnackBar.error(tr('handler_chart.error_amount_zero'));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _category,
        _labelCtrl.text.trim(),
        amount,
        _paidByCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr('handler_chart.error_save_expense'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('handler_chart.category'),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Wrap(
            spacing: UgamSpacing.sm,
            runSpacing: UgamSpacing.sm,
            // busOwner is excluded: the bus rent is the single source
            // of truth (Bus.busPrice) and must never be added manually,
            // or it would be double-counted.
            children: ExpenseCategory.values
                .where((cat) => cat != ExpenseCategory.busOwner)
                .map((cat) {
              final active = cat == _category;
              return GestureDetector(
                onTap: () => setState(() => _category = cat),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.lg,
                    vertical: UgamSpacing.sm + 2,
                  ),
                  decoration: BoxDecoration(
                    color: active ? c.accentFill : c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(color: active ? c.accent : c.border),
                  ),
                  child: Text(
                    cat.displayName,
                    style: UgamText.caption.copyWith(
                      color: active ? c.accent : c.ink2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('handler_chart.field_what_for'),
            controller: _labelCtrl,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.field_amount'),
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.field_paid_by'),
            controller: _paidByCtrl,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('handler_chart.saving')
                : tr('handler_chart.save_expense'),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

// ─── Handler bus-message sheet (F4 handler path) ────────────────────────

/// The handler's per-bus announcement composer: a single free-text field
/// scoped to the handler's own [busLabel] (no bus picker — a handler only
/// owns/sees their own bus). On Send it routes the text to every seated
/// passenger on that bus via [onSend] (WhatsAppCloudService.sendBusMessageAsHandler)
/// and pops on success.
class _HandlerBusMessageSheet extends StatefulWidget {
  final String busLabel;
  final Future<void> Function(String text) onSend;

  const _HandlerBusMessageSheet({required this.busLabel, required this.onSend});

  @override
  State<_HandlerBusMessageSheet> createState() =>
      _HandlerBusMessageSheetState();
}

class _HandlerBusMessageSheetState extends State<_HandlerBusMessageSheet> {
  final TextEditingController _textCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      AppSnackBar.error(tr('bus_message.empty_text'));
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      AppSnackBar.error(tr('bus_message.failed_body'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('bus_message.handler_intro', namedArgs: {'bus': widget.busLabel}),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('bus_message.field_message'),
            controller: _textCtrl,
            hint: tr('bus_message.field_message_hint'),
            maxLines: 5,
            minLines: 3,
            autofocus: true,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _sending
                ? tr('bus_message.sending')
                : tr('bus_message.send_btn'),
            leadingIcon: Icons.send_rounded,
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
  }
}
