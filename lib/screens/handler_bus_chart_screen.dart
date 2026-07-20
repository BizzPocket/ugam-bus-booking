import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../components/bus_message_composer_field.dart';
import '../components/combined_seat_grid.dart';
import '../components/pickup_grouped_list.dart';
import '../components/seat_chart_tile.dart';
import '../design/group_color.dart';
import '../design/price_band_color.dart';
import '../design/ugam.dart';
import '../models/attendance.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/expense.dart';
import '../models/handler_bus_money.dart';
import '../models/handler_manifest.dart';
import '../models/income_entry.dart';
import '../models/passenger.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../services/whatsapp_cloud_service.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/pickup_grouping.dart';
import '../utils/seat_money_state.dart';
import '../utils/seat_occupants.dart';
import '../utils/time_format.dart';
import 'fullscreen_chart_screen.dart';

/// The ways the handler reads the chart: the visual seat [grid], the
/// call-first [list] (a roster of full name + mobile per seat), or the
/// [attendance] boarding tally (who's present / left behind per leg).
enum _ViewMode { grid, list, attendance }

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

  /// Local, mutable income cache keyed by income id. Seeded from the manifest
  /// and updated in-place after each add / delete so the per-bus income ledger
  /// and the "income / in hand" summary refresh without a full reload.
  final Map<String, IncomeEntry> _income = {};

  /// Local, mutable attendance cache keyed by '"$passengerId|$busId|$leg"'.
  /// Seeded from the manifest once loaded; updated in-place after each toggle
  /// so the boarding tally refreshes without a full reload.
  final Map<String, Attendance> _attendance = {};

  /// Which leg the attendance view is currently showing (GO vs RETURN).
  AttendanceLeg _attLeg = AttendanceLeg.go;

  String _collectionKey(String passengerId, String busId, String seatId) =>
      '$passengerId|$busId|$seatId';

  String _attKey(String passengerId, String busId, AttendanceLeg leg) =>
      '$passengerId|$busId|${leg.name}';

  /// Expenses logged against [busId], oldest first.
  List<Expense> _expensesForBus(String busId) {
    final list = _expenses.values.where((e) => e.busId == busId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  /// Income entries logged against [busId], oldest first.
  List<IncomeEntry> _incomesForBus(String busId) {
    final list = _income.values.where((i) => i.busId == busId).toList();
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

  /// Reads the local attendance cache first, falling back to the manifest.
  /// Returns null when attendance hasn't been marked for that passenger on
  /// that leg.
  Attendance? _attendanceFor(
    String passengerId,
    String busId,
    AttendanceLeg leg,
  ) {
    final cached = _attendance[_attKey(passengerId, busId, leg)];
    if (cached != null) return cached;
    return _manifest?.attendanceFor(passengerId, busId, leg);
  }

  /// Whether [passengerId] is marked present on [busId] for [leg]. Unmarked
  /// passengers are NOT counted as boarded here (the tally treats "no row" as
  /// "not yet boarded" so the handler can work through the manifest); the
  /// model default of present=true only applies once a row is written.
  bool _isPresent(String passengerId, String busId, AttendanceLeg leg) =>
      _attendanceFor(passengerId, busId, leg)?.present ?? false;

  /// Every passenger expected to board [bus] on [leg]: those holding a seat on
  /// this bus whose trip uses the matching leg, deduped by passenger id and
  /// sorted by display name.
  List<Passenger> _expectedForLeg(
    HandlerManifest manifest,
    Bus bus,
    AttendanceLeg leg,
  ) {
    final seen = <String>{};
    final out = <Passenger>[];
    for (final p in manifest.passengers) {
      final onBus = p.assignedSeats.any((a) => a.busId == bus.id);
      if (!onBus) continue;
      final usesLeg = leg == AttendanceLeg.go
          ? p.tripType.usesOutbound
          : p.tripType.usesReturn;
      if (!usesLeg) continue;
      if (!seen.add(p.id)) continue;
      out.add(p);
    }
    out.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return out;
  }

  /// Boarding counts for [bus] on [leg] across its expected passengers.
  _AttendanceCounts _attendanceCounts(
    HandlerManifest manifest,
    Bus bus,
    AttendanceLeg leg,
  ) {
    final expected = _expectedForLeg(manifest, bus, leg);
    final present = expected.where((p) => _isPresent(p.id, bus.id, leg)).length;
    return _AttendanceCounts(present: present, total: expected.length);
  }

  /// Marks [p] present / left-behind on [bus] for [leg], persisting via the
  /// store and caching the server-returned row. Mirrors [_showOccupantSheet]'s
  /// save+cache flow.
  Future<void> _togglePresent(
    Bus bus,
    Passenger p,
    AttendanceLeg leg,
    bool present,
  ) async {
    // Resolve the tour id from the bus first, falling back to the passenger;
    // both manifest models carry tourId.
    final tourId = (bus.tourId?.isNotEmpty == true) ? bus.tourId! : p.tourId;
    final existing = _attendanceFor(p.id, bus.id, leg);
    final base =
        existing ??
        Attendance(tourId: tourId, busId: bus.id, passengerId: p.id, leg: leg);
    final updated = base.copyWith(present: present);
    try {
      final saved = await _store.handlerUpsertAttendance(
        widget.requestId,
        updated,
      );
      if (saved == null) {
        throw StateError('Handler attendance save was rejected.');
      }
      if (!mounted) return;
      // Cache the server-returned row so ids/timestamps stay aligned with the
      // database after insert or conflict update.
      setState(() {
        _attendance[_attKey(saved.passengerId, saved.busId, saved.leg)] = saved;
      });
    } catch (_) {
      AppSnackBar.error(tr('handler_chart.error_save_attendance'));
    }
  }

  /// Per-bus money totals for [bus], built on the shared [HandlerBusMoney] /
  /// [BusMoneySummary] so the handler can never disagree with the admin's money
  /// board on what was collected.
  ///
  /// Cash is summed per COLLECTION ROW scoped to the bus — NOT matched to a
  /// rider's current seat. The old per-seat lookup orphaned the row when a paid
  /// rider changed seats, dropping their cash from "collected" and double-
  /// counting it into "to collect".
  HandlerBusMoney _summaryForBus(HandlerManifest manifest, Bus bus) =>
      HandlerBusMoney.compute(
        busId: bus.id,
        passengers: manifest.passengers,
        collections: _collections.values.toList(),
        expenses: _expensesForBus(bus.id),
        incomes: _incomesForBus(bus.id),
        // The handler pays the bus owner out of collected cash, so the rent is
        // a real deduction from their in-hand — same figure the admin settles.
        busRent: bus.busPrice,
        dueForSeat: bus.amountDueForSeat,
      );

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
        _income
          ..clear()
          ..addEntries(
            (manifest?.incomes ?? const <IncomeEntry>[]).map(
              (i) => MapEntry(i.id, i),
            ),
          );
        _attendance
          ..clear()
          ..addEntries(
            (manifest?.attendance ?? const <Attendance>[]).map(
              (a) => MapEntry(_attKey(a.passengerId, a.busId, a.leg), a),
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

  void _onSeatTapped(Bus bus, String seatId, List<Passenger> occupants) {
    HapticFeedback.selectionClick();
    if (occupants.isEmpty) return;
    // A shared seat (a Double Sofa can carry up to four riders across GO+RET, or
    // two on one leg) needs a chooser so the handler picks whom to call /
    // collect from. A single occupant goes straight to the collect sheet.
    if (occupants.length == 1) {
      _showOccupantSheet(bus, seatId, occupants.first);
      return;
    }
    _showOccupantChooser(bus, seatId, occupants);
  }

  /// Shared seat → a small chooser listing EVERY rider (each with phone + Call),
  /// so the handler picks whom to act on before the collect sheet opens. Was
  /// leg-shared-only (one GO + one RETURN); now lists all riders so a Double
  /// Sofa booked by three or four one-way passengers is fully reachable.
  Future<void> _showOccupantChooser(
    Bus bus,
    String seatId,
    List<Passenger> occupants,
  ) {
    // Has the agent completed the outbound (GO) leg? Once they have, GO-only
    // riders are journeyDone — the chooser should open on the RETURN leg.
    final outboundDone =
        _manifest?.passengers.any((p) => p.journeyDone) ?? false;
    return UgamSheet.show<void>(
      context,
      title: tr('handler_chart.seat_shared_title', namedArgs: {'seat': seatId}),
      builder: (sheetCtx) => _OccupantChooserSheet(
        seatId: seatId,
        occupants: occupants,
        outboundDone: outboundDone,
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
            // Overpayment auto-books as change returned (net settles to due)
            // unless the handler typed an explicit return — same rule as the
            // admin collection screen. See [refundToRecord].
            amountRefunded: refundToRecord(
              due: due,
              received: received,
              manualReturned: returned,
            ),
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

  /// Opens the add/edit income sheet for [bus]. Pass [existing] to edit a logged
  /// income entry. On save the server-returned row is cached so the ledger and
  /// the "income / in hand" summary refresh without a reload. Income is cash the
  /// handler takes in outside the seat fares (e.g. cabin / gallery spots), so it
  /// ADDS to what they hold.
  Future<void> _showIncomeSheet(Bus bus, {IncomeEntry? existing}) {
    final tourId = bus.tourId?.isNotEmpty == true ? bus.tourId! : '';
    return UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('handler_chart.add_income')
          : tr('handler_chart.edit_income'),
      builder: (sheetCtx) => _IncomeSheet(
        existing: existing,
        onSave: (category, label, amount, receivedBy) async {
          final base =
              existing ??
              IncomeEntry(tourId: tourId, busId: bus.id, label: label);
          final updated = base.copyWith(
            busId: bus.id,
            category: category,
            label: label,
            amount: amount,
            receivedBy: receivedBy.isEmpty ? null : receivedBy,
          );
          final saved = await _store.handlerUpsertIncome(
            widget.requestId,
            updated,
          );
          if (saved == null) {
            throw StateError('Handler income save was rejected.');
          }
          if (!mounted) return;
          setState(() => _income[saved.id] = saved);
        },
      ),
    );
  }

  /// Confirms then removes a logged income entry, both on the server and in the
  /// local cache.
  Future<void> _deleteIncome(IncomeEntry income) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('handler_chart.delete_income_title'),
      message: income.label.isEmpty
          ? tr(
              'handler_chart.delete_income_msg_category',
              namedArgs: {
                'category': income.category.displayName.toLowerCase(),
                'amount': Formatters.formatMoneyInr(income.amount),
              },
            )
          : tr(
              'handler_chart.delete_income_msg_label',
              namedArgs: {
                'label': income.label,
                'amount': Formatters.formatMoneyInr(income.amount),
              },
            ),
      confirmLabel: tr('app.action.delete'),
      destructive: true,
    );
    if (ok != true) return;
    try {
      final removed = await _store.handlerDeleteIncome(
        widget.requestId,
        income.id,
      );
      if (!removed) {
        AppSnackBar.error(tr('handler_chart.error_delete_income'));
        return;
      }
      if (!mounted) return;
      setState(() => _income.remove(income.id));
    } catch (_) {
      AppSnackBar.error(tr('handler_chart.error_delete_income'));
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
              tr(
                'bus_message.sent_body',
                namedArgs: {'count': '${result.sent}'},
              ),
              title: tr('bus_message.sent_title'),
            );
          } else if (result.anySent) {
            AppSnackBar.warning(
              tr(
                'bus_message.partial_body',
                namedArgs: {
                  'sent': '${result.sent}',
                  'failed': '${result.failed}',
                },
              ),
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
  /// `SeatOccupancy` map flattened to the `List<Passenger>` shape the
  /// full-screen view expects: a leg-shared seat → both occupants, otherwise the
  /// sole occupant, else empty). Only wired up in grid view with a real chart on
  /// screen (see [build]).
  void _openFullscreenChart(Bus bus) {
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) return;
    // EVERY rider per seat (a Double Sofa can seat up to four across GO+RET),
    // so the full-screen chart shows the same complete roster the inline grid
    // and its occupant sheet now show — not just one holder per leg.
    final occupantsForFullscreen = occupantListForBus(
      _manifest!.passengers,
      bus.id,
    );
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
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              title: tr('handler_chart.bus_chart'),
              actions: [
                if (canMessage)
                  UgamAppBarAction(
                    icon: Icons.campaign_rounded,
                    onTap: () => _openBusMessageComposer(bus),
                    tooltip: tr('bus_message.message_bus'),
                  ),
                if (canExpand)
                  UgamAppBarAction(
                    icon: Icons.open_in_full_rounded,
                    onTap: () => _openFullscreenChart(bus),
                    tooltip: tr('handler_chart.expand_chart'),
                  ),
              ],
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
          padding: const EdgeInsets.all(UgamSpacing.lg),
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
          padding: const EdgeInsets.all(UgamSpacing.lg),
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
    // [fullOccupantsBySeat] keeps EVERY rider on a seat (a Double Sofa seats up
    // to four across GO+RET), so the tile shows all of them, the money dot can
    // aggregate across the whole berth, and a seat tap can offer the full
    // roster. The tile detects the GO/RET leg split itself from this list.
    final fullOccupantsBySeat = occupantListForBus(manifest.passengers, bus.id);

    final grid = _viewMode == _ViewMode.grid;
    final attendance = _viewMode == _ViewMode.attendance;

    // Boarding tallies for the header chips (both legs, current bus).
    final goCounts = _attendanceCounts(manifest, bus, AttendanceLeg.go);
    final retCounts = _attendanceCounts(manifest, bus, AttendanceLeg.ret);

    return Column(
      children: [
        if (multiBus)
          UgamSelectorPills(
            items: [
              for (final b in manifest.buses) UgamSelectorItem(label: b.name),
            ],
            currentIndex: manifest.buses.indexWhere((b) => b.id == bus.id),
            onChanged: (i) =>
                setState(() => _selectedBusId = manifest.buses[i].id),
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
              UgamTabItem(
                label: tr('handler_chart.view_attendance'),
                icon: Icons.how_to_reg_rounded,
              ),
            ],
            currentIndex: _viewMode == _ViewMode.list
                ? 0
                : _viewMode == _ViewMode.grid
                ? 1
                : 2,
            onChanged: (i) => setState(
              () => _viewMode = i == 0
                  ? _ViewMode.list
                  : i == 1
                  ? _ViewMode.grid
                  : _ViewMode.attendance,
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
                _DriverContact(bus: bus, c: c),
                _SummaryHeader(
                  collected: summary.collected,
                  toReturn: summary.toReturn,
                  toCollect: summary.toCollect,
                  spent: summary.spent,
                  income: summary.income,
                  rent: summary.rent,
                  inHand: summary.inHand,
                ),
                const SizedBox(height: UgamSpacing.md),
                _BoardedSummary(go: goCounts, ret: retCounts, c: c),
                const SizedBox(height: UgamSpacing.lg),
                if (grid) ...[
                  _SeatGrid(
                    bus: bus,
                    fullOccupantsBySeat: fullOccupantsBySeat,
                    collectionFor: (pId, seatId) =>
                        _collectionFor(pId, bus.id, seatId),
                    onTapSeat: (seatId, occupants) =>
                        _onSeatTapped(bus, seatId, occupants),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamSeatChartLegend(c: c),
                  _PriceBandKey(bus: bus),
                  const SizedBox(height: UgamSpacing.xl),
                  _ExpensesSection(
                    busName: bus.name,
                    expenses: _expensesForBus(bus.id),
                    onAdd: () => _showExpenseSheet(bus),
                    onEdit: (e) => _showExpenseSheet(bus, existing: e),
                    onDelete: (e) => _deleteExpense(e),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  _IncomeSection(
                    busName: bus.name,
                    incomes: _incomesForBus(bus.id),
                    onAdd: () => _showIncomeSheet(bus),
                    onEdit: (i) => _showIncomeSheet(bus, existing: i),
                    onDelete: (i) => _deleteIncome(i),
                  ),
                ] else if (attendance)
                  _AttendanceView(
                    bus: bus,
                    leg: _attLeg,
                    rows: [
                      for (final p in _expectedForLeg(manifest, bus, _attLeg))
                        _AttendanceEntry(
                          passenger: p,
                          present: _isPresent(p.id, bus.id, _attLeg),
                        ),
                    ],
                    onToggleLeg: (leg) => setState(() => _attLeg = leg),
                    onTogglePresent: (p, present) =>
                        _togglePresent(bus, p, _attLeg, present),
                  )
                else ...[
                  _SeatRoster(
                    bus: bus,
                    fullOccupantsBySeat: fullOccupantsBySeat,
                    collectionFor: (pId, seatId) =>
                        _collectionFor(pId, bus.id, seatId),
                    onTapSeat: (seatId, occupants) =>
                        _onSeatTapped(bus, seatId, occupants),
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
                  const SizedBox(height: UgamSpacing.xl),
                  _IncomeSection(
                    busName: bus.name,
                    incomes: _incomesForBus(bus.id),
                    onAdd: () => _showIncomeSheet(bus),
                    onEdit: (i) => _showIncomeSheet(bus, existing: i),
                    onDelete: (i) => _deleteIncome(i),
                  ),
                ],
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
              Expanded(
                child: UgamSkeleton(height: 76, radius: UgamRadius.card),
              ),
              SizedBox(width: UgamSpacing.md),
              Expanded(
                child: UgamSkeleton(height: 76, radius: UgamRadius.card),
              ),
              SizedBox(width: UgamSpacing.md),
              Expanded(
                child: UgamSkeleton(height: 76, radius: UgamRadius.card),
              ),
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

// ─── Group colour ──────────────────────────────────────────────────────

// Group ring colours come from the shared `groupColorForId` util
// (lib/design/group_color.dart) — an infinite, golden-angle hue generator that
// never collides with the warm priority ring or the one-way tint. The old
// copied 6-hue `_GroupPalette` was deleted so the handler reads exactly the
// same colour the agent seat-detail screen shows for a given group.

// ─── Seat grid card ────────────────────────────────────────────────────

class _SeatGrid extends StatelessWidget {
  final Bus bus;

  /// EVERY distinct rider per seat — handed to the tile (so a sofa shared by up
  /// to four riders shows them all + the "+N" badge), drives the seat-level
  /// money dot, and is passed to the tap handler.
  final Map<String, List<Passenger>> fullOccupantsBySeat;
  final Collection? Function(String passengerId, String seatId) collectionFor;
  final void Function(String seatId, List<Passenger> occupants) onTapSeat;

  const _SeatGrid({
    required this.bus,
    required this.fullOccupantsBySeat,
    required this.collectionFor,
    required this.onTapSeat,
  });

  /// The collection state for the WHOLE seat, aggregated across every rider
  /// sharing it: green only when ALL have squared off, otherwise the worst
  /// outstanding state wins — so a shared sofa with only one person's cash
  /// entered stays red instead of looking settled.
  SeatMoneyState _seatMoneyState(List<Passenger> occupants, String seatId) =>
      seatMoneyStateOf(
        occupants.map(
          (p) => riderMoneyStateOf(
            bus.amountDueForSeat(p, seatId),
            collectionFor(p.id, seatId),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
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
          // EVERY rider on this seat (up to four on a Double Sofa across
          // GO+RET). The canonical tile draws the leg split for the first two
          // and badges the rest; the tap hands the whole list to the chooser.
          // The tile detects the GO/RET split itself by trip type.
          final List<Passenger> occList = cell.seatId == null
              ? const <Passenger>[]
              : (fullOccupantsBySeat[cell.seatId!] ?? const <Passenger>[]);
          // The money dot is a SEAT-level summary across EVERY rider sharing
          // the berth — green only when ALL have squared off, so a shared sofa
          // with just one person's cash entered stays red, not green.
          final money = occList.isEmpty
              ? SeatMoneyState.uncollected
              : _seatMoneyState(occList, cell.seatId!);
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
                moneyDotColor: occList.isEmpty
                    ? null
                    : money.dotColor(UgamColors.of(ctx)),
                onTapBooked: occList.isEmpty
                    ? null
                    : () => onTapSeat(cell.seatId!, occList),
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

// ─── Call button ───────────────────────────────────────────────────────

/// The round tap-to-call button shared by the roster row, the shared-seat
/// chooser, and the attendance list. Dials [phone] via the platform dialer.
class _CallButton extends StatelessWidget {
  final String phone;
  final UgamColorSet c;

  const _CallButton({required this.phone, required this.c});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('handler_chart.call_semantic', namedArgs: {'phone': phone}),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          PhoneDialer.call(phone);
        },
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
          tr(
            'handler_chart.band_per_person',
            namedArgs: {'amount': Formatters.formatMoneyInr(band.price)},
          ),
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

  /// EVERY distinct rider per seat — a row is emitted per rider, so a Double
  /// Sofa shared by three or four one-way passengers lists all of them.
  final Map<String, List<Passenger>> fullOccupantsBySeat;
  final Collection? Function(String passengerId, String seatId) collectionFor;
  final void Function(String seatId, List<Passenger> occupants) onTapSeat;

  const _SeatRoster({
    required this.bus,
    required this.fullOccupantsBySeat,
    required this.collectionFor,
    required this.onTapSeat,
  });

  SeatMoneyState _moneyState(Passenger passenger, String seatId) =>
      riderMoneyStateOf(
        bus.amountDueForSeat(passenger, seatId),
        collectionFor(passenger.id, seatId),
      );

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
        alignment: Alignment.center,
        child: Text(
          tr('handler_chart.no_seat_layout'),
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    // Walk every seat cell in placement order; emit an entry per distinct
    // occupant, then group the roster by pickup location. Seat order is
    // preserved WITHIN each pickup group. `grid` is the flat seat list (only
    // [hasSeat] cells stored).
    final entries = <({String seatId, Passenger passenger})>[];
    for (final cell in layout.grid) {
      final seatId = cell.seatId;
      if (seatId == null) continue;
      final occupants = fullOccupantsBySeat[seatId] ?? const <Passenger>[];
      if (occupants.isEmpty) continue;
      for (final p in occupants) {
        entries.add((seatId: seatId, passenger: p));
      }
    }

    if (entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
        alignment: Alignment.center,
        child: Text(
          tr(
            'handler_chart.no_passengers_on_bus',
            namedArgs: {'bus': bus.name},
          ),
          textAlign: TextAlign.center,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      );
    }

    return PickupGroupedList<({String seatId, Passenger passenger})>(
      groups: groupByPickup<({String seatId, Passenger passenger})>(
        entries,
        idOf: (e) => e.passenger.pickupLocationId,
        nameOf: (e) => e.passenger.pickupLocationName,
      ),
      rowBuilder: (e) => _RosterRow(
        seatId: e.seatId,
        passenger: e.passenger,
        money: _moneyState(e.passenger, e.seatId),
        // A roster row is one specific rider — go straight to their sheet
        // (single-element list skips the chooser).
        onTap: () => onTapSeat(e.seatId, <Passenger>[e.passenger]),
        c: c,
      ),
      unassignedLabel: tr('handler_chart.pickup_none'),
      c: c,
    );
  }
}

/// One roster line: seat id chip, full name + mobile + group dot + trip badge,
/// and a tap-to-call action plus the collection-status chip.
class _RosterRow extends StatelessWidget {
  final String seatId;
  final Passenger passenger;
  final SeatMoneyState money;
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
      case SeatMoneyState.paid:
        return tr('handler_chart.money_paid');
      case SeatMoneyState.owing:
        return tr('handler_chart.money_owing');
      case SeatMoneyState.returnDue:
        return tr('handler_chart.money_return_due');
      case SeatMoneyState.uncollected:
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
                      _Dot(color: money.dotColor(c), size: 7),
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
              _CallButton(phone: p.phone, c: c),
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
        : (isRet
              ? tr('handler_chart.badge_ret')
              : tr('handler_chart.badge_go'));
    final label = oneWay
        ? tr('handler_chart.badge_half_suffix', namedArgs: {'leg': base})
        : base;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: oneWay ? tint : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
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

/// A chooser for a shared seat. When the seat is leg-divided — different riders
/// per leg (an outbound-only + a return-only, or a round-trip sharing with a
/// one-way rider) — the handler collects from ONE leg at a time: the GO riders
/// while the bus is going out, the RETURN riders once GO is done. A GO/Return
/// toggle (mirroring the attendance view) switches between them, opening on the
/// active leg by default. A non-divided seat (same riders on both legs, or all
/// on one leg) lists everyone with no toggle. Each row carries phone + a Call
/// button, so the handler picks whom to collect from / call before the collect
/// sheet opens.
class _OccupantChooserSheet extends StatefulWidget {
  final String seatId;
  final List<Passenger> occupants;

  /// Whether the agent has completed the outbound leg — seeds the default leg
  /// to RETURN so the handler collects from the riders still aboard.
  final bool outboundDone;
  final ValueChanged<Passenger> onPick;

  const _OccupantChooserSheet({
    required this.seatId,
    required this.occupants,
    required this.outboundDone,
    required this.onPick,
  });

  @override
  State<_OccupantChooserSheet> createState() => _OccupantChooserSheetState();
}

class _OccupantChooserSheetState extends State<_OccupantChooserSheet> {
  late CollectLeg _leg = defaultCollectLeg(
    widget.occupants,
    outboundDone: widget.outboundDone,
  );

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasSplit = seatHasLegSplit(widget.occupants);
    final shown = hasSplit
        ? occupantsForCollectLeg(widget.occupants, _leg)
        : widget.occupants;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('handler_chart.leg_shared_intro'),
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        if (hasSplit) ...[
          const SizedBox(height: UgamSpacing.md),
          // GO / Return leg toggle — same control the attendance view uses.
          UgamTabPills(
            items: [
              UgamTabItem(label: tr('handler_chart.att_leg_go')),
              UgamTabItem(label: tr('handler_chart.att_leg_ret')),
            ],
            currentIndex: _leg == CollectLeg.go ? 0 : 1,
            onChanged: (i) =>
                setState(() => _leg = i == 0 ? CollectLeg.go : CollectLeg.ret),
          ),
        ],
        const SizedBox(height: UgamSpacing.md),
        // Cross-fade the occupant list when the GO/RET leg toggle changes so the
        // tiles swap smoothly instead of popping. Contained region only — the
        // sheet's surrounding layout is untouched.
        AnimatedSwitcher(
          duration: UgamMotion.sheet,
          switchInCurve: UgamMotion.easeOut,
          switchOutCurve: UgamMotion.easeOut,
          child: Column(
            key: ValueKey<CollectLeg>(_leg),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(height: UgamSpacing.sm),
                _LegSharedTile(
                  passenger: shown[i],
                  // The badge reads each rider's own leg (GO / RET / round-trip).
                  leg: shown[i].tripType,
                  onPick: () => widget.onPick(shown[i]),
                  c: c,
                ),
              ],
            ],
          ),
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
              _CallButton(phone: p.phone, c: c),
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

/// Driver name + phone for THIS bus, with one-tap call and WhatsApp so the
/// handler can reach the driver from the ground (running late, boarding-point
/// change, head-count). Hidden entirely when the bus has neither a driver name
/// nor a phone — there is nothing to show or contact. The phone line and the
/// action buttons only appear when a number exists; otherwise just the name is
/// shown so the handler at least knows who is driving.
class _DriverContact extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;

  const _DriverContact({required this.bus, required this.c});

  Future<void> _openWhatsApp(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    try {
      final ok = await WhatsAppService().openChat(phone: phone, message: '');
      if (!ok) {
        AppSnackBar.error(
          tr('handler_chart.wa_open_failed', namedArgs: {'phone': phone}),
          title: tr('handler_chart.wa_failed_title'),
        );
      }
    } catch (e) {
      AppSnackBar.error(
        tr('handler_chart.wa_open_error', namedArgs: {'error': '$e'}),
        title: tr('handler_chart.wa_failed_title'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = bus.driverName.trim();
    final phone = bus.driverPhone.trim();
    if (name.isEmpty && phone.isEmpty) return const SizedBox.shrink();
    final hasPhone = phone.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.directions_bus_filled_rounded,
                size: 19,
                color: c.accent,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('handler_chart.driver'),
                    style: UgamText.micro.copyWith(
                      color: c.ink3,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    name.isEmpty ? tr('handler_chart.driver_unnamed') : name,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hasPhone)
                    Text(
                      phone,
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink2),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (hasPhone) ...[
              const SizedBox(width: UgamSpacing.sm),
              Semantics(
                button: true,
                label: tr(
                  'handler_chart.call_semantic',
                  namedArgs: {'phone': phone},
                ),
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    PhoneDialer.call(phone);
                  },
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
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  _openWhatsApp(phone);
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.goodFill,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.chat_rounded, size: 17, color: c.good),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Summary header ────────────────────────────────────────────────────

/// Boarding tally for one bus + leg: how many of the [total] expected
/// passengers are marked [present], and by subtraction how many were left
/// behind.
class _AttendanceCounts {
  final int present;
  final int total;

  const _AttendanceCounts({required this.present, required this.total});

  int get left => total - present;
}

/// One row in the attendance list: a passenger expected on the current leg
/// plus their boarded flag (resolved from the cache/manifest by the screen).
class _AttendanceEntry {
  final Passenger passenger;
  final bool present;

  const _AttendanceEntry({required this.passenger, required this.present});
}

class _SummaryHeader extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;
  final double spent;
  final double income;
  final double rent;
  final double inHand;

  const _SummaryHeader({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
    required this.rent,
    required this.inHand,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // ONE money hero: "In hand" is the headline; everything else is folded
    // into a tap-to-reveal breakdown so the chart/roster owns the viewport.
    return UgamHeroStat(
      label: tr('handler_chart.stat_in_hand'),
      value: Formatters.formatMoneyInr(inHand),
      secondary: tr(
        'handler_chart.in_hand_secondary',
        namedArgs: {'amount': Formatters.formatMoneyInr(collected)},
      ),
      breakdown: [
        HeroStatLine(
          tr('handler_chart.stat_collected'),
          Formatters.formatMoneyInr(collected),
          tone: c.good,
        ),
        HeroStatLine(
          tr('handler_chart.stat_to_collect'),
          Formatters.formatMoneyInr(toCollect),
          tone: c.accent,
        ),
        HeroStatLine(
          tr('handler_chart.stat_to_return'),
          Formatters.formatMoneyInr(toReturn),
          tone: c.warm,
        ),
        HeroStatLine(
          tr('handler_chart.stat_income'),
          Formatters.formatMoneyInr(income),
          tone: c.good,
        ),
        HeroStatLine(
          tr('handler_chart.stat_spent'),
          Formatters.formatMoneyInr(spent),
          tone: c.warm,
        ),
        // The owner's rent the handler pays out of collected cash — shown as a
        // distinct deduction so the in-hand drop reads clearly. Hidden when the
        // bus carries no rent.
        if (rent > 0.005)
          HeroStatLine(
            tr('handler_chart.stat_rent'),
            Formatters.formatMoneyInr(rent),
            tone: c.warm,
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
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
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
                              borderRadius: BorderRadius.circular(
                                UgamRadius.chip,
                              ),
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
                final isRet =
                    passenger.tripType.usesReturn &&
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
                        namedArgs: {
                          'amount': Formatters.formatMoneyInr(balance),
                        },
                      ),
                      c.warm,
                    )
                  : balance < 0
                  ? (
                      tr(
                        'handler_chart.balance_still_to_collect',
                        namedArgs: {
                          'amount': Formatters.formatMoneyInr(-balance),
                        },
                      ),
                      c.danger,
                    )
                  : (tr('handler_chart.balance_settled'), c.good);
              // Smooth the color/text transitions as the amount field changes;
              // the balance VALUE/logic is unchanged, only the visual is eased.
              return AnimatedContainer(
                duration: UgamMotion.sheet,
                curve: UgamMotion.easeOut,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.lg,
                  vertical: UgamSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: balColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: UgamMotion.sheet,
                  curve: UgamMotion.easeOut,
                  style: UgamText.bodyStrong.copyWith(color: balColor),
                  child: Text(balLabel),
                ),
              );
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving ? tr('handler_chart.saving') : tr('app.action.save'),
            loading: _saving,
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
            UgamButton(
              label: tr('app.action.add'),
              icon: Icons.add_rounded,
              kind: UgamButtonKind.tonal,
              onPressed: onAdd,
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
                onTap: () {
                  HapticFeedback.lightImpact();
                  onDelete();
                },
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
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
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
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _category = cat);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: UgamMotion.tab,
                      curve: UgamMotion.easeOut,
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
                })
                .toList(),
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
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

// ─── Income section ────────────────────────────────────────────────────

/// The handler's per-bus income ledger: a header with the running total + an
/// Add action, then one tappable row per logged income entry (tap to edit,
/// trash to delete). Mirrors [_ExpensesSection], scoped to the bus the handler
/// is currently viewing so they can log cabin / gallery cash taken in on the
/// ground — money that ADDS to what they hold, unlike an expense.
class _IncomeSection extends StatelessWidget {
  final String busName;
  final List<IncomeEntry> incomes;
  final VoidCallback onAdd;
  final ValueChanged<IncomeEntry> onEdit;
  final ValueChanged<IncomeEntry> onDelete;

  const _IncomeSection({
    required this.busName,
    required this.incomes,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final total = incomes.fold<double>(0, (sum, i) => sum + i.amount);
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
                    tr('handler_chart.bus_income'),
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  if (incomes.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr(
                        'handler_chart.bus_income_total',
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
            UgamButton(
              label: tr('app.action.add'),
              icon: Icons.add_rounded,
              kind: UgamButtonKind.tonal,
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        if (incomes.isEmpty)
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(
              vertical: UgamSpacing.lg,
              horizontal: UgamSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.savings_outlined, size: 18, color: c.ink3),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('handler_chart.no_income'),
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
                for (final i in incomes)
                  _HandlerIncomeRow(
                    income: i,
                    onTap: () => onEdit(i),
                    onDelete: () => onDelete(i),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One income line: category chip, label (+ "received by"), amount, and a
/// delete affordance. The whole row taps through to edit.
class _HandlerIncomeRow extends StatelessWidget {
  final IncomeEntry income;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HandlerIncomeRow({
    required this.income,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final receivedBy = (income.receivedBy ?? '').trim();
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
                income.category.displayName,
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
                    income.label.isEmpty
                        ? income.category.displayName
                        : income.label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (receivedBy.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr(
                        'handler_chart.received_by',
                        namedArgs: {'name': receivedBy},
                      ),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(income.amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.good),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: tr('handler_chart.delete_income'),
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  onDelete();
                },
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

// ─── Income sheet ──────────────────────────────────────────────────────

/// Add / edit one bus income entry. Category chips (cabin / gallery / other) +
/// what-for label + amount + "received by", mirroring [_ExpenseSheet]. [onSave]
/// persists via the handler RPC and updates the ledger; this widget owns the
/// controllers and pops on success.
class _IncomeSheet extends StatefulWidget {
  final IncomeEntry? existing;
  final Future<void> Function(
    IncomeCategory category,
    String label,
    double amount,
    String receivedBy,
  )
  onSave;

  const _IncomeSheet({required this.existing, required this.onSave});

  @override
  State<_IncomeSheet> createState() => _IncomeSheetState();
}

class _IncomeSheetState extends State<_IncomeSheet> {
  late IncomeCategory _category;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _receivedByCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final i = widget.existing;
    _category = i?.category ?? IncomeCategory.cabin;
    _labelCtrl = TextEditingController(text: i?.label ?? '');
    _amountCtrl = TextEditingController(
      text: (i?.amount ?? 0) == 0 ? '' : i!.amount.toStringAsFixed(0),
    );
    _receivedByCtrl = TextEditingController(text: i?.receivedBy ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    _receivedByCtrl.dispose();
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
        _receivedByCtrl.text.trim(),
      );
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr('handler_chart.error_save_income'));
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
            children: IncomeCategory.values.map((cat) {
              final active = cat == _category;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _category = cat);
                },
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
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
            label: tr('handler_chart.field_received_by'),
            controller: _receivedByCtrl,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('handler_chart.saving')
                : tr('handler_chart.save_income'),
            loading: _saving,
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
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
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
            tr(
              'bus_message.handler_intro',
              namedArgs: {'bus': widget.busLabel},
            ),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          BusMessageComposerField(controller: _textCtrl),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _sending
                ? tr('bus_message.sending')
                : tr('bus_message.send_btn'),
            leadingIcon: Icons.send_rounded,
            loading: _sending,
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
  }
}

// ─── Boarded summary chips ─────────────────────────────────────────────

/// Two compact chips under the money summary — GO and RET — each showing the
/// "Boarded {present}/{total}" tally for the current bus, tinted with the
/// chart's leg colours (GO cyan [kOneWayTint], RET violet [kReturnTint]) so the
/// boarding state is glanceable from every view mode.
class _BoardedSummary extends StatelessWidget {
  final _AttendanceCounts go;
  final _AttendanceCounts ret;
  final UgamColorSet c;

  const _BoardedSummary({required this.go, required this.ret, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BoardedChip(
            icon: Icons.north_east_rounded,
            tint: kOneWayTint,
            counts: go,
            c: c,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: _BoardedChip(
            icon: Icons.south_west_rounded,
            tint: kReturnTint,
            counts: ret,
            c: c,
          ),
        ),
      ],
    );
  }
}

class _BoardedChip extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final _AttendanceCounts counts;
  final UgamColorSet c;

  const _BoardedChip({
    required this.icon,
    required this.tint,
    required this.counts,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: tint.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              tr(
                'handler_chart.att_boarded',
                namedArgs: {
                  'present': '${counts.present}',
                  'total': '${counts.total}',
                },
              ),
              style: UgamText.micro.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Attendance view ───────────────────────────────────────────────────

/// The handler's boarding board for one bus: a GO/RET leg toggle, a present /
/// left-behind / total tally header, and a tap-to-mark roster of every
/// passenger expected on the chosen leg. Strictly attendance — no money or seat
/// pricing chrome (those live in the grid / list views).
class _AttendanceView extends StatelessWidget {
  final Bus bus;
  final AttendanceLeg leg;
  final List<_AttendanceEntry> rows;
  final ValueChanged<AttendanceLeg> onToggleLeg;
  final void Function(Passenger passenger, bool present) onTogglePresent;

  const _AttendanceView({
    required this.bus,
    required this.leg,
    required this.rows,
    required this.onToggleLeg,
    required this.onTogglePresent,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final total = rows.length;
    final present = rows.where((r) => r.present).length;
    final left = total - present;

    return Column(
      children: [
        // GO / RET leg toggle.
        UgamTabPills(
          items: [
            UgamTabItem(label: tr('handler_chart.att_leg_go')),
            UgamTabItem(label: tr('handler_chart.att_leg_ret')),
          ],
          currentIndex: leg == AttendanceLeg.go ? 0 : 1,
          onChanged: (i) =>
              onToggleLeg(i == 0 ? AttendanceLeg.go : AttendanceLeg.ret),
        ),
        const SizedBox(height: UgamSpacing.md),
        // Tally header: present / left-behind / total.
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.how_to_reg_rounded,
                value: '$present',
                label: tr('handler_chart.att_present'),
                variant: UgamStatVariant.good,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.person_off_rounded,
                value: '$left',
                label: tr('handler_chart.att_left_behind'),
                variant: UgamStatVariant.warm,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.groups_rounded,
                value: '$total',
                label: tr('handler_chart.att_total'),
                variant: UgamStatVariant.neutral,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            tr(
              'handler_chart.att_tally',
              namedArgs: {'present': '$present', 'left': '$left'},
            ),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
        ),
        const SizedBox(height: UgamSpacing.lg),
        if (rows.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
            alignment: Alignment.center,
            child: Text(
              tr('handler_chart.att_none'),
              textAlign: TextAlign.center,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
          )
        else
          // Cross-fade the roster card when the GO/RET leg toggle changes so the
          // list swaps smoothly. Contained region only — the surrounding scroll
          // layout is untouched.
          AnimatedSwitcher(
            duration: UgamMotion.sheet,
            switchInCurve: UgamMotion.easeOut,
            switchOutCurve: UgamMotion.easeOut,
            child: PickupGroupedList<_AttendanceEntry>(
              key: ValueKey<AttendanceLeg>(leg),
              groups: groupByPickup<_AttendanceEntry>(
                rows,
                idOf: (e) => e.passenger.pickupLocationId,
                nameOf: (e) => e.passenger.pickupLocationName,
              ),
              rowBuilder: (e) => _AttendanceRow(
                bus: bus,
                passenger: e.passenger,
                present: e.present,
                onChanged: (v) => onTogglePresent(e.passenger, v),
                c: c,
              ),
              unassignedLabel: tr('handler_chart.pickup_none'),
              c: c,
            ),
          ),
      ],
    );
  }
}

/// One attendance line: the passenger's seat id chip(s) on this bus, their name
/// + mobile, and a present / left-behind toggle. Mirrors [_RosterRow]'s left
/// side; the trailing control is a [Switch] instead of a call button.
class _AttendanceRow extends StatelessWidget {
  final Bus bus;
  final Passenger passenger;
  final bool present;
  final ValueChanged<bool> onChanged;
  final UgamColorSet c;

  const _AttendanceRow({
    required this.bus,
    required this.passenger,
    required this.present,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final p = passenger;
    final hasPhone = p.phone.trim().isNotEmpty;
    final hasGroup = p.groupId != null && p.groupId!.isNotEmpty;
    final groupColor = hasGroup ? groupColorForId(p.groupId!) : null;
    // Every seat this passenger holds on THIS bus, joined (a whole double-sofa
    // resolves to a single seat id via the set).
    final seatIds =
        p.assignedSeats
            .where((a) => a.busId == bus.id)
            .map((a) => a.seatId)
            .toSet()
            .toList()
          ..sort();
    final seatLabel = seatIds.join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      child: Row(
        children: [
          // Seat id chip(s).
          Container(
            constraints: const BoxConstraints(minWidth: 40),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            child: Text(
              seatLabel,
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          // Name + mobile + group dot.
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
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  hasPhone ? p.phone : tr('handler_chart.no_mobile'),
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(color: hasPhone ? c.ink2 : c.ink3),
                  ),
                ),
              ],
            ),
          ),
          // Tap-to-call — reach a no-show straight from the attendance list.
          if (hasPhone) ...[
            const SizedBox(width: UgamSpacing.sm),
            _CallButton(phone: p.phone, c: c),
          ],
          // Present / left-behind toggle.
          const SizedBox(width: UgamSpacing.sm),
          Semantics(
            label: tr('handler_chart.att_mark_present'),
            toggled: present,
            child: Switch(
              value: present,
              onChanged: (v) {
                HapticFeedback.lightImpact();
                onChanged(v);
              },
              activeTrackColor: c.good,
              activeThumbColor: c.onAccent,
            ),
          ),
        ],
      ),
    );
  }
}
