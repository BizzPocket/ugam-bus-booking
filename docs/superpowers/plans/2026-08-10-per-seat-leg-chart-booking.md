# Per-Seat Legs in the Customer Seat Chart — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one chart booking carry passengers on different legs — 4 going, 2 coming back — instead of forcing a single `TripType` onto the whole basket.

**Architecture:** The leg moves from a screen-level variable and a scalar RPC parameter to a field on each picked seat. `PartyIntent` gains three bucket counts; `autoPick` runs one pass per bucket; `ChartBasket` stores a leg beside each seat's berth count; `ChartPick.toClaimMap()` emits it; and migration 089 extends the four chart RPCs to read a per-seat leg, falling back to `p_leg` so builds already on the Play Store behave exactly as they do today.

**Tech Stack:** Flutter/Dart, GetX navigation, easy_localization (en/gu/hi), Supabase Postgres RPCs, flutter_test.

**Spec:** [`docs/superpowers/specs/2026-08-10-per-seat-leg-chart-booking-design.md`](../specs/2026-08-10-per-seat-leg-chart-booking-design.md)

## Global Constraints

- **Flutter is not on PATH.** Use `C:/src/flutter/bin/flutter` for every `flutter` / `dart` command.
- **`lib/utils/*` is pure Dart.** No `package:flutter` imports in `party_fit.dart`, `seat_autopick.dart`, `chart_selection.dart`, `chart_basket.dart`. Tests for these must not need `pumpWidget`.
- **All three locales change together.** Any new `tr()` key must be added to `assets/translations/en.json`, `gu.json` and `hi.json` in the same commit. A missing key renders as the raw key string in the UI.
- **Widget tests calling `plural()` must `Localization.load` a locale in `setUpAll`** or they throw `LateInitializationError`. `tr()` is safe without it.
- **A concurrent agent edits this working tree.** Before believing any `flutter analyze` or `flutter test` failure, re-run it once.
- **Do not deploy migrations.** Migration 089 is written to `supabase/migrations/` and committed only. Migrations are applied by hand, one file at a time, by the repo owner.
- **089 depends on 067 and 068, which are staged but NOT deployed.** Task 8 must state this in the migration header, not silently assume it.
- **Berth cap is 6** (`SeatSelectionScreen._maxSeats`). It counts berths, not cells. Mixed legs must not widen the gap between it and migration 048's `jsonb_array_length(p_seats) > 6` cell cap.
- **Customer chart tile density is a documented exception** to the cockpit-density rule and applies only to `ChartSeatMetrics`. Do not touch shared spacing tokens.
- **`TripType.storageKey` is `name`** — the exact strings `roundTrip`, `outboundOnly`, `returnOnly`. The DB column stores these; never invent new spellings.

---

## File Structure

**Created:**
- `supabase/migrations/089_per_seat_leg_chart_claim.sql` — per-seat leg in the four chart RPCs.
- `test/utils/seat_autopick_legs_test.dart` — the three-pass picker.
- `test/utils/chart_basket_legs_test.dart` — basket entries carrying a leg.

**Modified:**
- `lib/utils/party_fit.dart` — `PartyIntent` becomes three buckets; `hasLadies` deleted.
- `lib/utils/seat_autopick.dart` — three passes, `AutoPickResult`, `hasLadies` param deleted.
- `lib/utils/chart_basket.dart` — value type gains a leg.
- `lib/utils/chart_selection.dart` — `ChartPick.leg`; grouping by leg.
- `lib/services/seat_chart_booking_service.dart` — `BusClaim.toPayload` carries per-seat legs.
- `lib/screens/party_gate_screen.dart` — ladies question out, split block in.
- `lib/screens/seat_selection_screen.dart` — view tabs, basket survival, per-pick pricing, sofa rule.
- `lib/screens/seat_booking_confirm_screen.dart` — leg becomes derived, not passed.
- `lib/widgets/chart_summary_bar.dart` — per-leg shortfall.
- `assets/translations/{en,gu,hi}.json` — gate and summary strings.
- `test/screens/party_gate_screen_test.dart`, `test/utils/seat_autopick_test.dart`, `test/screens/seat_selection_prefill_test.dart`, `test/screens/seat_selection_sharing_test.dart` — updated, not deleted.

---

## Task 1: Remove the ladies question

The gate collects `hasLadies`, threads it through `PartyIntent` into `autoPick` — and `autoPick` never reads it. Delete the whole path. This lands first because it shrinks the type every later task touches.

**Files:**
- Modify: `lib/utils/party_fit.dart:24-49`
- Modify: `lib/utils/seat_autopick.dart:241-248`
- Modify: `lib/screens/party_gate_screen.dart:36-121`
- Modify: `lib/screens/seat_selection_screen.dart:185-192`
- Modify: `assets/translations/{en,gu,hi}.json` (remove `party_gate.ladies_q`)
- Test: `test/screens/party_gate_screen_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `PartyIntent({required int people, bool shareOk = true})` — `hasLadies` gone. `autoPick({required List<Bus> buses, required Map<String, SeatAvailability> availability, required TripType leg, required int people, bool shareOk = true})`.

- [ ] **Step 1: Update the gate test to assert the question is gone**

In `test/screens/party_gate_screen_test.dart`, replace the `ladiesKey` expectation in the first test and delete the `hasLadies` assertions:

```dart
  testWidgets('it shows both questions immediately, with no loading',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(PartyGateScreen.peopleKey), findsOneWidget);
    expect(find.byKey(PartyGateScreen.shareKey), findsOneWidget);
  });

  testWidgets('it no longer asks about ladies', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('party_ladies')),
      findsNothing,
      reason: 'the picker never read the answer, so the question was a tax',
    );
  });
```

Then in the test named `'the three answers reach the chart'`, rename it to `'the answers reach the chart'` and delete the `answer(tester, PartyGateScreen.ladiesKey, true);` line and the `expect(captured!.hasLadies, isTrue);` line. In `'sharing defaults to allowed, so the picker is not hobbled'`, delete `expect(captured!.hasLadies, isFalse);`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `C:/src/flutter/bin/flutter test test/screens/party_gate_screen_test.dart`
Expected: FAIL — `party_ladies` is still found, and `hasLadies` no longer compiles once step 3 lands. At this step the failure is the `findsNothing` assertion.

- [ ] **Step 3: Delete `hasLadies` from `PartyIntent`**

In `lib/utils/party_fit.dart`, replace the class (lines 24-49):

```dart
class PartyIntent {
  /// How many people are travelling. One berth each.
  final int people;

  /// Whether they will share a two-person sofa with a stranger.
  ///
  /// False means half-sofas are never auto-picked and never offered on tap.
  final bool shareOk;

  const PartyIntent({
    required this.people,
    this.shareOk = true,
  });

