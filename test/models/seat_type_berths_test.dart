import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_type.dart';

/// The single domain rule "a Double Sofa is two berths, everything else one"
/// lives on [SeatType.berthsPerUnit]. Guard it so the form's seat-total and the
/// capacity accounting can't silently diverge on what a double sofa is worth.
void main() {
  test('berthsPerUnit: a double sofa is 2 berths, others are 1', () {
    expect(SeatType.doubleSofa.berthsPerUnit, 2);
    expect(SeatType.singleSofa.berthsPerUnit, 1);
    expect(SeatType.seater.berthsPerUnit, 1);
  });
}
