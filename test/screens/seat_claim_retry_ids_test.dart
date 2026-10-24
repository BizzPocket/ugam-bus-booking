import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/screens/seat_booking_confirm_screen.dart';

/// A rider on 2G taps "Confirm seats"; the claim commits on the server but the
/// answer never reaches the phone. They tap again. With a new id per tap the
/// retry was a NEW claim for seats the first one had just taken: "seats taken",
/// and no ticket saved. The retry must carry the SAME ids.
void main() {
  var n = 0;
  String mint() => 'id-${n++}';

  setUp(() => n = 0);

  test('a retry of the same checkout re-uses every id', () {
    final first = claimIdsFor(null, 'sig-A', ['bus1', 'bus2'], mint: mint);
    final retry = claimIdsFor(first, 'sig-A', ['bus1', 'bus2'], mint: mint);

    expect(retry.requestId, first.requestId);
    expect(retry.partyId, first.partyId);
    expect(retry.busRequestIds, first.busRequestIds);
    expect(n, 4, reason: 'nothing new is minted for the retry');
  });

  test('a CHANGED checkout is a different booking and gets fresh ids', () {
    final first = claimIdsFor(null, 'sig-A', ['bus1'], mint: mint);
    final changed = claimIdsFor(first, 'sig-B', ['bus1'], mint: mint);

    expect(changed.requestId, isNot(first.requestId));
    expect(changed.partyId, isNot(first.partyId));
    expect(changed.busRequestIds['bus1'], isNot(first.busRequestIds['bus1']));
  });

  test('no pending attempt mints one request id per bus', () {
    final ids = claimIdsFor(null, 'sig', ['b1', 'b2', 'b3'], mint: mint);
    expect(ids.busRequestIds.keys, ['b1', 'b2', 'b3']);
    expect(ids.busRequestIds.values.toSet(), hasLength(3));
  });
}
