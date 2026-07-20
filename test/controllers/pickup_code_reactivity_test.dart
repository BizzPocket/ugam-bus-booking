import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/pickup_controller.dart';

/// [PickupController.codeFor] is called from inside an `Obx` on every screen
/// that renders the admin-facing pickup CODE tag (occupant sheet, requests,
/// collection). GetX throws "improper use of a GetX" when the closure reads NO
/// observable, so `codeFor` must touch the reactive `all` list on EVERY path —
/// including the early-outs where there is nothing to look up.
void main() {
  setUp(() => Get.put(PickupController()));
  tearDown(Get.reset);

  Widget wrap(String? id) => MaterialApp(
    home: Obx(() {
      final code = Get.find<PickupController>().codeFor(id);
      return Text(code ?? '-');
    }),
  );

  testWidgets('codeFor(null) inside Obx registers a dependency', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(null));
    expect(tester.takeException(), isNull);
  });

  testWidgets('codeFor(unknown id) inside Obx registers a dependency', (
    tester,
  ) async {
    await tester.pumpWidget(wrap('no-such-pickup-id'));
    expect(tester.takeException(), isNull);
  });
}
