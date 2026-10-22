import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Money reads that fail until [healthy] is set — the board that loaded on a
/// dead link and must heal by itself once signal returns.
class _FlakySync extends SyncService {
  bool healthy = false;
  int collectionFetches = 0;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
  smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    if (table == 'collections') collectionFetches++;
    if (!healthy) {
      return (
        rows: const <Map<String, dynamic>>[],
        failed: true,
        error: 'timed out',
      );
    }
    return (rows: const <Map<String, dynamic>>[], failed: false, error: null);
  }

  @override
  Future<void> invalidateCache(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalDelay = MoneyController.reconnectReloadDelay;

  late _FlakySync sync;
  late MoneyController money;

  setUp(() {
    Get.reset();
    MoneyController.reconnectReloadDelay = const Duration(milliseconds: 10);
    sync = _FlakySync();
    Get.put<SyncService>(sync);
    final ledger = LedgerMoneySource()
      ..debugFetchBusRows = ((_) async => const [])
      ..debugFetchTourRows = (() async => const []);
    money = Get.put(MoneyController(ledgerSource: ledger));
  });

  tearDown(() {
    MoneyController.reconnectReloadDelay = originalDelay;
    Get.reset();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  test('a board that FAILED to load re-reads itself when signal returns',
      () async {
    await money.loadForTour('t1');
    expect(money.loadFailed.value, isTrue);
    expect(sync.collectionFetches, 1);

    sync.healthy = true;
    // A flapping link: several online edges in a row.
    sync.isOnline.value = false;
    sync.isOnline.value = true;
    sync.isOnline.value = false;
    sync.isOnline.value = true;
    await settle();

    expect(sync.collectionFetches, 2, reason: 'one reload, not one per flap');
    expect(money.loadFailed.value, isFalse);
  });

  test('a board that loaded fine is NOT re-read on every connectivity flap',
      () async {
    sync.healthy = true;
    await money.loadForTour('t1');
    expect(money.loadFailed.value, isFalse);

    sync.isOnline.value = false;
    sync.isOnline.value = true;
    await settle();

    expect(sync.collectionFetches, 1);
  });
}
