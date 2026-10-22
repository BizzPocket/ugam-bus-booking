import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/utils/app_snackbar.dart';

class _DeadWrites extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async =>
      throw const SocketException('connection reset');
}

/// The snap-back reload after a failed write is held open, as it is on 2G.
class _SlowRefreshMoney extends MoneyController {
  final gate = Completer<void>();

  @override
  Future<void> refreshForTour(String tourId) => gate.future;
}

/// A failed money write must say so at once. The snap-back reload behind it
/// is four reads that take most of a minute on 2G, and the toast used to wait
/// for all of them — a failed save looked like a save.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    AppSnackBar.debugOnShow = null;
    Get.reset();
  });

  test('the failure toast fires BEFORE the slow snap-back reload lands',
      () async {
    Get.put<SyncService>(_DeadWrites());
    final money = _SlowRefreshMoney();
    final toasts = <UgamSnackTone>[];
    AppSnackBar.debugOnShow = (_, tone) => toasts.add(tone);

    final write = money.upsertExpense(
      Expense(
        tourId: 't1',
        busId: 'b1',
        category: ExpenseCategory.other,
        label: 'Diesel',
        amount: 500,
      ),
    );
    final outcome = expectLater(write, throwsA(isA<SocketException>()));
    await pumpEventQueue();

    expect(toasts, [UgamSnackTone.error],
        reason: 'the agent hears about the failure while the reload is '
            'still on the wire');

    money.gate.complete();
    await outcome;
  });
}
