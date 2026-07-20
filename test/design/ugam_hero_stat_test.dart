import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_card.dart';
import 'package:occubusbooking/design/components/ugam_hero_stat.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('framed:true (default) wraps in a UgamCard', (tester) async {
    await tester.pumpWidget(_host(
      const UgamHeroStat(label: 'NET', value: '100'),
    ));
    expect(find.byType(UgamCard), findsOneWidget);
    expect(find.text('NET'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('framed:false renders content without its own UgamCard',
      (tester) async {
    await tester.pumpWidget(_host(
      const UgamHeroStat(label: 'NET', value: '100', framed: false),
    ));
    expect(find.byType(UgamCard), findsNothing);
    expect(find.text('NET'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });
}
