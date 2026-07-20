# Money Board + Cockpit Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Elevate the tour money board and per-bus money cockpit to the approved design language (one hero per surface, semantic figure color with copper rationed, zero-suppression, state-driven rhythm), keeping the existing copper/graphite tokens.

**Architecture:** View-layer only. No controller/model/data changes. We refine two screens (`tour_money_board_screen.dart`, `bus_money_screen.dart`) and add one flag to a shared component (`UgamHeroStat`). State classification (`MoneyController.stateForBusSummary`) is untouched — we only change how each state is *rendered*.

**Tech Stack:** Flutter, GetX (reactive `Obx`), easy_localization (`tr()`), the Ugam design system (`lib/design/`). Tests: `flutter_test` widget tests. `flutter` binary at `C:\src\flutter\bin`.

## Global Constraints

- **Palette/tokens only** — every color from `UgamColors.of(context)`; no raw hex. (`tokens.dart`)
- **Copper (`accent`) is rationed** — used only for the P&L outcome hero and the single solid-copper CTA per screen. Figures are semantic: `danger`=to-collect, `warm`=handover-due, `good`=done/profit, `ink2/ink3`=context. (spec §A2)
- **Nothing renders a ₹0-because-nothing-happened field.** (spec §A3)
- **Only the hero breathes; supporting rows stay `md`(12)-tight.** Do not re-widen density. (spec §A5)
- **Every task ends green:** `& C:\src\flutter\bin\flutter analyze <files>` clean AND the touched test passes, before committing.
- **New user-facing strings** get keys in all three locales: `assets/translations/en.json`, `gu.json`, `hi.json`.
- Run tests/analyze from repo root `c:\WorkSpace\ugam-bus-booking` with PowerShell: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test <path>`.

---

### Task 1: `UgamHeroStat` gains a `framed` flag

Lets a hero-stat render its content **without** wrapping itself in a `UgamCard`, so it can sit inside a card the caller already owns (fixes the "card-in-card" smell). Default `true` = today's behavior, so all existing call sites are unchanged.

**Files:**
- Modify: `lib/design/components/ugam_hero_stat.dart`
- Test: `test/design/ugam_hero_stat_test.dart` (create)

**Interfaces:**
- Produces: `UgamHeroStat({..., bool framed = true})`. When `framed == false`, the widget returns its `body`/tap-target directly (no `UgamCard`).

- [ ] **Step 1: Write the failing test**

```dart
// test/design/ugam_hero_stat_test.dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/design/ugam_hero_stat_test.dart`
Expected: FAIL — `framed` is not a defined parameter (compile error).

- [ ] **Step 3: Add the flag and branch the return**

In `lib/design/components/ugam_hero_stat.dart`, add the field + constructor param:

```dart
  final List<HeroStatLine>? breakdown;
  final bool initiallyExpanded;
  final VoidCallback? onTap;
  /// When false, render the hero content directly (no wrapping UgamCard) so it
  /// can live inside a card the caller already owns — avoids card-in-card.
  final bool framed;

  const UgamHeroStat({
    super.key,
    required this.label,
    required this.value,
    this.tone,
    this.secondary,
    this.breakdown,
    this.initiallyExpanded = false,
    this.onTap,
    this.framed = true,
  });
```

Then replace the final return block (the two `UgamCard.plain(...)` returns) with framing-aware versions:

