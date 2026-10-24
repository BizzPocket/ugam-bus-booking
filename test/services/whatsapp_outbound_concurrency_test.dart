// Perf round 2: per-rider chart renders are capped at 2 in flight (each is an
// ~8.7 MB bitmap allocated twice on Android; 5 at once peaked above 80 MB on a
// 2–3 GB phone). The cap must not change what is sent: send ORDER follows the
// roster, and a rider whose chart fails is still reported by id with the
// renderer's reason.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/chart_footer.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/whatsapp_cloud_service.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';
import 'package:shared_preferences/shared_preferences.dart';

Tour _tour(int riders) {
  final layout = BusLayout.generate(busType: BusType.seater, totalSeats: 20);
  final cells = layout.grid.where((c) => c.hasSeat).toList();
  return Tour(
    id: 't1',
    title: 'Dwarka',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 11, 1),
    pricePerSeat: 1500,
    buses: [
      Bus(id: 'b1', name: 'Bus 1', tourId: 't1', busType: 'Seater', layout: layout),
    ],
    passengers: [
      for (var i = 0; i < riders; i++)
        Passenger(
          id: 'p$i',
          tourId: 't1',
          name: 'Rider $i',
          phone: '98765432${i.toString().padLeft(2, '0')}',
          assignedSeats: [SeatAssignment(busId: 'b1', seatId: cells[i].seatId!)],
        ),
    ],
  );
}

class _FakeCloud extends WhatsAppCloudService {
  final sent = <WaMessage>[];
  List<String>? sentIds;

  @override
  Future<String> uploadSigned({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
    int ttlSeconds = 0,
  }) async =>
      'https://signed/$path';

  @override
  Future<WaSendResult> send(
    List<WaMessage> messages, {
    List<String>? passengerIds,
  }) async {
    sent.addAll(messages);
    sentIds = passengerIds;
    return WaSendResult(
      sent: messages.length,
      failed: 0,
      results: [
        for (var i = 0; i < messages.length; i++)
          WaRecipientResult(
            to: messages[i].to,
            ok: true,
            passengerId: passengerIds?[i],
          ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default cap is 2', () {
    expect(WhatsAppOutbound.defaultChartConcurrency, 2);
  });

  test('never more than 2 chart renders in flight; order + failures intact',
      () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final renderOrder = <String>[];
    Future<List<Uint8List>> render({
      required Tour tour,
      required Passenger passenger,
      required ChartFooter footer,
    }) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      renderOrder.add(passenger.id);
      // Uneven render times so completion order differs from roster order.
      await Future<void>.delayed(
          Duration(milliseconds: passenger.id == 'p0' ? 20 : 2));
      inFlight--;
      if (passenger.id == 'p3') throw StateError('raster OOM');
      return [Uint8List.fromList(List.filled(64, 1))];
    }

    final cloud = _FakeCloud();
    final progress = <int>[];
    final res = await WhatsAppOutbound(cloud: cloud, chartImages: render)
        .sendSeatAllocations(
      tour: _tour(7),
      onProgress: (done, _) => progress.add(done),
    );

    expect(maxInFlight, 2);
    expect(renderOrder, ['p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6']);
    // Messages go out in ROSTER order, the failed rider left out.
    expect(cloud.sentIds, ['p0', 'p1', 'p2', 'p4', 'p5', 'p6']);
    expect(cloud.sent.map((m) => m.headerImageUrl),
        everyElement(startsWith('https://signed/t1/')));
    // The chart failure is reported by passenger, with the real reason.
    final failed = res.results.where((r) => !r.ok).toList();
    expect(failed, hasLength(1));
    expect(failed.single.passengerId, 'p3');
    expect(failed.single.error, contains('raster OOM'));
    expect(res.sent, 6);
    expect(progress, [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('an explicit concurrency is still honoured', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    Future<List<Uint8List>> render({
      required Tour tour,
      required Passenger passenger,
      required ChartFooter footer,
    }) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      inFlight--;
      return [Uint8List.fromList(List.filled(64, 1))];
    }

    await WhatsAppOutbound(cloud: _FakeCloud(), chartImages: render)
        .sendSeatAllocations(tour: _tour(5), concurrency: 1);
    expect(maxInFlight, 1);
  });
}
