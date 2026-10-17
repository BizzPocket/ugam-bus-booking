import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/screens/board/board_screen.dart';

Passenger _p(String id) =>
    Passenger(id: id, tourId: 't1', name: id, phone: '+910000000000');

void main() {
  group('resolveBoardCollectRider', () {
    test('a shared berth credits the selected rider, not the first one', () {
      final go = _p('go');
      final ret = _p('ret');
      expect(resolveBoardCollectRider([go, ret], ret), same(ret));
    });

    test('the live roster row wins over the sheet snapshot', () {
      final live = _p('ret');
      expect(resolveBoardCollectRider([_p('go'), live], _p('ret')), same(live));
    });

    test('a solo berth with no selection is its one rider', () {
      final solo = _p('solo');
      expect(resolveBoardCollectRider([solo], null), same(solo));
    });

    test('never guesses: no selection on a shared berth, or a stale one', () {
      expect(resolveBoardCollectRider([_p('a'), _p('b')], null), isNull);
      expect(resolveBoardCollectRider([_p('a')], _p('gone')), isNull);
    });
  });
}