  /// The default for a customer who reached the chart without the gate (a deep
  /// link, or a returning rider): one traveller, willing to share.
  static const solo = PartyIntent(people: 1);
}
```

- [ ] **Step 4: Delete the unused `hasLadies` parameter from `autoPick`**

In `lib/utils/seat_autopick.dart`, change the signature at line 241:

```dart
List<ChartBusSelection> autoPick({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
  bool shareOk = true,
}) {
```

- [ ] **Step 5: Remove the question from the gate screen**

In `lib/screens/party_gate_screen.dart`: delete `static const ladiesKey = Key('party_ladies');` (line 38), delete `bool _hasLadies = false;` (line 49), delete `hasLadies: _hasLadies,` from the `PartyIntent` construction (line 60), and delete this block from the `ListView` children (lines 100-108):

```dart
                  _Question(c: c, label: tr('party_gate.ladies_q')),
                  const SizedBox(height: UgamSpacing.md),
                  _YesNo(
                    key: PartyGateScreen.ladiesKey,
                    c: c,
                    value: _hasLadies,
                    onChanged: (v) => setState(() => _hasLadies = v),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
```

- [ ] **Step 6: Remove the call-site argument**

In `lib/screens/seat_selection_screen.dart`, in `_prefill()` (line 185), delete the line `hasLadies: widget.intent.hasLadies,`.

- [ ] **Step 7: Remove the translation key from all three locales**

Delete the `"ladies_q"` line from the `"party_gate"` object in `assets/translations/en.json`, `gu.json` and `hi.json`. Nothing else in that object changes.

- [ ] **Step 8: Run the full suite**

Run: `C:/src/flutter/bin/flutter test`
Expected: PASS. If `seat_autopick_test.dart` or `party_fit_test.dart` reference `hasLadies`, delete those arguments — they were always inert.

- [ ] **Step 9: Analyze**

Run: `C:/src/flutter/bin/flutter analyze`
Expected: no errors.

- [ ] **Step 10: Commit**

```bash
git add lib/utils/party_fit.dart lib/utils/seat_autopick.dart lib/screens/party_gate_screen.dart lib/screens/seat_selection_screen.dart assets/translations test/screens/party_gate_screen_test.dart
git commit -m "refactor(chart): drop the ladies question the picker never read"
```

---

## Task 2: `PartyIntent` carries three leg buckets

**Files:**
- Modify: `lib/utils/party_fit.dart`
- Modify: `lib/screens/party_gate_screen.dart`
- Modify: `assets/translations/{en,gu,hi}.json`
- Test: `test/utils/party_fit_test.dart`, `test/screens/party_gate_screen_test.dart`

**Interfaces:**
- Consumes: `PartyIntent` from Task 1.
- Produces:
  ```dart
  PartyIntent({int roundTrip = 0, int outboundOnly = 0, int returnOnly = 0, bool shareOk = true})
  int  get people          // roundTrip + outboundOnly + returnOnly
  bool get isMixed         // more than one bucket non-zero
  int  countFor(TripType)  // the bucket for one leg
  List<TripType> get activeLegs  // non-zero buckets, roundTrip → outboundOnly → returnOnly
  static const solo = PartyIntent(roundTrip: 1)
  ```
  New keys: `PartyGateScreen.bothWaysKey`, `PartyGateScreen.splitKey`, `PartyGateScreen.roundTripKey`, `PartyGateScreen.outboundKey`, `PartyGateScreen.returnKey`.

- [ ] **Step 1: Write the failing model test**

Append to `test/utils/party_fit_test.dart`:

```dart
  group('PartyIntent leg buckets', () {
    test('people is the sum of the three buckets', () {
      const i = PartyIntent(roundTrip: 2, outboundOnly: 2);
      expect(i.people, 4);
    });

    test('a single-bucket party is not mixed', () {
      const i = PartyIntent(roundTrip: 4);
      expect(i.isMixed, isFalse);
      expect(i.activeLegs, [TripType.roundTrip]);
    });

    test('a mixed party lists its legs most-constrained first', () {
      const i = PartyIntent(roundTrip: 2, outboundOnly: 1, returnOnly: 3);
      expect(i.isMixed, isTrue);
      expect(i.activeLegs, [
        TripType.roundTrip,
        TripType.outboundOnly,
        TripType.returnOnly,
      ]);
    });

    test('countFor reads the matching bucket', () {
      const i = PartyIntent(roundTrip: 2, returnOnly: 3);
      expect(i.countFor(TripType.roundTrip), 2);
      expect(i.countFor(TripType.outboundOnly), 0);
      expect(i.countFor(TripType.returnOnly), 3);
    });

    test('solo is one round-trip traveller willing to share', () {
      expect(PartyIntent.solo.people, 1);
      expect(PartyIntent.solo.countFor(TripType.roundTrip), 1);
      expect(PartyIntent.solo.shareOk, isTrue);
    });
  });
```

Add `import 'package:occubusbooking/models/trip_type.dart';` to that file if absent.

- [ ] **Step 2: Run it to verify it fails**

Run: `C:/src/flutter/bin/flutter test test/utils/party_fit_test.dart`
Expected: FAIL — `No named parameter with the name 'roundTrip'`.

- [ ] **Step 3: Implement the buckets**

Replace `PartyIntent` in `lib/utils/party_fit.dart`:

```dart
/// What the customer told the gate before the chart was drawn.
///
/// *** WHY THREE COUNTS AND NOT ONE ***
/// A leg used to be a property of the whole booking: one `TripType` on the
/// screen, one `p_leg` on the RPC. That cannot express the ordinary case of a
/// family where two people stay back with relatives — 4 go, 2 come home. The
/// leg is a property of each PERSON, so the intent counts people per leg.
///
/// Request mode has always worked this way (`RequestLine.leg`); chart mode was
/// the odd one out.
class PartyIntent {
  /// People travelling both ways. Their berth must be free on BOTH legs.
  final int roundTrip;

  /// People taking the outbound bus only.
  final int outboundOnly;

  /// People boarding only for the journey home.
  final int returnOnly;

  /// Whether they will share a two-person sofa with a stranger.
  ///
  /// False means half-sofas are never auto-picked and never offered on tap.
  final bool shareOk;

  const PartyIntent({
    this.roundTrip = 0,
    this.outboundOnly = 0,
    this.returnOnly = 0,
    this.shareOk = true,
  });

  /// Total berths to place. One person, one berth, on whichever legs they take.
  int get people => roundTrip + outboundOnly + returnOnly;

  /// True when this party spans more than one leg — the case that needs a
  /// return tab on the chart and a per-seat leg on the claim.
  bool get isMixed => activeLegs.length > 1;

  int countFor(TripType leg) => switch (leg) {
        TripType.roundTrip => roundTrip,
        TripType.outboundOnly => outboundOnly,
        TripType.returnOnly => returnOnly,
      };

  /// Non-empty buckets, MOST CONSTRAINED FIRST. Round-trip leads because its
  /// berth must be free on both legs, so it has the fewest candidates; letting
  /// a one-way pass take those cells first would strand it.
  List<TripType> get activeLegs => [
        for (final leg in const [
          TripType.roundTrip,
          TripType.outboundOnly,
          TripType.returnOnly,
        ])
          if (countFor(leg) > 0) leg,
      ];

  /// The default for a customer who reached the chart without the gate (a deep
  /// link, or a returning rider): one traveller, both ways, willing to share.
  static const solo = PartyIntent(roundTrip: 1);
}
```

Add `import '../models/trip_type.dart';` if not already present — it is, at line 15.

- [ ] **Step 4: Run the model test to verify it passes**

Run: `C:/src/flutter/bin/flutter test test/utils/party_fit_test.dart`
Expected: PASS.

- [ ] **Step 5: Fix the two call sites so the tree compiles**

In `lib/screens/party_gate_screen.dart` `_continue()`, build the intent from the buckets:

```dart
    final intent = PartyIntent(
      roundTrip: _bothWays ? _people : _roundTrip,
      outboundOnly: _bothWays ? 0 : _outbound,
      returnOnly: _bothWays ? 0 : _return,
      shareOk: _shareOk,
    );
```

In `lib/screens/seat_selection_screen.dart` `_prefill()`, `widget.intent.people` already resolves via the getter — no change needed there yet.

- [ ] **Step 6: Add the gate state fields**

In `_PartyGateScreenState`, alongside `int _people = 1;`:

```dart
  /// True until the customer says otherwise. Most parties travel both ways, so
  /// this is the answer that costs them no extra taps.
  bool _bothWays = true;

  /// The split, used only when [_bothWays] is false. All three start at ZERO —
  /// a pre-filled split is already valid, so the customer could walk straight
  /// past the question this block exists to ask.
  int _roundTrip = 0;
  int _outbound = 0;
  int _return = 0;

  int get _splitTotal => _roundTrip + _outbound + _return;

  /// How many people are still unaccounted for in the split. Negative means
  /// they have assigned more people than the party has.
  int get _unassigned => _people - _splitTotal;

  bool get _canContinue => _bothWays || _unassigned == 0;
```

- [ ] **Step 7: Write the failing gate widget tests**

Append to `test/screens/party_gate_screen_test.dart`:

```dart
  Future<void> setSplit(WidgetTester tester, Key group, int n) async {
    await tester.tap(
      find.descendant(of: find.byKey(group), matching: find.text('$n')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the split block is hidden until the party says it is mixed',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);

    expect(find.byKey(PartyGateScreen.splitKey), findsNothing);

    await answer(tester, PartyGateScreen.bothWaysKey, false);
    expect(find.byKey(PartyGateScreen.splitKey), findsOneWidget);
  });

  testWidgets('everyone both ways sends one round-trip bucket', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await submit(tester);

    expect(captured!.roundTrip, 4);
    expect(captured!.outboundOnly, 0);
    expect(captured!.returnOnly, 0);
    expect(captured!.isMixed, isFalse);
  });

  testWidgets('the split buckets start at zero, not pre-filled', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await submit(tester);

    expect(
      captured,
      isNull,
      reason: 'a zero split does not add up, so continuing must be blocked — '
          'a pre-filled split would let them skip the question entirely',
    );
  });

  testWidgets('a split that adds up reaches the chart', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await setSplit(tester, PartyGateScreen.roundTripKey, 2);
    await setSplit(tester, PartyGateScreen.outboundKey, 2);
    await submit(tester);

    expect(captured!.roundTrip, 2);
    expect(captured!.outboundOnly, 2);
    expect(captured!.people, 4);
    expect(captured!.isMixed, isTrue);
  });

  testWidgets('changing the headline count re-zeroes the split', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await setSplit(tester, PartyGateScreen.roundTripKey, 4);
    await pickPeople(tester, 3);
    await submit(tester);

    expect(
      captured,
      isNull,
      reason: 'a stale split from the old headline must not silently survive',
    );
  });
```

- [ ] **Step 8: Run to verify they fail**

Run: `C:/src/flutter/bin/flutter test test/screens/party_gate_screen_test.dart`
Expected: FAIL — `bothWaysKey` is not defined.

- [ ] **Step 9: Add the keys and the UI**

In `PartyGateScreen`, beside the existing key constants:

```dart
  static const bothWaysKey = Key('party_both_ways');
  static const splitKey = Key('party_split');
  static const roundTripKey = Key('party_split_round');
  static const outboundKey = Key('party_split_go');
  static const returnKey = Key('party_split_return');
