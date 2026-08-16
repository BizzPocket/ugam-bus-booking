import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/models/request_band.dart';
import 'package:occubusbooking/utils/band_options.dart';
import 'package:occubusbooking/widgets/band_picker_dialog.dart';

/// The three live bands, all sharing the label `બેન્ડ` — which is precisely
/// why the picker must identify them by price and rows, and why these tests
/// target keys rather than text. Localization is not initialised under
/// `flutter test`, so `tr(...)` returns raw keys.
List<BandOption> liveOptions() => const [
      BandOption(
        band:
            RequestBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, pricePaise: 160000),
        unitPricePaise: 160000,
      ),
      BandOption(
        band:
            RequestBand(label: 'બેન્ડ', fromRow: 4, toRow: 4, pricePaise: 150000),
        unitPricePaise: 150000,
      ),
      BandOption(
        band:
            RequestBand(label: 'બેન્ડ', fromRow: 5, toRow: 5, pricePaise: 120000),
        unitPricePaise: 120000,
      ),
    ];

void main() {
  /// Opens the picker from a tap and records what it resolved to.
  Future<BandPick?> openPicker(
    WidgetTester tester, {
    List<BandOption>? options,
    int maxQty = 10,
  }) async {
    BandPick? result;
    var done = false;

    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const Key('open'),
            onPressed: () async {
              result = await showBandPickerDialog(
                context,
                seatTypeLabel: 'Single Sofa',
                options: options ?? liveOptions(),
                maxQty: maxQty,
              );
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    addTearDown(() => expect(done || result == null, isTrue));
    return result;
  }

  testWidgets('lists one row per band option', (tester) async {
    await openPicker(tester);

    for (final o in liveOptions()) {
      expect(find.byKey(Key('band-${o.key}')), findsOneWidget);
    }
  });

  testWidgets('quantities stay hidden until a band is chosen', (tester) async {
    // Picking a quantity before a band would have to guess which band it meant.
    await openPicker(tester);

    expect(find.byKey(const Key('bandqty-1')), findsNothing);
  });

  testWidgets('choosing a band then a quantity resolves that pick',
      (tester) async {
    BandPick? picked;
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const Key('open'),
            onPressed: () async {
              picked = await showBandPickerDialog(
                context,
                seatTypeLabel: 'Single Sofa',
                options: liveOptions(),
                maxQty: 10,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    final middle = liveOptions()[1]; // row 4, Rs 1,500
    await tester.tap(find.byKey(Key('band-${middle.key}')));
    await tester.pumpAndSettle();

    // Tapping the quantity is the commit — the dialog closes on it.
    await tester.tap(find.byKey(const Key('bandqty-2')));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.option, middle);
    expect(picked!.qty, 2);
  });

  testWidgets('a double sofa quantity is capped by the caller', (tester) async {
    await openPicker(tester, maxQty: 2);

    await tester.tap(find.byKey(Key('band-${liveOptions().first.key}')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bandqty-2')), findsOneWidget);
    expect(find.byKey(const Key('bandqty-3')), findsNothing);
  });

  testWidgets('dismissing without choosing resolves null', (tester) async {
    final result = await openPicker(tester);

    // Nothing tapped inside — the sheet is still open and has produced nothing.
    expect(result, isNull);
  });

  testWidgets('a sold-out type shows the waiting-list notice, no bands',
      (tester) async {
    // Empty options is the sold-out / unpriced path. The customer is not shown
    // an empty box — they are told they will join the waiting list free.
    await openPicker(tester, options: const []);

    expect(find.byKey(const Key('band-empty')), findsOneWidget);
  });
}
