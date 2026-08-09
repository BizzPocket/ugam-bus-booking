import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Pins the 2G read-budget policy: cellular / unknown gets the long timeout;
/// wifi/ethernet keeps the shorter one. Connectivity is forced via the obs
/// rather than the platform plugin.
class _TimeoutProbeSync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  test('cellular radio uses the long per-page read timeout', () {
    final sync = _TimeoutProbeSync();
    sync.isCellular.value = true;
    expect(sync.readTimeout, const Duration(seconds: 28));
  });

  test('wifi radio keeps the shorter per-page read timeout', () {
    final sync = _TimeoutProbeSync();
    sync.isCellular.value = false;
    expect(sync.readTimeout, const Duration(seconds: 12));
  });
}