```

Replace the `_peopleChips` call site block in `build`'s `ListView` children — after the people chips, before the share question — with:

```dart
                  const SizedBox(height: UgamSpacing.xl),
                  _Question(c: c, label: tr('party_gate.both_ways_q')),
                  const SizedBox(height: UgamSpacing.md),
                  _YesNo(
                    key: PartyGateScreen.bothWaysKey,
                    c: c,
                    value: _bothWays,
                    onChanged: (v) => setState(() {
                      _bothWays = v;
                      _roundTrip = 0;
                      _outbound = 0;
                      _return = 0;
                    }),
                  ),
                  if (!_bothWays) ...[
                    const SizedBox(height: UgamSpacing.lg),
                    Column(
                      key: PartyGateScreen.splitKey,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _splitRow(
                          c,
                          key: PartyGateScreen.roundTripKey,
                          label: tr('party_gate.split_round'),
                          value: _roundTrip,
                          onChanged: (n) => setState(() => _roundTrip = n),
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        _splitRow(
                          c,
                          key: PartyGateScreen.outboundKey,
                          label: tr('party_gate.split_go'),
                          value: _outbound,
                          onChanged: (n) => setState(() => _outbound = n),
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        _splitRow(
                          c,
                          key: PartyGateScreen.returnKey,
                          label: tr('party_gate.split_return'),
                          value: _return,
                          onChanged: (n) => setState(() => _return = n),
                        ),
                        const SizedBox(height: UgamSpacing.sm),
                        // The mismatch is stated in WORDS. A silently dead CTA
                        // teaches the customer nothing about why.
                        if (_unassigned != 0)
                          Text(
                            _unassigned > 0
                                ? tr('party_gate.split_short',
                                    namedArgs: {'n': '$_unassigned'})
                                : tr('party_gate.split_over',
                                    namedArgs: {'n': '${-_unassigned}'}),
                            style: UgamText.caption.copyWith(color: c.ink2),
                          ),
                      ],
                    ),
                  ],
```

Add the row builder as a method on `_PartyGateScreenState`:

```dart
  /// One labelled count row of the split. Offers 0..[_people] because no single
  /// bucket can exceed the party.
  Widget _splitRow(
    UgamColorSet c, {
    required Key key,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
        const SizedBox(height: 6),
        Wrap(
          key: key,
          spacing: UgamSpacing.sm,
          runSpacing: UgamSpacing.sm,
          children: [
            for (var n = 0; n <= _people; n++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged(n);
                },
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  width: 44,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == n ? c.accentFill : c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(
                      color: value == n
                          ? c.accent.withValues(alpha: 0.32)
                          : c.border,
                    ),
                  ),
                  child: Text(
                    '$n',
                    style: UgamText.tabular(
                      UgamText.body.copyWith(
                        color: value == n ? c.accent : c.ink2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
```

In `_peopleChips`, the `onTap` must re-zero the split so a stale answer cannot survive a headline change:

```dart
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _people = n;
                _roundTrip = 0;
                _outbound = 0;
                _return = 0;
              });
            },
```

Gate the CTA in `_continue()`:

```dart
  void _continue() {
    if (!_canContinue) return;
    HapticFeedback.selectionClick();
    ...
```

and disable it visually in `build`'s `bottomNavigationBar`:

```dart
        child: UgamCTA(
          key: PartyGateScreen.continueKey,
          label: tr('party_gate.continue'),
          leadingIcon: Icons.arrow_forward_rounded,
          onPressed: _canContinue ? _continue : null,
        ),
```

If `UgamCTA.onPressed` is non-nullable, pass `_continue` unchanged — the `_canContinue` guard inside it already blocks submission, and the widget test asserts on `captured` being null, not on the button's enabled state.

- [ ] **Step 10: Add the translation keys to all three locales**

`assets/translations/en.json`, inside `"party_gate"`:

```json
    "both_ways_q": "Is everyone travelling both ways?",
    "split_round": "Both ways",
    "split_go": "Going only",
    "split_return": "Coming back only",
    "split_short": "{n} more to place",
    "split_over": "{n} too many",
```

`gu.json`, inside `"party_gate"`:

```json
    "both_ways_q": "બધા બંને બાજુ જાવ-આવ કરશે?",
    "split_round": "બંને બાજુ",
    "split_go": "ફક્ત જવાના",
    "split_return": "ફક્ત પાછા આવવાના",
    "split_short": "હજી {n} બાકી",
    "split_over": "{n} વધારે થયા",
```

`hi.json`, inside `"party_gate"`:

```json
    "both_ways_q": "क्या सभी आना-जाना दोनों करेंगे?",
    "split_round": "दोनों तरफ",
    "split_go": "सिर्फ़ जाना",
    "split_return": "सिर्फ़ वापसी",
    "split_short": "{n} और बाकी",
    "split_over": "{n} ज़्यादा हैं",
```

- [ ] **Step 11: Run the gate tests**

Run: `C:/src/flutter/bin/flutter test test/screens/party_gate_screen_test.dart`
Expected: PASS.

- [ ] **Step 12: Migrate every `PartyIntent(people: N)` construction**

`people` stopped being a constructor parameter and became a derived getter, so every existing construction breaks. Run:

```bash
grep -rn "PartyIntent(people:" lib test
```

Rewrite each hit as `PartyIntent(roundTrip: N)` — the old single-leg meaning was always "everyone, both ways". Known sites: `test/screens/seat_selection_prefill_test.dart` and `test/screens/seat_selection_sharing_test.dart`. Reads of `intent.people` are unchanged; the getter keeps working.

- [ ] **Step 13: Run the full suite and analyze**

Run: `C:/src/flutter/bin/flutter test && C:/src/flutter/bin/flutter analyze`
Expected: PASS, no analyzer errors.

- [ ] **Step 14: Commit**

```bash
git add lib/utils/party_fit.dart lib/screens/party_gate_screen.dart assets/translations test/utils/party_fit_test.dart test/screens/party_gate_screen_test.dart
git commit -m "feat(chart): the gate asks who travels which leg"
```

---

## Task 3: `autoPick` runs one pass per leg bucket

**Files:**
- Modify: `lib/utils/seat_autopick.dart`
- Create: `test/utils/seat_autopick_legs_test.dart`
- Modify: `test/utils/seat_autopick_test.dart` (call-site updates only)

**Interfaces:**
- Consumes: `PartyIntent.activeLegs`, `PartyIntent.countFor`, `PartyIntent.shareOk` from Task 2.
- Produces:
  ```dart
  class AutoPickResult {
    final List<ChartBusSelection> selections;   // may hold picks for several legs
    final Map<TripType, int> shortfall;         // berths NOT placed, per bucket
    bool get isEmpty;
    bool get hasShortfall;
  }
  AutoPickResult autoPick({
    required List<Bus> buses,
    required Map<String, SeatAvailability> availability,
    required PartyIntent intent,
  })
  ```
  `ChartPick` gains `leg` in Task 4; until then the picker records legs in a parallel structure. **To avoid that awkwardness, Task 4's `ChartPick.leg` field is added HERE, in step 3, and Task 4 only changes what is done with it.**

- [ ] **Step 1: Add `leg` to `ChartPick` first — the picker cannot express its output without it**

In `lib/utils/chart_selection.dart`, extend `ChartPick`:

```dart
class ChartPick {
  final SeatCell cell;
  final int berths;

  /// Which legs this berth is taken for. A chart booking used to carry ONE leg
  /// for the whole basket; it is a property of the person in the seat, not of
  /// the booking, which is why a party where two stay back could not be
  /// expressed at all before this field existed.
  final TripType leg;

  const ChartPick({
    required this.cell,
    required this.berths,
    this.leg = TripType.roundTrip,
  });

  SeatType get seatType => cell.seatType!;
  String get seatId => cell.seatId!;

  bool get isWholeDouble => seatType == SeatType.doubleSofa && berths >= 2;

  Map<String, dynamic> toClaimMap() =>
      {'seatId': seatId, 'berths': berths, 'leg': leg.storageKey};
}
```

The default keeps every existing construction call compiling and behaving as today.

- [ ] **Step 2: Write the failing three-pass tests**

Create `test/utils/seat_autopick_legs_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';
import 'package:occubusbooking/utils/party_fit.dart';
import 'package:occubusbooking/utils/seat_autopick.dart';

/// The picker fills one LEG BUCKET at a time.
///
/// A party is no longer "4 people on one leg". It is up to three counts —
/// both-ways, going-only, coming-back-only — and each needs its own pass,
/// because availability is leg-scoped and a round-trip berth must be free on
/// BOTH legs while a one-way berth need only be free on its own.
void main() {
  SeatCell single(String id, int row, {int col = 0, SeatPosition? pos}) =>
      SeatCell(
        row: row,
        col: col,
        seatType: SeatType.singleSofa,
        position: pos ?? SeatPosition.upper,
        seatId: id,
      );

  Bus bus({required String id, required List<SeatCell> cells}) => Bus(
        id: id,
        name: 'Bus $id',
        busType: 'Sleeper',
        pricePerSeat: 1200,
        singleSofaPrice: 1400,
        doubleSofaPrice: 2200,
        layout: BusLayout(
          rows: cells.map((c) => c.row).fold<int>(0, (a, c) => a > c ? a : c) + 1,
          cols: SeatGridCols.count,
          grid: cells,
        ),
      );

  List<ChartPick> allPicks(AutoPickResult r) =>
      [for (final s in r.selections) ...s.picks];

  Bus sixSeater(String id) => bus(id: id, cells: [
        for (var r = 0; r < 3; r++) ...[
          single('SU${r + 1}', r),
          single('SL${r + 1}', r, col: 1, pos: SeatPosition.lower),
        ],
      ]);

  group('it fills each bucket', () {
    test('a single-bucket party behaves exactly as before', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 4),
      );

      expect(allPicks(r), hasLength(4));
      expect(r.hasShortfall, isFalse);
      expect(
        allPicks(r).every((p) => p.leg == TripType.roundTrip),
        isTrue,
      );
    });

    test('a mixed party stamps each pick with its own leg', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, outboundOnly: 2),
      );

      final picks = allPicks(r);
      expect(picks, hasLength(4));
      expect(
        picks.where((p) => p.leg == TripType.roundTrip),
        hasLength(2),
      );
      expect(
        picks.where((p) => p.leg == TripType.outboundOnly),
        hasLength(2),
      );
    });

    test('no cell is used by two passes', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, outboundOnly: 2, returnOnly: 2),
      );

      final ids = allPicks(r).map((p) => p.seatId).toList();
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'the customer picker never puts two different people on one '
            'berth, even where disjoint legs would technically allow it',
      );
    });

    test('a bucket that cannot be seated reports its own shortfall', () {
      // Two seats, but the party needs two round-trip AND two return-only.
      final b = bus(id: 'a', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);
      final r = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, returnOnly: 2),
      );

      expect(
        allPicks(r),
        hasLength(2),
        reason: 'the round-trip pass succeeded and its picks must survive',
      );
      expect(r.shortfall[TripType.returnOnly], 2);
      expect(r.shortfall.containsKey(TripType.roundTrip), isFalse);
    });

    test('everyone fitting means an empty shortfall', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1, outboundOnly: 1),
      );
      expect(r.shortfall, isEmpty);
      expect(r.hasShortfall, isFalse);
    });

    test('an empty party picks nothing', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(),
      );
      expect(r.isEmpty, isTrue);
      expect(r.shortfall, isEmpty);
    });
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `C:/src/flutter/bin/flutter test test/utils/seat_autopick_legs_test.dart`
Expected: FAIL — `AutoPickResult` is not defined.

- [ ] **Step 4: Implement `AutoPickResult` and the three-pass `autoPick`**

In `lib/utils/seat_autopick.dart`, add the import `import 'party_fit.dart';` and replace `autoPick` (lines 231-291) with:

