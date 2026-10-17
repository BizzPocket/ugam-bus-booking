import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:get/get.dart';

import '../models/collection.dart';
import '../models/expense.dart';
import '../models/income_entry.dart';
import '../models/bus_handover.dart';
import '../models/ledger_bus_rollup.dart';
import '../models/money_summary.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/payment_claim.dart';
import '../models/tour.dart';
import '../services/collection_reconciler.dart';
import '../services/ledger_money_source.dart';
import '../services/supabase_service.dart';
import '../services/sync_read_projections.dart';
import '../services/sync_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/collection_seat_resolver.dart';
import '../utils/seat_money_state.dart';
import 'finance_controller.dart';
import 'tour_controller.dart';

part 'money_controller/base.dart';
part 'money_controller/aggregation.dart';
part 'money_controller/settlement.dart';
part 'money_controller/load.dart';
part 'money_controller/writes.dart';

/// Loads & persists the money tables (`collections`, `expenses`,
/// `bus_handovers`, `incomes`) for a single tour via [SyncService], and
/// exposes aggregation summaries from the finance ledger when available
/// (legacy row lists remain the write/edit surface).
///
/// CRUD follows the same shape as [TourController]: mutate local state
/// optimistically so the UI feels instant, await the server write, and on
/// failure pull fresh state from the server + surface the error.
///
/// RLS note: these three tables are NOT owner-scoped (no `owner_id`
/// column). Their policies validate via the tour-owner join, so we just
/// send the row's `toMap()` (which already carries `tour_id`/`bus_id`).
class MoneyController extends _MoneyControllerBase
    with _MoneyAggregation, _MoneySettlement, _MoneyLoad, _MoneyWrites {
  MoneyController({LedgerMoneySource? ledgerSource})
      : _ledgerSource = ledgerSource ?? LedgerMoneySource();

  @override
  final LedgerMoneySource _ledgerSource;
}

/// Per-bus money board state, driving the attention ring on the tour money
/// board. Kept here (next to the aggregation helpers) so both the screen and
/// its tests share one source of truth.
enum BusMoneyState { actionNeeded, settled, neutral }
