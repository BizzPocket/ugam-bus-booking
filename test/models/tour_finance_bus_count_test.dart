import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_finance.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_pnl.dart';

Tour _tour({List<Bus> buses = const []}) => Tour(
      id: 't1',
      title: 'Ambaji',
      fromCity: 'Surat',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 3, 1),
      pricePerSeat: 0,
      status: TourStatus.completed,
      buses: buses,
    );

void main() {
  test(
      'an archived tour with no roster in memory uses the fetched bus count, '
      'not "0 buses"', () {
    final tf = TourFinance.from(_tour(), TripPnl.zero, busCount: 3);
    expect(tf.buses, 3);
  });

  test('a loaded roster always wins over the fetched count', () {
    final tf = TourFinance.from(
      _tour(buses: [Bus(id: 'b1', name: 'A', busType: 'Sleeper')]),
      TripPnl.zero,
      busCount: 5,
    );
    expect(tf.buses, 1);
  });

  test('no roster and no count is still 0', () {
    expect(TourFinance.from(_tour(), TripPnl.zero).buses, 0);
  });
}