```dart
/// What the picker managed to do, and what it could not.
///
/// The old signature returned a bare list and said "no room" by returning it
/// empty. That cannot express the ordinary mixed-party outcome where the
/// outbound leg fits and the return leg does not — the go picks are real and
/// must survive, while the customer is told plainly about the gap.
class AutoPickResult {
  final List<ChartBusSelection> selections;

  /// Berths the picker could NOT place, per bucket. Absent key means that
  /// bucket was fully seated.
  final Map<TripType, int> shortfall;

  const AutoPickResult({
    this.selections = const [],
    this.shortfall = const {},
  });

  bool get isEmpty => selections.isEmpty;
  bool get hasShortfall => shortfall.isNotEmpty;
}

/// Propose seats for a party, one LEG BUCKET at a time.
///
/// Buckets are filled in [PartyIntent.activeLegs] order — round-trip first,
/// because its berth must be free on BOTH legs and therefore has the fewest
/// candidates. Letting a one-way pass take those cells first would strand it.
///
/// A cell taken by one pass is invisible to the next. Disjoint legs could in
/// principle share a berth (see `seating_engine.dart`), but the customer picker
/// deliberately never does: one tile is always one person, which keeps the
/// chart honest and keeps the claim payload free of duplicate seat ids.
AutoPickResult autoPick({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
  required PartyIntent intent,
}) {
  if (intent.people <= 0 || buses.isEmpty) return const AutoPickResult();

  // seatIds already committed, keyed as availability is: busId + seatId.
  final claimed = <String>{};
  final byBus = <String, List<ChartPick>>{};
  final shortfall = <TripType, int>{};

  for (final leg in intent.activeLegs) {
    final want = intent.countFor(leg);
    final placed = _pickOneLeg(
      buses: buses,
      availability: availability,
      leg: leg,
      people: want,
      shareOk: intent.shareOk,
      claimed: claimed,
    );

    var covered = 0;
    for (final selection in placed) {
      for (final pick in selection.picks) {
        claimed.add(SeatAvailability.keyFor(selection.bus.id, pick.seatId));
        covered += pick.berths;
        (byBus[selection.bus.id] ??= []).add(pick);
      }
    }
    if (covered < want) shortfall[leg] = want - covered;
  }

  // Rebuild selections in bus tab order so the chart's bus tabs and the
  // checkout list agree on ordering.
  final selections = <ChartBusSelection>[
    for (final bus in buses)
      if (byBus[bus.id] != null)
        ChartBusSelection(bus: bus, picks: byBus[bus.id]!),
  ];

  return AutoPickResult(selections: selections, shortfall: shortfall);
}

/// One bucket's worth of picking. Returns whatever it could place — partial is
/// allowed here, because the caller reports the gap per leg rather than
/// throwing the whole proposal away.
List<ChartBusSelection> _pickOneLeg({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
  required bool shareOk,
  required Set<String> claimed,
}) {
  if (people <= 0) return const [];

  // ── 1. Whole bucket on ONE bus, in tab order ─────────────────────────────
  for (final bus in buses) {
    final packing = _packBus(
      bus: bus,
      availability: availability,
      leg: leg,
      people: people,
      shareOk: shareOk,
      claimed: claimed,
    );
    if (packing != null) {
      return [ChartBusSelection(bus: bus, picks: packing.picksFor(leg))];
    }
  }

  // ── 2. Split, only because nothing else fits ─────────────────────────────
  final out = <ChartBusSelection>[];
  final used = <String>{...claimed};
  var remaining = people;

  for (final bus in buses) {
    if (remaining <= 0) break;
    for (var want = remaining; want >= 1; want--) {
      final packing = _packBus(
        bus: bus,
        availability: availability,
        leg: leg,
        people: want,
        shareOk: shareOk,
        claimed: used,
      );
      if (packing == null) continue;
      final picks = packing.picksFor(leg);
      out.add(ChartBusSelection(bus: bus, picks: picks));
      for (final p in picks) {
        used.add(SeatAvailability.keyFor(bus.id, p.seatId));
      }
      remaining -= packing.covered;
      break;
    }
  }

  return out;
}
```

- [ ] **Step 5: Teach `_packBus` and `_optionsFor` to skip claimed cells, and `_Packing` to stamp the leg**

In `lib/utils/seat_autopick.dart`, change `_Packing.picks` (lines 67-69) to a leg-aware method:

```dart
  List<ChartPick> picksFor(TripType leg) => [
        for (final o in options)
          ChartPick(cell: o.cell, berths: o.berths, leg: leg),
      ];
```

Add a `claimed` parameter to `_optionsFor` and skip those cells:

```dart
List<_Option> _optionsFor({
  required Bus bus,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required bool shareOk,
  required Set<String> claimed,
}) {
  final out = <_Option>[];
  for (final cell in bus.layout?.grid ?? const <SeatCell>[]) {
    if (!cell.hasSeat) continue;
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) continue;
    // An earlier leg's pass already took this berth. One tile, one person.
    if (claimed.contains(SeatAvailability.keyFor(bus.id, seatId))) continue;
    ...
```

The rest of `_optionsFor` is unchanged. Thread `claimed` through `_packBus`:

```dart
_Packing? _packBus({
  required Bus bus,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
  required bool shareOk,
  required Set<String> claimed,
}) {
  if (people <= 0) return null;
  final options = _optionsFor(
    bus: bus,
    availability: availability,
    leg: leg,
    shareOk: shareOk,
    claimed: claimed,
  );
  ...
```

- [ ] **Step 6: Run the new tests**

Run: `C:/src/flutter/bin/flutter test test/utils/seat_autopick_legs_test.dart`
Expected: PASS.

- [ ] **Step 7: Update the existing picker tests to the new signature**

In `test/utils/seat_autopick_test.dart`, every `autoPick(buses: …, availability: …, leg: X, people: N, shareOk: S)` call becomes:

```dart
      final r = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1),
      );
```

with `leg: TripType.outboundOnly` cases becoming `PartyIntent(outboundOnly: N)`, and `shareOk: false` becoming `PartyIntent(roundTrip: N, shareOk: false)`. Update the two local helpers to take the result:

```dart
  int berthsOf(AutoPickResult r) => r.selections.fold<int>(
        0,
        (sum, s) => sum + s.picks.fold<int>(0, (n, p) => n + p.berths),
      );

  Set<String> seatIdsOf(AutoPickResult r) => {
        for (final s in r.selections)
          for (final p in s.picks) p.seatId,
      };
```

Assertions of the form `expect(picks, hasLength(1))` become `expect(r.selections, hasLength(1))`, and `picks.single.bus.id` becomes `r.selections.single.bus.id`. Assertions that the picker returns nothing (`expect(picks, isEmpty)`) become `expect(r.isEmpty, isTrue)`.

Add `import 'package:occubusbooking/utils/party_fit.dart';`.

- [ ] **Step 8: Run the full suite and analyze**

Run: `C:/src/flutter/bin/flutter test && C:/src/flutter/bin/flutter analyze`
Expected: PASS. `seat_selection_screen.dart` will fail to compile at `_prefill` — fix it in this step by adapting the call:

```dart
    final proposed = autoPick(
      buses: _buses,
      availability: _availability,
      intent: widget.intent,
    );

    setState(() {
      _shortfall = proposed.shortfall;
      for (final selection in proposed.selections) {
        for (final pick in selection.picks) {
          _basket.setBerths(
            busId: selection.bus.id,
            seatId: pick.seatId,
            berths: pick.berths,
            leg: pick.leg,
          );
        }
      }
    });
```

`setBerths`'s `leg` parameter arrives in Task 4 — until then, drop the `leg:` argument and add the field `Map<TripType, int> _shortfall = const {};` replacing `bool _noRoom = false;`, with `_noRoom` usages becoming `_shortfall.isNotEmpty`.

- [ ] **Step 9: Commit**

```bash
git add lib/utils/seat_autopick.dart lib/utils/chart_selection.dart lib/screens/seat_selection_screen.dart test/utils/seat_autopick_test.dart test/utils/seat_autopick_legs_test.dart
git commit -m "feat(chart): autoPick fills one leg bucket at a time"
```

---

## Task 4: The basket and the claim payload carry the leg

**Files:**
- Modify: `lib/utils/chart_basket.dart`
- Modify: `lib/utils/chart_selection.dart`
- Modify: `lib/screens/seat_selection_screen.dart` (basket reads/writes)
- Create: `test/utils/chart_basket_legs_test.dart`
- Modify: `test/utils/double_sofa_leg_split_test.dart` if it constructs `ChartPick`

**Interfaces:**
- Consumes: `ChartPick.leg` from Task 3.
- Produces:
  ```dart
  typedef BasketEntry = ({int berths, TripType leg});
  typedef BusPicks = Map<String, BasketEntry>;
  void ChartBasket.setBerths({required String busId, required String seatId, required int berths, TripType leg = TripType.roundTrip})
  BasketEntry? ChartBasket.entryFor({required String busId, required String seatId})
  int ChartBasket.berthsFor({required String busId, required String seatId})     // unchanged signature
  int ChartBasket.berthsForLeg(TripType leg)                                      // berths in one bucket
  List<RequestLine> requestLinesFor({required List<ChartPick> picks})             // leg param REMOVED
  List<SeatAssignment> assignmentsFor({required List<ChartPick> picks, required String busId})  // leg param REMOVED
  TripType summaryLegOf(List<ChartPick> picks)
  ```

- [ ] **Step 1: Write the failing basket and selection tests**