```dart
    // A breakdown card owns its own tap (the chevron toggle); otherwise the
    // whole card taps when an [onTap] is given.
    if (_hasBreakdown) {
      final tappable = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: body,
      );
      return framed ? UgamCard.plain(child: tappable) : tappable;
    }

    if (!framed) {
      return widget.onTap == null
          ? body
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: body,
            );
    }
    return UgamCard.plain(
      onTap: widget.onTap,
      child: body,
    );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/design/ugam_hero_stat_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Analyze + commit**

```bash
$env:Path = "C:\src\flutter\bin;$env:Path"; flutter analyze lib/design/components/ugam_hero_stat.dart test/design/ugam_hero_stat_test.dart
git add lib/design/components/ugam_hero_stat.dart test/design/ugam_hero_stat_test.dart
git commit -m "feat(design): UgamHeroStat framed flag to avoid card-in-card"
```
Expected: analyze "No issues found!", commit succeeds.

---

### Task 2: Money board — semantic card tone (danger to-collect vs warm handover)

Today an action-needed bus always uses `UgamCardTone.warm`. Split it: a **collect shortfall** → `danger` tint (matches its red figure); a **handover due** → `warm` tint (matches its rose figure). This is spec §A2/§A4. Also add a stable key to each bus card so state is assertable.

**Files:**
- Modify: `lib/screens/tour_money_board_screen.dart` (the `_BusMoneyRow.build` switch + the `UgamCard.plain` return)
- Test: `test/screens/tour_money_board_screen_test.dart` (add one test)

**Interfaces:**
- Consumes: `MoneyController.stateForBusSummary`, `BusMoneyState`, `UgamCardTone` (all existing).
- Produces: each bus card carries `key: ValueKey('bus-money-row-<busId>')`.

- [ ] **Step 1: Write the failing test**

Add to `test/screens/tour_money_board_screen_test.dart` (inside `main()`), a new `testWidgets`:

```dart
  testWidgets('to-collect bus tints danger; handover-due bus tints warm',
      (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);

    money.collections.assignAll([
      // Bus 1: billed 5000 but nothing received → revenue outstanding, no
      // handover expected yet → actionNeeded via "to collect" (danger).
      Collection(
        tourId: 't1', busId: 'b1', passengerId: 'p1', seatId: 'A1',
        amountDue: 5000, amountReceived: 0,
      ),
      // Bus 2: fully collected 5000, none handed over → handover due (warm).
      Collection(
        tourId: 't1', busId: 'b2', passengerId: 'p2', seatId: 'B1',
        amountDue: 5000, amountReceived: 5000,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    final busA = tester.widget<UgamCard>(
      find.byKey(const ValueKey('bus-money-row-b1')),
    );
    final busB = tester.widget<UgamCard>(
      find.byKey(const ValueKey('bus-money-row-b2')),
    );
    expect(busA.tone, UgamCardTone.danger);
    expect(busB.tone, UgamCardTone.warm);
  });
```

Add the imports at the top of the test file if missing:

```dart
import 'package:occubusbooking/design/components/ugam_card.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens/tour_money_board_screen_test.dart -n "danger"`
Expected: FAIL — no widget with key `bus-money-row-b1` (finder returns nothing) OR tone is `warm` not `danger`.

- [ ] **Step 3: Split the tone + add the key**

In `lib/screens/tour_money_board_screen.dart`, in `_BusMoneyRow.build`, change the `actionNeeded` arm of the switch so the card tone tracks the figure:

```dart
      BusMoneyState.actionNeeded => (
        hasHandoverDue ? UgamCardTone.warm : UgamCardTone.danger,
        hasHandoverDue
            ? tr('tour_money_board.handover')
            : tr('tour_money_board.to_collect'),
        hasHandoverDue ? summary.outstandingHandover : summary.toCollectTotal,
        hasHandoverDue ? c.warm : c.danger,
        null,
        hasHandoverDue ? UgamStatusTone.warm : UgamStatusTone.warm,
      ),
```

(The `statusTone` stays `warm` — action cards omit the status word anyway; leaving it avoids an unused-branch warning.)

Then add the key to the returned card:

```dart
    return UgamCard.plain(
      key: ValueKey('bus-money-row-${bus.id}'),
      tone: cardTone,
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.md),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens/tour_money_board_screen_test.dart`
Expected: PASS (all tests, including the two existing ones — the settled/neutral/handover behavior is unchanged).

- [ ] **Step 5: Analyze + commit**

```bash
$env:Path = "C:\src\flutter\bin;$env:Path"; flutter analyze lib/screens/tour_money_board_screen.dart test/screens/tour_money_board_screen_test.dart
git add lib/screens/tour_money_board_screen.dart test/screens/tour_money_board_screen_test.dart
git commit -m "feat(money): danger tint for to-collect, warm for handover-due"
```

---

### Task 3: Money board — elevate the P&L card into the screen hero

Turn `_PnlEntryCard` from a flat row into the screen's one copper-accented hero: `elev: true`, a soft copper **glow** halo behind it, an **outcome headline** ("Trip is in profit" / "Trip is at a loss"), and the big net figure tinted `good`/`danger`. (Sparkline is deferred per spec §8 — data source undecided; do NOT fabricate a series.)

**Files:**
- Modify: `lib/screens/tour_money_board_screen.dart` (`_PnlEntryCard`)
- Modify: `assets/translations/en.json`, `assets/translations/gu.json`, `assets/translations/hi.json`
- Test: `test/screens/tour_money_board_screen_test.dart` (add one test)

**Interfaces:**
- Consumes: `TourMoneySummary.totalNetBilled` (existing), `Formatters.formatMoneyInr` (existing).
- Produces: the P&L card carries `key: const ValueKey('pnl-hero')` and renders `tr('tour_money_board.trip_in_profit')` or `tr('tour_money_board.trip_at_loss')`.

- [ ] **Step 1: Add the i18n keys**

In `assets/translations/en.json`, inside the `"tour_money_board"` object, after `"more_detail": "More detail"` add a comma and:

```json
    "more_detail": "More detail",
    "trip_in_profit": "Trip is in profit",
    "trip_at_loss": "Trip is at a loss"
```

In `assets/translations/gu.json`, inside its `"tour_money_board"` object add:

```json
    "trip_in_profit": "ટ્રીપ નફામાં છે",
    "trip_at_loss": "ટ્રીપ ખોટમાં છે"
```

In `assets/translations/hi.json`, inside its `"tour_money_board"` object add:

```json
    "trip_in_profit": "ट्रिप मुनाफ़े में है",
    "trip_at_loss": "ट्रिप घाटे में है"
```

(Match each file's existing trailing-comma style — add a comma to the previous last key.)

- [ ] **Step 2: Write the failing test**

Add to `test/screens/tour_money_board_screen_test.dart`:

```dart
  testWidgets('P&L hero shows the trip outcome headline + net figure',
      (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);
    money.collections.assignAll([
      Collection(
        tourId: 't1', busId: 'b1', passengerId: 'p1', seatId: 'A1',
        amountDue: 1000, amountReceived: 1000,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // The hero exists and its outcome headline matches the computed sign.
    expect(find.byKey(const ValueKey('pnl-hero')), findsOneWidget);
    final billed = money.tourSummary().totalNetBilled;
    final key = billed >= 0
        ? 'tour_money_board.trip_in_profit'
        : 'tour_money_board.trip_at_loss';
    expect(find.text(key), findsOneWidget);
  });
```

- [ ] **Step 3: Run test to verify it fails**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens/tour_money_board_screen_test.dart -n "P&L hero"`
Expected: FAIL — no widget with key `pnl-hero`.

- [ ] **Step 4: Rewrite `_PnlEntryCard`**

Replace the whole `_PnlEntryCard` class body's `build` return in `lib/screens/tour_money_board_screen.dart` with an elevated, glowing hero:

```dart
  @override
  Widget build(BuildContext context) {
    final billed = summary.totalNetBilled;
    final inProfit = billed >= 0;
    final tone = inProfit ? c.good : c.danger;
    return UgamCard.plain(
      key: const ValueKey('pnl-hero'),
      onTap: onTap,
      elev: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Soft copper halo — the screen's one signature glow (spec §A4).
          Positioned(
            left: -30,
            top: -60,
            child: IgnorePointer(
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [c.glow, c.glow.withValues(alpha: 0)],
                    stops: const [0.0, 0.7],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: BorderRadius.circular(UgamRadius.stat),
                ),
                child: Icon(Icons.insights_rounded, size: 20, color: c.accent),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('trip_pnl.title').toUpperCase(),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      inProfit
                          ? tr('tour_money_board.trip_in_profit')
                          : tr('tour_money_board.trip_at_loss'),
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      Formatters.formatMoneyInr(billed.abs()),
                      style: UgamText.tabular(
                        UgamText.numXl.copyWith(color: tone),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('trip_pnl.entry_sub'),
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
            ],
          ),
        ],
      ),
    );
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens/tour_money_board_screen_test.dart`
Expected: PASS (all tests).

- [ ] **Step 6: Analyze + commit**

```bash
$env:Path = "C:\src\flutter\bin;$env:Path"; flutter analyze lib/screens/tour_money_board_screen.dart
git add lib/screens/tour_money_board_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json test/screens/tour_money_board_screen_test.dart
git commit -m "feat(money): elevate P&L card into the glowing screen hero"
```

---

### Task 4: Per-bus cockpit — tighten the hero + semantic stats + zero-suppress income

Three changes in `bus_money_screen.dart`: (1) shrink the outstanding hero from showroom to cockpit size (the `SizedBox(height: 96)` + 200×200 halo + `xl` paddings); (2) the supporting stat grid drops the "Income" tile when income is ₹0 (spec §A3); (3) confirm collected/income read `good`, expenses `warm` (already correct — verify).

**Files:**
- Modify: `lib/screens/bus_money_screen.dart` (`_OutstandingHero` + the stat `Row` at ~lines 119-155)
- Test: `test/screens/bus_money_screen_test.dart` (create)

**Interfaces:**
- Consumes: `MoneyController.summaryForBus`, `BusMoneySummary.income` (existing).
- Produces: the stat row renders 3 tiles when `income > 0`, else 2 (no Income tile).

- [ ] **Step 1: Write the failing test**

```dart
// test/screens/bus_money_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/income_entry.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/bus_money_screen.dart';

class _FakeMoneyController extends MoneyController {
  @override
  Future<void> loadForTour(String tourId) async {}
}

Bus _bus() => Bus(
      id: 'b1',
      name: 'Vantara',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus()],
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: BusMoneyScreen(tour: _tour(), bus: _bus()),
    );

void main() {
  tearDown(Get.reset);

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('income stat is hidden when there is no extra income',
      (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);
    money.collections.assignAll([
      Collection(
        tourId: 't1', busId: 'b1', passengerId: 'p1', seatId: 'A1',
        amountDue: 1000, amountReceived: 1000,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // No income seeded → the Income stat label key must not render.
    expect(find.text('bus_money.stat_income'), findsNothing);
    // Collected + expenses stats still render.
    expect(find.text('bus_money.stat_collected'), findsOneWidget);
    expect(find.text('bus_money.stat_expenses'), findsOneWidget);
  });

  testWidgets('income stat appears once there is income', (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);
    money.collections.assignAll([
      Collection(
        tourId: 't1', busId: 'b1', passengerId: 'p1', seatId: 'A1',
        amountDue: 1000, amountReceived: 1000,
      ),
    ]);
    money.incomes.assignAll([
      IncomeEntry(
        tourId: 't1', busId: 'b1',
        category: IncomeCategory.other, label: 'Cabin', amount: 500,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('bus_money.stat_income'), findsOneWidget);
  });
}
```

> Before writing, verify the `IncomeEntry` + `IncomeCategory` constructor names against `lib/models/income_entry.dart`; adjust the seed if the enum value differs. (Read the file first — do not guess field names.)

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens/bus_money_screen_test.dart -n "hidden"`
Expected: FAIL — the Income tile renders unconditionally today, so `bus_money.stat_income` is found.

- [ ] **Step 3: Zero-suppress the income tile + tighten the hero**

In `lib/screens/bus_money_screen.dart`, replace the supporting stat `Row` (the one with three `UgamStatTile`s, collected/income/expenses) with a version that builds its children conditionally:

```dart
                    // ── Supporting stat grid (demoted) ─────────────────
                    Builder(
                      builder: (_) {
                        final tiles = <Widget>[
                          Expanded(
                            child: UgamStatTile(
                              icon: Icons.payments_rounded,
                              value:
                                  Formatters.formatMoneyInrCompact(s.collected),
                              label: tr('bus_money.stat_collected'),
                              variant: UgamStatVariant.good,
                            ),
                          ),
                          if (s.income > 0.005)
                            Expanded(
                              child: UgamStatTile(
                                icon: Icons.savings_rounded,
                                value:
                                    Formatters.formatMoneyInrCompact(s.income),
                                label: tr('bus_money.stat_income'),
                                variant: UgamStatVariant.good,
                              ),
                            ),
                          Expanded(
                            child: UgamStatTile(
                              icon: Icons.receipt_long_rounded,
                              value: Formatters.formatMoneyInrCompact(
                                s.expensesTotal,
                              ),
                              label: tr('bus_money.stat_expenses'),
                              variant: UgamStatVariant.warm,
                            ),
                          ),
                        ];
                        return Row(
                          children: [
                            for (var i = 0; i < tiles.length; i++) ...[
                              if (i > 0) const SizedBox(width: UgamSpacing.md),
                              tiles[i],
                            ],
                          ],
                        );
                      },
                    ),
```

Then tighten `_OutstandingHero` — change its card padding and the halo/figure sizing:

```dart
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.lg,
      ),
```

and inside it, shrink the focal figure block:

```dart
          const SizedBox(height: UgamSpacing.sm),
          // The screen's single focal figure — a big Sora number set over a
          // soft copper halo, mirroring the dashboard passenger hero.
          SizedBox(
            height: 72,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [c.glow, c.glow.withValues(alpha: 0)],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.lg,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Formatters.formatMoneyInr(amount),
                      style: UgamText.tabular(
                        UgamText.hero
                            .copyWith(color: figureColor, fontSize: 38),
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens/bus_money_screen_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Analyze + commit**

```bash
$env:Path = "C:\src\flutter\bin;$env:Path"; flutter analyze lib/screens/bus_money_screen.dart test/screens/bus_money_screen_test.dart
git add lib/screens/bus_money_screen.dart test/screens/bus_money_screen_test.dart
git commit -m "feat(money): tighten cockpit hero + zero-suppress income stat"
```

---

### Task 5: Regression sweep + close-out

**Files:** none changed (verification only).

- [ ] **Step 1: Full money-cluster test + analyze**

Run:
```
$env:Path = "C:\src\flutter\bin;$env:Path"
flutter analyze lib/screens/tour_money_board_screen.dart lib/screens/bus_money_screen.dart lib/design/components/ugam_hero_stat.dart
flutter test test/screens/tour_money_board_screen_test.dart test/screens/bus_money_screen_test.dart test/design/ugam_hero_stat_test.dart
```
Expected: analyze clean; all tests pass.

- [ ] **Step 2: Broader safety net**

Run: `$env:Path = "C:\src\flutter\bin;$env:Path"; flutter test test/screens test/design`
Expected: no NEW failures vs the pre-change baseline. (Pre-existing unrelated failures, if any, are noted, not fixed here.)

- [ ] **Step 3: Manual visual check**

Hot-reload the app, open a tour → Money. Confirm against the approved mockup: P&L hero glows and leads; to-collect buses are red-tinted, handover-due rose-tinted, settled calm; no ₹0 rows; cockpit hero is tighter. Note anything off for a follow-up.

---

## Self-Review

**Spec coverage:** §A1 hero (Tasks 3, 4) ✓ · §A2 semantic color + rationed accent (Tasks 2, 3) ✓ · §A3 zero-suppress (Task 4; board already done) ✓ · §A4 state rhythm/tone (Task 2) ✓ · §A5 earned space (Task 4 hero tighten) ✓ · §B0 UgamHeroStat framed flag (Task 1) ✓ · §B1 board remainder (Tasks 2, 3) ✓ · §B2 cockpit (Task 4) ✓. **Deferred (explicitly, per spec §8):** P&L sparkline; collection (§B3) and trip P&L (§B4) screens → separate follow-up plan after these ship.

**Placeholder scan:** Task 4 Step 1 flags "verify IncomeEntry constructor against the model file" — this is a real instruction (read before seeding), not a placeholder for missing plan content; the executor confirms field names against `lib/models/income_entry.dart`. No TBDs elsewhere.

**Type consistency:** `framed` (Task 1) matches its use implicitly (no other task calls it yet — it's foundation for the deferred rollup). `ValueKey('bus-money-row-<id>')` (Task 2) and `ValueKey('pnl-hero')` (Task 3) are the only keys, used consistently in their tests. `BusMoneySummary.income`, `.collected`, `.expensesTotal`, `.totalNetBilled` are all existing fields already read by these screens today.
