import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/utils/boarding_stops.dart';

/// Stop-by-stop boarding is what replaces the flat attendance list. The
/// "which stop are we at" answer is derived rather than stored, so it is
/// pinned down here before any widget depends on it.
void main() {
  Passenger rider(String name, {String? pickupId, String? pickupName}) =>
      Passenger(
        id: name,
        tourId: 'tour-1',
        name: name,
        phone: '900000000$name',
        pickupLocationId: pickupId,
        pickupLocationName: pickupName,
      );

  // Adajan is serial 1, Varachha 2, Kamrej 3 — the admin's route order, which
  // is deliberately NOT alphabetical so the ranking is actually exercised.
  int? rank(String? id, String name) =>
      const {'adajan': 1, 'varachha': 2, 'kamrej': 3}[id];

  final riders = [
    rider('1', pickupId: 'kamrej', pickupName: 'Kamrej'),
    rider('2', pickupId: 'adajan', pickupName: 'Adajan'),
    rider('3', pickupId: 'varachha', pickupName: 'Varachha'),
    rider('4', pickupId: 'adajan', pickupName: 'Adajan'),
  ];

  group('buildBoardingProgress', () {
    test('orders stops by the admin route order, not the alphabet', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (_) => false,
        rankOf: rank,
      );
      expect(p.stops.map((s) => s.locationName).toList(), [
        'Adajan',
        'Varachha',
        'Kamrej',
      ]);
    });

    test('the current stop is the first one not fully boarded', () {
      // Both Adajan riders aboard, nobody else.
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '2' || r.id == '4',
        rankOf: rank,
      );
      expect(p.stops.first.isComplete, isTrue);
      expect(p.currentIndex, 1);
      expect(p.current!.locationName, 'Varachha');
    });

    test('counts roll up across stops', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '2',
        rankOf: rank,
      );
      expect(p.total, 4);
      expect(p.boarded, 1);
      expect(p.pending, 3);
      expect(p.stopsComplete, 0);
      expect(p.isComplete, isFalse);
    });

    test('everyone aboard leaves no current stop', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (_) => true,
        rankOf: rank,
      );
      expect(p.currentIndex, isNull);
      expect(p.current, isNull);
      expect(p.isComplete, isTrue);
      expect(p.stopsComplete, 3);
    });

    // Forgiving on purpose: a rider who walks up the route to meet the bus
    // must not drag the handler back to a stop they have finished with.
    test('boarding out of order does not move the current stop backwards', () {
      // The Kamrej rider (last stop) boards early; Adajan is still pending.
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '1',
        rankOf: rank,
      );
      expect(p.current!.locationName, 'Adajan');
      expect(p.stops.last.boarded, 1);
    });

    test('riders with no pickup point fall into a last, unnamed stop', () {
      final p = buildBoardingProgress(
        [...riders, rider('5')],
        isPresent: (_) => false,
        rankOf: rank,
      );
      expect(p.stops.last.isUnassigned, isTrue);
      expect(p.stops.last.total, 1);
    });

    test('per-stop pending is what the handler reads before leaving', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '2',
        rankOf: rank,
      );
      final adajan = p.stops.first;
      expect(adajan.total, 2);
      expect(adajan.boarded, 1);
      expect(adajan.pending, 1);
      expect(adajan.isComplete, isFalse);
    });

    test('an empty roster is complete-free rather than crashing', () {
      final p = buildBoardingProgress(const [], isPresent: (_) => true);
      expect(p.stops, isEmpty);
      expect(p.currentIndex, isNull);
      expect(p.total, 0);
      // total == 0 must not read as "everyone is aboard".
      expect(p.isComplete, isFalse);
    });
  });
}