Create `test/utils/chart_basket_legs_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_basket.dart';
import 'package:occubusbooking/utils/chart_selection.dart';

/// A basket entry is a PERSON's berth on a PERSON's leg.
///
/// The basket used to be `seatId -> berths`, which silently assumed every seat
/// in it shared one trip type. That assumption is what made "4 go, 2 come back"
/// impossible to express.
void main() {
  SeatCell cell(String id, {SeatType type = SeatType.singleSofa}) => SeatCell(
        row: 0,
        col: 0,
        seatType: type,
        position: SeatPosition.lower,
        seatId: id,
      );

  group('ChartBasket', () {
    test('it stores a leg beside the berth count', () {
      final b = ChartBasket();
      b.setBerths(
        busId: 'bus1',
        seatId: 'SU1',
        berths: 1,
        leg: TripType.outboundOnly,
      );

      expect(b.berthsFor(busId: 'bus1', seatId: 'SU1'), 1);
      expect(
        b.entryFor(busId: 'bus1', seatId: 'SU1')!.leg,
        TripType.outboundOnly,
      );
    });

    test('it defaults to round-trip so untouched call sites are unchanged', () {
      final b = ChartBasket();
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 1);
      expect(b.entryFor(busId: 'bus1', seatId: 'SU1')!.leg, TripType.roundTrip);
    });

    test('berthsForLeg counts one bucket across every bus', () {
      final b = ChartBasket();
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 2);
      b.setBerths(
        busId: 'bus2',
        seatId: 'SU1',
        berths: 1,
        leg: TripType.outboundOnly,
      );

      expect(b.berthsForLeg(TripType.roundTrip), 2);
      expect(b.berthsForLeg(TripType.outboundOnly), 1);
      expect(b.berthsForLeg(TripType.returnOnly), 0);
      expect(b.totalBerths, 3);
    });

    test('setting zero berths removes the entry and its leg', () {
      final b = ChartBasket();
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 1);
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 0);
      expect(b.entryFor(busId: 'bus1', seatId: 'SU1'), isNull);
      expect(b.isEmpty, isTrue);
    });
  });

  group('chart_selection', () {
    test('the claim payload carries each seat own leg', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1),
        ChartPick(
          cell: cell('SU2'),
          berths: 1,
          leg: TripType.outboundOnly,
        ),
      ];

      expect(claimPayload(picks), [
        {'seatId': 'SU1', 'berths': 1, 'leg': 'roundTrip'},
        {'seatId': 'SU2', 'berths': 1, 'leg': 'outboundOnly'},
      ]);
    });

    test('request lines split by leg, not just by type', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1),
        ChartPick(
          cell: cell('SU2'),
          berths: 1,
          leg: TripType.outboundOnly,
        ),
      ];

      final lines = requestLinesFor(picks: picks);
      expect(lines, hasLength(2));
      expect(
        lines.map((l) => l.leg).toSet(),
        {TripType.roundTrip, TripType.outboundOnly},
      );
      expect(lines.every((l) => l.qty == 1), isTrue);
    });

    test('same type and same leg still collapse into one line', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1),
        ChartPick(cell: cell('SU2'), berths: 1),
      ];
      final lines = requestLinesFor(picks: picks);
      expect(lines, hasLength(1));
      expect(lines.single.qty, 2);
    });

    test('assignments are stamped per pick', () {
      final picks = [
        ChartPick(
          cell: cell('DU1', type: SeatType.doubleSofa),
          berths: 2,
          leg: TripType.returnOnly,
        ),
      ];
      final out = assignmentsFor(picks: picks, busId: 'bus1');
      expect(out, hasLength(2));
      expect(out.every((a) => a.leg == TripType.returnOnly), isTrue);
    });

    test('the summary leg is round-trip whenever the legs are mixed', () {
      expect(
        summaryLegOf([
          ChartPick(cell: cell('SU1'), berths: 1, leg: TripType.outboundOnly),
          ChartPick(cell: cell('SU2'), berths: 1, leg: TripType.returnOnly),
        ]),
        TripType.roundTrip,
      );
      expect(
        summaryLegOf([
          ChartPick(cell: cell('SU1'), berths: 1, leg: TripType.outboundOnly),
        ]),
        TripType.outboundOnly,
      );
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `C:/src/flutter/bin/flutter test test/utils/chart_basket_legs_test.dart`
Expected: FAIL — `setBerths` has no `leg` parameter.

- [ ] **Step 3: Widen the basket value type**

In `lib/utils/chart_basket.dart`, add `import '../models/trip_type.dart';` and replace the typedef and the three affected members:

```dart
/// One picked cell: how many berths, and which legs the person in it travels.
///
/// The leg lives HERE rather than on the screen because it is a property of the
/// person, not of the booking. A basket keyed only by berth count silently
/// forced every seat onto one trip type.
typedef BasketEntry = ({int berths, TripType leg});

/// Seats picked on one bus: `seatId -> entry`.
typedef BusPicks = Map<String, BasketEntry>;

class ChartBasket {
  final Map<String, BusPicks> _byBus = {};

  /// Berths of [seatId] on [busId] currently in the basket. Zero when untouched.
  int berthsFor({required String busId, required String seatId}) =>
      _byBus[busId]?[seatId]?.berths ?? 0;

  /// The whole entry, or null when this cell is not in the basket.
  BasketEntry? entryFor({required String busId, required String seatId}) =>
      _byBus[busId]?[seatId];

  /// Set how many berths of one cell are taken, and on which legs. Zero or less
  /// REMOVES the seat, and emptying a bus removes the bus — an empty bus must
  /// never reach the claim as "a bus with no seats", which the server rejects.
  void setBerths({
    required String busId,
    required String seatId,
    required int berths,
    TripType leg = TripType.roundTrip,
  }) {
    if (berths <= 0) {
      final picks = _byBus[busId];
      if (picks == null) return;
      picks.remove(seatId);
      if (picks.isEmpty) _byBus.remove(busId);
      return;
    }
    (_byBus[busId] ??= {})[seatId] = (berths: berths, leg: leg);
  }

  BusPicks forBus(String busId) => Map<String, BasketEntry>.from(_byBus[busId] ?? {});

  List<String> get busIds => _byBus.keys.toList();

  /// Total people in the basket, across every bus.
  int get totalBerths => _byBus.values
      .expand((picks) => picks.values)
      .fold<int>(0, (sum, e) => sum + e.berths);

  /// Berths taken for ONE leg bucket, across every bus. This is what the sofa
  /// rule and the summary bar count against the gate's per-leg answer.
  int berthsForLeg(TripType leg) => _byBus.values
      .expand((picks) => picks.values)
      .where((e) => e.leg == leg)
      .fold<int>(0, (sum, e) => sum + e.berths);

  bool get isEmpty => _byBus.isEmpty;
  bool get isNotEmpty => !isEmpty;
  bool get spansMultipleBuses => _byBus.length > 1;

  void clearBus(String busId) => _byBus.remove(busId);
  void clear() => _byBus.clear();
}
```

Preserve the existing file header comment above the typedef.

- [ ] **Step 4: Group selections by leg**

In `lib/utils/chart_selection.dart`, replace `requestLinesFor` and `assignmentsFor`, and add `summaryLegOf`:

```dart
/// Collapse picks into request lines, grouped by (seat type, position, LEG), in
/// a stable order. Mirrors the `group by` in `chart_claim_seats`.
///
/// The leg joins the key because two people in the same kind of berth on
/// DIFFERENT legs are two different lines — and are billed differently, since
/// a one-way berth pays half.
List<RequestLine> requestLinesFor({required List<ChartPick> picks}) {
  final counts =
      <String, ({SeatType type, SeatPosition? pos, TripType leg, int qty})>{};
  for (final p in picks) {
    final type = lineTypeFor(p);
    final pos = linePositionFor(p);
    final key = '${type.name}|${pos?.name ?? ''}|${p.leg.name}';
    final prev = counts[key];
    counts[key] = (
      type: type,
      pos: pos,
      leg: p.leg,
      qty: (prev?.qty ?? 0) + 1,
    );
  }
  return [
    for (final v in counts.values)
      RequestLine(seatType: v.type, position: v.pos, qty: v.qty, leg: v.leg),
  ];
}

/// One [SeatAssignment] PER BERTH, each stamped with its own pick's leg.
List<SeatAssignment> assignmentsFor({
  required List<ChartPick> picks,
  required String busId,
}) {
  final out = <SeatAssignment>[];
  for (final p in picks) {
    for (var i = 0; i < p.berths; i++) {
      out.add(SeatAssignment(busId: busId, seatId: p.seatId, leg: p.leg));
    }
  }
  return out;
}

/// The coarse trip type a mixed basket reports as. Round-trip when any pick is
/// round-trip or the legs are mixed, else the single shared value.
///
/// Deliberately the same rule as `summaryTripTypeOf` in `round_trip_combine.dart`
/// — request mode has always derived `booking_requests.trip_type` this way, and
/// two different derivations of one column is how they drift apart.
TripType summaryLegOf(List<ChartPick> picks) {
  if (picks.isEmpty) return TripType.roundTrip;
  if (picks.any((p) => p.leg == TripType.roundTrip)) return TripType.roundTrip;
  final legs = picks.map((p) => p.leg).toSet();
  return legs.length == 1 ? legs.first : TripType.roundTrip;
}
```

- [ ] **Step 5: Run the new tests**

Run: `C:/src/flutter/bin/flutter test test/utils/chart_basket_legs_test.dart`
Expected: PASS.

- [ ] **Step 6: Fix every consumer the type change breaks**

Run: `C:/src/flutter/bin/flutter analyze`

Fix each reported site:
- `lib/screens/seat_selection_screen.dart` `_selectedLowerBerths` and `_total`: `entry.value` becomes `entry.value.berths`.
- `lib/screens/seat_selection_screen.dart` `_picksFor`: build with the stored leg —
  ```dart
      if (cell.hasSeat) {
        out.add(ChartPick(cell: cell, berths: e.value.berths, leg: e.value.leg));
      }
  ```
- `lib/screens/seat_selection_screen.dart` `_prefill`: pass `leg: pick.leg` to `setBerths`.
- Any caller of `requestLinesFor(picks: …, leg: …)` or `assignmentsFor(picks: …, busId: …, leg: …)`: drop the `leg:` argument.

- [ ] **Step 7: Run the full suite**

Run: `C:/src/flutter/bin/flutter test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/utils/chart_basket.dart lib/utils/chart_selection.dart lib/screens/seat_selection_screen.dart test/utils/chart_basket_legs_test.dart
git commit -m "feat(chart): a picked seat carries its own leg"
```

---

## Task 5: The claim payload reaches the server with per-seat legs

**Files:**
- Modify: `lib/services/seat_chart_booking_service.dart`
- Modify: `lib/screens/seat_booking_confirm_screen.dart`
- Test: `test/utils/chart_basket_legs_test.dart` (extend)

**Interfaces:**
- Consumes: `ChartPick.leg`, `claimPayload`, `summaryLegOf` from Task 4.
- Produces: unchanged public method signatures on `SeatChartBookingService`. `leg` arguments become the DERIVED summary rather than a customer choice.

> **Correctness note for the implementer.** `ChartPick.toClaimMap()` now always emits `leg`, so *all four* RPCs — `chart_claim_seats`, `chart_claim_seats_multi`, `chart_hold_seats`, `chart_hold_seats_multi` — receive it whether or not they read it. Until migration 089 lands they will ignore the field and fall back to `p_leg`, which is exactly today's behaviour. That is safe, but it means **the app must keep sending a correct `p_leg`**: the derived summary, not a hardcoded value.

- [ ] **Step 1: Write the failing derivation test**

Append to `test/utils/chart_basket_legs_test.dart`, inside the `chart_selection` group:

```dart
    test('a mixed basket derives round-trip as its coarse leg', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1, leg: TripType.outboundOnly),
        ChartPick(cell: cell('SU2'), berths: 1, leg: TripType.roundTrip),
      ];
      expect(summaryLegOf(picks), TripType.roundTrip);
      expect(
        claimPayload(picks).map((m) => m['leg']),
        ['outboundOnly', 'roundTrip'],
        reason: 'the coarse summary must never overwrite the per-seat truth',
      );
    });
```

- [ ] **Step 2: Run to verify it passes already**

Run: `C:/src/flutter/bin/flutter test test/utils/chart_basket_legs_test.dart`
Expected: PASS — Task 4 delivered both functions. This test exists to pin the invariant before the confirm screen starts depending on it.

- [ ] **Step 3: Derive the leg at the confirm screen instead of receiving it**

In `lib/screens/seat_booking_confirm_screen.dart`, replace the `final TripType leg;` field and its constructor parameter with a derived getter:

```dart
  /// The COARSE trip type this booking reports as, derived from the picks.
  ///
  /// It is no longer passed in: with per-seat legs there is no single customer
  /// answer to pass. `booking_requests.trip_type` has always been a summary in
  /// request mode, and this makes chart mode agree.
  TripType get leg => summaryLegOf([
        for (final s in widget.selections) ...s.picks,
      ]);
```

Add `import '../utils/chart_selection.dart';` if absent. Replace every `widget.leg` in that file with `leg`, and every `tripType: widget.leg` with `tripType: leg`.

- [ ] **Step 4: Stop passing `leg` from the chart**

In `lib/screens/seat_selection_screen.dart` `_continue()`, delete the `leg: _leg,` argument to `SeatBookingConfirmScreen`.

- [ ] **Step 5: Make the leg label honest for a mixed booking**

In `seat_booking_confirm_screen.dart`, `_legLabel()` currently maps one `TripType` to one string. A mixed booking must say so:

```dart
  String _legLabel() {
    final picks = [for (final s in widget.selections) ...s.picks];
    final legs = picks.map((p) => p.leg).toSet();
    if (legs.length > 1) return tr('seat_confirm.leg_mixed');
    switch (legs.isEmpty ? TripType.roundTrip : legs.first) {
      case TripType.roundTrip:
        return tr('seat_pick.leg_round');
      case TripType.outboundOnly:
        return tr('seat_pick.leg_go');
      case TripType.returnOnly:
        return tr('seat_pick.leg_return');
    }
  }
```

- [ ] **Step 6: Add `seat_confirm.leg_mixed` to all three locales**

`en.json` inside `"seat_confirm"`: `"leg_mixed": "Mixed — some one way",`
`gu.json` inside `"seat_confirm"`: `"leg_mixed": "મિશ્ર — કેટલાક એક બાજુ",`
`hi.json` inside `"seat_confirm"`: `"leg_mixed": "मिश्रित — कुछ एक तरफ़",`

- [ ] **Step 7: Run the full suite and analyze**

Run: `C:/src/flutter/bin/flutter test && C:/src/flutter/bin/flutter analyze`
Expected: PASS, no errors.

- [ ] **Step 8: Commit**

```bash
git add lib/services/seat_chart_booking_service.dart lib/screens/seat_booking_confirm_screen.dart lib/screens/seat_selection_screen.dart assets/translations test/utils/chart_basket_legs_test.dart
git commit -m "feat(chart): derive the coarse trip type from the picks"
```

---

## Task 6: The chart's leg pills become view tabs

**Files:**
- Modify: `lib/screens/seat_selection_screen.dart`
- Test: `test/screens/seat_selection_prefill_test.dart`

**Interfaces:**
- Consumes: `PartyIntent.activeLegs`, `ChartBasket.berthsForLeg`, `AutoPickResult.shortfall`.
- Produces: `SeatSelectionScreen.goTabKey`, `SeatSelectionScreen.returnTabKey`; state field `TripType _viewLeg`; method `TripType _bucketForTap()`.

- [ ] **Step 1: Write the failing tab tests**

`test/screens/seat_selection_prefill_test.dart` already defines `harness(List<Bus> buses, {required PartyIntent intent, Map<String, SeatAvailability> availability})`, `bus(busId, threeRows())` and `int selectedBerths(WidgetTester)`. Reuse them; add one more helper and the tests:

```dart
  /// Seat ids currently held, whichever tab is on screen.
  Set<String> selectedSeatIds(WidgetTester tester) => {
        for (final t in tester.widgetList<ChartSeatTile>(
          find.byType(ChartSeatTile),
        ))
          if (t.selectedBerths > 0) t.cell.seatId!,
      };

  testWidgets('a single-leg party sees no tab strip', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip: 2),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(SeatSelectionScreen.returnTabKey), findsNothing);
    expect(find.byKey(SeatSelectionScreen.goTabKey), findsNothing);
  });

  testWidgets('a return-only party sees only the return map', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(returnOnly: 2),
    ));
    await tester.pumpAndSettle();

    expect(
      find.byKey(SeatSelectionScreen.goTabKey),
      findsNothing,
      reason: 'nothing is being filled on the outbound leg',
    );
  });

  testWidgets('a mixed party gets both tabs', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(SeatSelectionScreen.goTabKey), findsOneWidget);
    expect(find.byKey(SeatSelectionScreen.returnTabKey), findsOneWidget);
  });

  testWidgets('switching tabs keeps the selection', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
    ));
    await tester.pumpAndSettle();

    final goSeats = selectedSeatIds(tester);
    expect(goSeats, isNotEmpty);

    await tester.tap(find.byKey(SeatSelectionScreen.returnTabKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SeatSelectionScreen.goTabKey));
    await tester.pumpAndSettle();

    expect(
      selectedSeatIds(tester),
      goSeats,
      reason: 'the tab is a view filter now, not a change of what is bought',
    );
  });

  testWidgets('a round-trip berth shows on BOTH tabs, a one-way berth on one',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
    ));
    await tester.pumpAndSettle();

    final onGo = selectedSeatIds(tester);
    await tester.tap(find.byKey(SeatSelectionScreen.returnTabKey));
    await tester.pumpAndSettle();
    final onReturn = selectedSeatIds(tester);

    // The round-trip berth is one berth on both legs, so it appears on both
    // maps. The return-only berth belongs to the return map alone.
    expect(
      onGo.intersection(onReturn),
      hasLength(1),
      reason: 'the round-trip berth is the same physical seat on both legs',
    );
    expect(onReturn.difference(onGo), hasLength(1));
  });

  testWidgets('untapping a round-trip berth on the return tab clears it '
      'from the go tab too', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
    ));
    await tester.pumpAndSettle();

    final shared = selectedSeatIds(tester);
    await tester.tap(find.byKey(SeatSelectionScreen.returnTabKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate(
      (w) => w is ChartSeatTile && w.cell.seatId == shared.first,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(SeatSelectionScreen.goTabKey));
    await tester.pumpAndSettle();

    expect(
      selectedSeatIds(tester).contains(shared.first),
      isFalse,
      reason: 'it is ONE berth on ONE booking — it cannot survive on one map '
          'after being given back on the other',
    );
  });
```

- [ ] **Step 2: Run to verify they fail**

Run: `C:/src/flutter/bin/flutter test test/screens/seat_selection_prefill_test.dart`
Expected: FAIL — `goTabKey` is not defined.

- [ ] **Step 3: Rename `_leg` and add the tab keys**

In `SeatSelectionScreen`:

```dart
  static const goTabKey = Key('chart_tab_go');
  static const returnTabKey = Key('chart_tab_return');
```

In `_SeatSelectionScreenState`, replace `TripType _leg = TripType.roundTrip;` with:

```dart
  /// WHICH MAP IS ON SCREEN — not what is being bought.
  ///
  /// This used to be the booking's trip type: changing it changed what the
  /// customer was buying AND wiped their selection. With a leg on every seat it
  /// is a view filter, and switching it must never touch the basket.
  late TripType _viewLeg = widget.intent.activeLegs.isEmpty
      ? TripType.roundTrip
      : widget.intent.activeLegs.first;
```

Replace every remaining `_leg` with `_viewLeg`.

- [ ] **Step 4: Make the tabs a view filter**

Replace `_legPills` with a tab strip driven by the intent, and delete the selection-clearing branch:

```dart
  /// Which maps this party actually needs. A round-trip or go-only party fills
  /// the GO map; a return-only party fills the RETURN map. A party needing only
  /// one sees no strip at all.
  List<TripType> get _tabs {
    final go = widget.intent.roundTrip + widget.intent.outboundOnly > 0;
    final ret = widget.intent.returnOnly > 0;
    return [
      if (go) TripType.roundTrip,
      if (ret) TripType.returnOnly,
    ];
  }

  Widget _legTabs(UgamColorSet c) {
    final tabs = _tabs;
    if (tabs.length < 2) return const SizedBox.shrink();

    Widget tab(TripType leg, Key key, String label) {
      final on = _viewLeg == leg;
      return Expanded(
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          // NOTE: no basket mutation here. That is the whole change.
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _viewLeg = leg);
          },
          child: AnimatedContainer(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? c.accentFill : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(
                color: on ? c.accent.withValues(alpha: 0.32) : c.border,
              ),
            ),
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: on ? c.accent : c.ink2),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(
          TripType.roundTrip,
          SeatSelectionScreen.goTabKey,
          tr('seat_pick.tab_go'),
        ),
        const SizedBox(width: UgamSpacing.sm),
        tab(
          TripType.returnOnly,
          SeatSelectionScreen.returnTabKey,
          tr('seat_pick.tab_return'),
        ),
      ],
    );
  }
```

Replace both `_legPills(c)` call sites in `_body` with `_legTabs(c)`.

- [ ] **Step 5: Resolve which bucket a tap fills**

Add to `_SeatSelectionScreenState`:

```dart
  /// Which leg bucket the next tap on the visible map fills.
  ///
  /// On the GO map, round-trip is filled before go-only: a round-trip berth
  /// needs BOTH legs free, so it has the fewest candidates and must claim them
  /// first. The RETURN map only ever fills return-only.
  TripType _bucketForTap() {
    if (_viewLeg == TripType.returnOnly) return TripType.returnOnly;
    if (_basket.berthsForLeg(TripType.roundTrip) < widget.intent.roundTrip) {
      return TripType.roundTrip;
    }
    return TripType.outboundOnly;
  }

  /// Berths still to place in the bucket a tap would fill. Drives the sofa rule.
  int get _remainingInBucket {
    final leg = _bucketForTap();
    return widget.intent.countFor(leg) - _basket.berthsForLeg(leg);
  }
```

In `_tapSeat`, pass the bucket when writing to the basket:

```dart
    final leg = _bucketForTap();
    setState(
      () => _basket.setBerths(
        busId: bus.id,
        seatId: seatId,
        berths: wanted,
        leg: leg,
      ),
    );
```

- [ ] **Step 6: Scope availability and price to the seat's own leg**

`_berthPrice` takes the leg it is pricing:

```dart
  /// What one berth of [cell] costs on [bus] for [leg]. A one-way berth pays
  /// half — so a mixed basket cannot be priced off one screen-level factor.
  double _berthPrice(Bus bus, SeatCell cell, TripType leg) =>
      bus.berthPriceFor(cell.seatType!, cell.row) * Bus.tripFactor(leg);
```

In `_total`, price each entry by its stored leg:

```dart
        sum += bus.berthPriceFor(cell.seatType!, cell.row) *
            entry.value.berths *
            Bus.tripFactor(entry.value.leg);
```

In `_tapSeat`, the availability probe uses the bucket being filled, not the view:

```dart
    final free = freeBerths(cell: cell, occupancy: occ, leg: _bucketForTap());
```

and the sheet's price uses the same: `halfPrice: _berthPrice(bus, cell, _bucketForTap())`.

Grid rendering keeps using `_viewLeg` for the availability it paints — that is the map the customer is looking at.

- [ ] **Step 7: Show each pick on the maps its leg actually covers**

`_berthsOn` currently returns the basket's berth count regardless of which tab is showing, so a go-only berth would wrongly appear selected on the return map. Filter it by the tab:

```dart
  /// Berths picked on the bus currently on screen, AS SEEN FROM THE VISIBLE MAP.
  ///
  /// A round-trip berth is one berth on both legs, so it shows on both tabs and
  /// giving it back on either releases it. A one-way berth belongs to its own
  /// map alone — showing a go-only seat as taken on the return map would claim
  /// a berth the customer never bought.
  int _berthsOn(String seatId) {
    final b = _bus;
    if (b == null) return 0;
    final entry = _basket.entryFor(busId: b.id, seatId: seatId);
    if (entry == null) return 0;
    final showsHere = _viewLeg == TripType.returnOnly
        ? entry.leg.usesReturn
        : entry.leg.usesOutbound;
    return showsHere ? entry.berths : 0;
  }
```

`_tapSeat`'s own "already ours" check must NOT use this filtered view — untapping has to work on the real entry:

```dart
    final current = _basket.berthsFor(busId: bus.id, seatId: seatId);
```

That line already reads the unfiltered basket, so leave it exactly as it is. Add a comment above it recording why:

```dart
    // Deliberately the UNFILTERED count: a round-trip berth shown on the return
    // map is still the same berth, and one tap must give it back on both.
```

Mark a shared berth on the tile so the customer can see why it appears twice. Add to `ChartSeatTile`:

```dart
  /// True when this berth is held for BOTH legs and the party is mixed, so the
  /// customer can see why the same seat appears on both maps.
  final bool bothLegs;
```

defaulting to `false` in its constructor, and render it beside the existing seat-type label:

```dart
            if (bothLegs)
              Text(
                tr('seat_pick.both_legs'),
                style: UgamText.caption.copyWith(color: c.accent, fontSize: 9),
              ),
```

Pass it from the grid builder in `seat_selection_screen.dart`:

```dart
            bothLegs: widget.intent.isMixed &&
                _basket.entryFor(busId: bus.id, seatId: cell.seatId ?? '')?.leg ==
                    TripType.roundTrip,
```

- [ ] **Step 8: Add the tab labels to all three locales**

`en.json` inside `"seat_pick"`: `"tab_go": "Going", "tab_return": "Coming back", "both_legs": "both ways",`
`gu.json` inside `"seat_pick"`: `"tab_go": "જવાનું", "tab_return": "આવવાનું", "both_legs": "બંને",`
`hi.json` inside `"seat_pick"`: `"tab_go": "जाना", "tab_return": "वापसी", "both_legs": "दोनों",`

Keep the existing `leg_round` / `leg_go` / `leg_return` keys — the confirm screen still uses them for its summary label.

- [ ] **Step 9: Run the suite and analyze**

Run: `C:/src/flutter/bin/flutter test && C:/src/flutter/bin/flutter analyze`
Expected: PASS. Existing tests referencing the old `seat_pick.leg_round` pills will need their finders updated to the new tab keys.

- [ ] **Step 10: Commit**

```bash
git add lib/screens/seat_selection_screen.dart assets/translations test/screens/seat_selection_prefill_test.dart
git commit -m "feat(chart): leg pills become view tabs that keep the selection"
```

---

## Task 7: One tap takes a whole sofa when the bucket needs two

**Files:**
- Modify: `lib/screens/seat_selection_screen.dart:249-303`
- Test: `test/screens/seat_selection_sharing_test.dart`

**Interfaces:**
- Consumes: `_remainingInBucket` from Task 6.
- Produces: no new public API.

- [ ] **Step 1: Write the failing sofa tests**

`test/screens/seat_selection_sharing_test.dart` already defines `harness(List<Bus> buses, {Map<String, SeatAvailability> availability, PartyIntent intent})`, `tapSeat(tester, seatId)`, `clearPrefill(tester)`, `selectedBerths(tester, seatId)` and `bus(oneRow())`. Use those names — do not invent new ones. The file asserts on `find.byKey(SofaShareSheet.wholeKey)`, not on the widget type; match that.

Append:

```dart
  testWidgets('one tap takes a whole sofa when the bucket needs two',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(oneRow())],
      intent: const PartyIntent(roundTrip: 4),
    ));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await tapSeat(tester, 'DU1');

    expect(
      find.byKey(SofaShareSheet.wholeKey),
      findsNothing,
      reason: 'the party needs two berths — whole-or-half is not a real question',
    );
    expect(selectedBerths(tester, 'DU1'), 2);
  });

  testWidgets('the sheet appears when the bucket has one berth left',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(oneRow())],
      intent: const PartyIntent(roundTrip: 3),
    ));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await tapSeat(tester, 'SU1');
    await tapSeat(tester, 'SU2');
    await tapSeat(tester, 'DU1');

    expect(find.byKey(SofaShareSheet.wholeKey), findsOneWidget);
    expect(find.byKey(SofaShareSheet.halfKey), findsOneWidget);
  });

  testWidgets('the bucket remainder decides, not the global one',
      (tester) async {
    // 1 round-trip berth and 3 go-only. The FIRST tap fills the round-trip
    // bucket, which needs exactly one — so it must ask, even though 4 berths
    // remain unplaced overall.
    await tester.pumpWidget(harness(
      [bus(oneRow())],
      intent: const PartyIntent(roundTrip: 1, outboundOnly: 3),
    ));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await tapSeat(tester, 'DU1');

    expect(
      find.byKey(SofaShareSheet.halfKey),
      findsOneWidget,
      reason: 'the global remainder would have silently overshot the bucket',
    );
  });

  testWidgets('refusing to share still takes the whole sofa in one tap',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(oneRow())],
      intent: const PartyIntent(roundTrip: 1, shareOk: false),
    ));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await tapSeat(tester, 'DU1');

    expect(find.byKey(SofaShareSheet.halfKey), findsNothing);
    expect(selectedBerths(tester, 'DU1'), 2);
  });
```

`oneRow()` must contain `SU1`, `SU2` and `DU1` for the second test to have two singles to fill before the sofa. If it does not, extend it — that is a fixture change, not a behaviour change.

- [ ] **Step 2: Run to verify they fail**

Run: `C:/src/flutter/bin/flutter test test/screens/seat_selection_sharing_test.dart`
Expected: FAIL — the sheet opens in the first test.

- [ ] **Step 3: Implement the rule**

In `lib/screens/seat_selection_screen.dart`, replace the `capacity == 2` branch of `_tapSeat`:

```dart
    if (capacity == 2) {
      // *** WHY THIS IS NOT ALWAYS A SHEET ***
      // A hidden tap-cycle used to commit the customer to a stranger silently;
      // replacing it with a sheet fixed that, and introduced a new cost — a
      // family taking a whole sofa answered a question whose answer the party
      // size already implied.
      //
      // The sheet now survives exactly one case: the bucket being filled has a
      // single berth left, so whole-or-half is genuinely open.
      final canTakeHalf = widget.intent.shareOk && free >= 1;
      final canTakeWhole = free >= 2;
      if (!canTakeHalf && !canTakeWhole) return;

      if (canTakeWhole && !canTakeHalf) {
        wanted = 2;
      } else if (canTakeWhole && _remainingInBucket >= 2) {
        // They need both berths here. Asking would be asking nothing.
        wanted = 2;
      } else {
        final choice = await showSofaShareSheet(
          context,
          halfPrice: _berthPrice(bus, cell, _bucketForTap()),
          canTakeWhole: canTakeWhole,
          canTakeHalf: canTakeHalf,
          someoneAlreadyThere: free < capacity,
        );
        if (choice == null || !mounted) return; // dismissed — book nothing
        wanted = choice;
      }
    } else {
      wanted = 1;
    }
```

- [ ] **Step 4: Correct the stale docstring above `_tapSeat`**

Replace lines 249-254's comment, which still describes the removed cycle:

```dart
  /// Tapping a cell takes it, or gives it back.
  ///
  /// A single berth is a plain on/off. A double sofa takes both berths in one
  /// tap when the bucket being filled still needs two; when only one berth is
  /// left to place, the share sheet asks whole-or-half in words, with both
  /// prices, before any money moves.
```

- [ ] **Step 5: Run the sharing tests**

Run: `C:/src/flutter/bin/flutter test test/screens/seat_selection_sharing_test.dart`
Expected: PASS.

- [ ] **Step 6: Run the full suite and analyze**

Run: `C:/src/flutter/bin/flutter test && C:/src/flutter/bin/flutter analyze`
Expected: PASS, no errors.

- [ ] **Step 7: Commit**

```bash
git add lib/screens/seat_selection_screen.dart test/screens/seat_selection_sharing_test.dart
git commit -m "fix(chart): one tap takes the whole sofa when the party needs both berths"
```

---

## Task 8: The summary bar states a per-leg shortfall

**Files:**
- Modify: `lib/widgets/chart_summary_bar.dart`
- Modify: `lib/screens/seat_selection_screen.dart` (call site)
- Modify: `assets/translations/{en,gu,hi}.json`

**Interfaces:**
- Consumes: `AutoPickResult.shortfall` (`Map<TripType, int>`), `PartyIntent`.
- Produces: `ChartSummaryBar({..., Map<TripType, int> shortfall = const {}})`; `noRoom` removed.

- [ ] **Step 1: Write the failing widget test**

Create the test inside `test/widgets/chart_summary_bar_test.dart` (create the file if absent):

```dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/chart_summary_bar.dart';

void main() {
  Widget harness(Widget child) => MaterialApp(
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
        home: Scaffold(body: child),
      );

  testWidgets('it names the leg that could not be seated', (tester) async {
    await tester.pumpWidget(harness(const ChartSummaryBar(
      people: 4,
      pickedBerths: 2,
      lowerBerths: 2,
      total: 3300,
      shortfall: {TripType.returnOnly: 2},
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('2'), findsWidgets);
  });

  testWidgets('no shortfall reads as ready', (tester) async {
    await tester.pumpWidget(harness(const ChartSummaryBar(
      people: 2,
      pickedBerths: 2,
      lowerBerths: 1,
      total: 2800,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `C:/src/flutter/bin/flutter test test/widgets/chart_summary_bar_test.dart`
Expected: FAIL — no `shortfall` parameter.

- [ ] **Step 3: Replace `noRoom` with `shortfall`**

In `lib/widgets/chart_summary_bar.dart`, add `import '../models/trip_type.dart';`, replace the `noRoom` field:

```dart
  /// Berths the picker could not place, per leg. Empty when everyone fits.
  ///
  /// This replaces a single `noRoom` flag, which could only say "nothing fits"
  /// — useless for a mixed party whose outbound leg is seated and whose return
  /// leg is not. That is a fact the customer must not discover at the counter.
  final Map<TripType, int> shortfall;
```

with `this.shortfall = const {},` in the constructor, and:

```dart
  bool get _noRoom => shortfall.isNotEmpty;
  bool get _ready => !_noRoom && pickedBerths >= people && pickedBerths > 0;
```

Replace every `noRoom` reference in `build` and `_headline` with `_noRoom`, and make `_headline`'s no-room branch name the leg:

```dart
    if (_noRoom) {
      final entry = shortfall.entries.first;
      return tr(
        switch (entry.key) {
          TripType.roundTrip => 'chart_summary.short_round',
          TripType.outboundOnly => 'chart_summary.short_go',
          TripType.returnOnly => 'chart_summary.short_return',
        },
        namedArgs: {'n': '${entry.value}'},
      );
    }
```

- [ ] **Step 4: Update the call site**

In `lib/screens/seat_selection_screen.dart`, the `ChartSummaryBar` construction takes `shortfall: _shortfall` in place of `noRoom: _noRoom`.

- [ ] **Step 5: Add the three keys to all three locales**

`en.json` inside `"chart_summary"`:
```json
    "short_round": "No room for {n} for the round trip right now",
    "short_go": "No room for {n} on the way there right now",
    "short_return": "No room for {n} on the way back right now",
```

`gu.json` inside `"chart_summary"`:
```json
    "short_round": "અત્યારે આવ-જા માટે {n} બેઠક નથી",
    "short_go": "અત્યારે જવા માટે {n} બેઠક નથી",
    "short_return": "અત્યારે પાછા આવવા માટે {n} બેઠક નથી",
```

`hi.json` inside `"chart_summary"`:
```json
    "short_round": "अभी आने-जाने के लिए {n} सीट नहीं है",
    "short_go": "अभी जाने के लिए {n} सीट नहीं है",
    "short_return": "अभी वापसी के लिए {n} सीट नहीं है",
```

Leave the existing `"no_room"` key in place — other call sites may still use it; removing a live key is a separate change.

- [ ] **Step 6: Run the suite and analyze**

Run: `C:/src/flutter/bin/flutter test && C:/src/flutter/bin/flutter analyze`
Expected: PASS, no errors.

- [ ] **Step 7: Commit**

```bash
git add lib/widgets/chart_summary_bar.dart lib/screens/seat_selection_screen.dart assets/translations test/widgets/chart_summary_bar_test.dart
git commit -m "feat(chart): the summary bar names the leg that is short"
```

---

## Task 9: Migration 089 — per-seat legs in the chart RPCs

**Files:**
- Create: `supabase/migrations/089_per_seat_leg_chart_claim.sql`

**Interfaces:**
- Consumes: the claim payload shape from Task 4 — `{"seatId": "...", "berths": N, "leg": "roundTrip|outboundOnly|returnOnly"}`.
- Produces: no signature change. All four functions keep their existing argument lists; `p_leg` becomes the FALLBACK for seats that omit their own.

- [ ] **Step 1: Read the functions being replaced**

Read `supabase/migrations/068_multi_bus_chart_claim.sql` in full and `supabase/migrations/064_seat_holds_chart_finalize.sql:130-273`. The new file must reproduce each function's body verbatim except for the leg resolution — a rewrite from memory will drop the advisory locking and the conflict aggregation.

- [ ] **Step 2: Write the migration**

Create `supabase/migrations/089_per_seat_leg_chart_claim.sql`:

```sql
-- 089: a chart booking may carry a DIFFERENT leg on each seat.
--
-- WHY
-- The chart RPCs took one `p_leg` and stamped it onto every assigned seat and
-- every request line. That made the ordinary case impossible to express: four
-- people go to Dwarka, two stay with relatives, two come home. Request mode has
-- always carried a leg per `request_lines` row; chart mode was the odd one out.
--
-- SHAPE OF THE CHANGE
-- Additive. Each element of the seats array MAY carry its own "leg"; where it
-- does not, `p_leg` is used exactly as before:
--
--     coalesce(v_seat->>'leg', p_leg)
--
-- No signature changes, so no grants are re-issued and no client has to probe
-- for a new function. Builds already on the Play Store send no per-seat leg and
-- therefore behave byte-for-byte as they do today. That backward compatibility
-- is the entire reason this is a coalesce and not a new parameter.
--
-- DEPENDS ON: 067 and 068. Both are staged in this repo and were NOT deployed
-- at the time of writing. Verify they are live before applying this file.
--
-- booking_requests.trip_type becomes a DERIVED SUMMARY of the per-seat legs —
-- round-trip when any seat is round-trip or the legs are mixed, else the single
-- shared value. Identical rule to `summaryTripTypeOf` in the Dart client and to
-- how request mode has always written that column.

-- ── helper: the coarse trip type of a set of per-seat legs ──────────────────
create or replace function public.chart_summary_leg(p_legs text[])
returns text
language sql
immutable
as $$
  select case
    when p_legs is null or cardinality(p_legs) = 0 then 'roundTrip'
    when 'roundTrip' = any(p_legs) then 'roundTrip'
    when cardinality(array(select distinct unnest(p_legs))) = 1 then p_legs[1]
    else 'roundTrip'
  end;
$$;
```

Then, for each of `chart_validate_bus_seats`, `chart_claim_seats`, `chart_claim_seats_multi`, `chart_hold_seats` and `chart_hold_seats_multi`, copy the existing `create or replace function` body from 064/068 and apply exactly these edits:

1. Inside the `for v_seat in select * from jsonb_array_elements(...)` loop, resolve the leg per seat and derive the two leg wants from it:
   ```sql
       v_seat_leg  := coalesce(v_seat->>'leg', p_leg);
       if v_seat_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
         raise exception 'Invalid seat leg.' using errcode = 'check_violation';
       end if;
       v_wants_go  := v_seat_leg in ('roundTrip', 'outboundOnly');
       v_wants_ret := v_seat_leg in ('roundTrip', 'returnOnly');
   ```
   Delete the two assignments that computed `v_wants_go` / `v_wants_ret` once from `p_leg` before the loop, and declare `v_seat_leg text;`.

2. Carry the resolved leg into the claim object built inside the loop:
   ```sql
       v_claims := v_claims || jsonb_build_object(
         ..., 'leg', v_seat_leg
       );
   ```

3. Where `assigned_seats` are aggregated, take the leg from the claim rather than from `p_leg`:
   ```sql
       'leg', c->>'leg'
   ```

4. Where `request_lines` are aggregated, group by the claim's leg as well as type and position, and emit it:
   ```sql
       'qty', cnt, 'leg', c_leg
   ```

5. Where `booking_requests.trip_type` and the `raw_form` leg are written, use the derived summary:
   ```sql
       public.chart_summary_leg(
         array(select jsonb_array_elements(v_claims)->>'leg')
       )
   ```

Keep `p_leg`'s existing validation (`if p_leg not in (...)`) intact — it is still the fallback and an invalid one must still be rejected.

- [ ] **Step 3: Check the file parses**

There is no local Postgres in this repo. Verify by inspection against 068:
- every `create or replace function` in 089 has the SAME argument list as its 068/064 original (compare signature lines side by side);
- no `grant` or `revoke` statement is needed, because no signature changed;
- every `declare` block that uses `v_seat_leg` declares it.

Run: `git diff --stat supabase/migrations/089_per_seat_leg_chart_claim.sql`
Expected: one new file.

- [ ] **Step 4: Write the backward-compatibility note into the file**

At the end of 089, add the verification the repo owner must perform after deploying:

```sql
-- POST-DEPLOY VERIFICATION (run by hand, do not automate):
--
--   1. Old-client shape — a payload with NO per-seat leg must behave as before:
--      select public.chart_validate_bus_seats(
--        '<tour>', '<bus>', 'outboundOnly',
--        '[{"seatId":"SU1","berths":1}]'::jsonb
--      );
--      Expect the same result as before 089.
--
--   2. Mixed shape — two seats, two legs, one call:
--      select public.chart_validate_bus_seats(
--        '<tour>', '<bus>', 'roundTrip',
--        '[{"seatId":"SU1","berths":1,"leg":"roundTrip"},
--          {"seatId":"SU2","berths":1,"leg":"outboundOnly"}]'::jsonb
--      );
--      Expect SU2 to be checked against the outbound leg only.
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/089_per_seat_leg_chart_claim.sql
git commit -m "feat(db): 089 — a chart claim carries a leg per seat"
```

- [ ] **Step 6: Report the deployment dependency**

Do NOT deploy. Report to the user: 089 is committed and requires 067 and 068 to be live first; all three are pending manual deployment.

---

## Verification Before Completion

- [ ] `C:/src/flutter/bin/flutter analyze` — zero errors. Re-run once before believing a failure (concurrent agent in this tree).
- [ ] `C:/src/flutter/bin/flutter test` — full suite green, and the count is **higher** than the 1406 baseline, not merely equal.
- [ ] `git log --oneline` shows nine commits, one per task.
- [ ] Every new `tr()` key exists in all three of `en.json`, `gu.json`, `hi.json`. Verify by grepping each key in each file — a missing key renders as the raw key at runtime and no test catches it.
- [ ] Migration 089 is committed and NOT deployed, and the user has been told it depends on 067 and 068.
