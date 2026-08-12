# The Gujarati overflow guard

```
flutter test test/overflow/
```

## Why this exists

Gujarati is this app's **primary** language and runs ~30% longer than English,
but every layout in here was built and eyeballed in English at 390pt. Three
separate reviews have independently found the same three classes of breakage,
each time by hand, each time throwing the test away afterwards:

* a `Row` with an unbounded natural-width trailing child, where the longer
  translation silently pushes its sibling off the card;
* a label truncated mid-word to unreadability (`બાકી સોં…`);
* a control that fits at text scale 1.0 and clips at the 1.3x accessibility cap
  that `lib/app.dart` permits.

None of that reproduces in English at 390pt, which is the only combination a
developer ever looks at. This directory makes the hostile combination automatic.

## The matrix

Every subject is pumped across **16 cells**: `{gu, hi} x {375pt, 320pt} x
{text 1.0, text 1.3} x {light, dark}`. See `guardLocales` / `guardWidths` /
`guardTextScales` in `overflow_guard.dart` for why each axis is the value it is.

English is deliberately absent: it is the one language the layouts were already
eyeballed in, so it proves nothing.

Two numbers appear in every finding. `text x1.3` is the OS accessibility
preference; `effective 1.105` is what actually reaches the glyphs after
`app.dart`'s `clamp(0.9, 1.3) * UgamScale.of(context)`. Quote the effective one
when reproducing by hand.

## Adding a component

Add a `testWidgets` to `components_overflow_test.dart`:

```dart
testWidgets('UgamThing — the shape finance_screen actually ships', (tester) async {
  await expectNoOverflow(
    tester,
    subject: 'UgamThing (3 across, longest real label)',
    build: () => guardBody(
      Row(children: [
        Expanded(child: UgamThing(label: realText('finance.stat_tours'))),
        Expanded(child: UgamThing(label: realText('finance.stat_best'))),
      ]),
    ),
  );
});
```

Four rules, all of which have already caught something:

1. **Use `realText('some.key')`, never a literal.** It reads the value straight
   out of `assets/translations/<lang>.json` and *throws* if the key was renamed,
   so the guard can never quietly drift onto copy that no longer ships. Use
   `longestUnder('prefix.')` when several keys plausibly land in the same slot
   and you want whichever is longest. Real user data (a passenger's name) is the
   one legitimate place for a literal — it does not come from the catalogue.

2. **Call `realText` INSIDE the builder.** It resolves in the current scenario's
   language, so a string hoisted above `expectNoOverflow` gets frozen in one
   locale and the `hi` half of the matrix silently re-tests Gujarati.

3. **Reproduce the shape a screen actually ships**, not the component in
   isolation. `UgamStatTile` is fine alone; three of them in `Expanded`s at 320pt
   is what `finance_screen` does and is where it breaks.

4. **Render every branch.** Tone enums, the loading state, the sold-out string
   that only appears on a full bus — a branch that renders in one theme only is
   exactly the thing that goes untested forever.

## Adding a screen

Same call, but pass the screen as `build` and give it what it needs to mount:

```dart
testWidgets('CollectionScreen — the filtered list', (tester) async {
  Get.put(FakeMoneyController());        // GetX deps first
  await expectNoOverflow(
    tester,
    subject: 'CollectionScreen',
    build: () => const CollectionScreen(),
    useGetX: true,                       // default; gives a GetMaterialApp host
    matrix: lightOnlyMatrix,             // 8 pumps instead of 16, for heavy subjects
  );
});
```

`resetGuardState()` in `tearDown` clears the GetX registry between subjects.

If a screen cannot be pumped without contorting production code — it needs a
live Supabase session, a platform channel, a real router — **skip it and say so
in a comment**. A screen bent out of shape to satisfy a test is not the screen
users see, and guarding it proves nothing.

## Choosing options

| Option | Default | Turn it on/off when |
| --- | --- | --- |
| `checkTextBleed` | on | Off only for a widget that legitimately paints past the edge — a swipe pane mid-gesture. Horizontal `Scrollable`s are already exempt. |
| `forbidTruncation` | **off** | On for widgets whose *own* labels must survive whole: tab pills, dock captions, stat-tile captions. Leave off where an ellipsis is correct (a person's name). |
| `checkLeakedAnimations` | on | Off only for a subject that deliberately owns an app-lifetime ticker (the shared shimmer driver in `ugam_skeleton.dart`). |
| `scrollThrough` | on | Rarely off. Scrolls each `Scrollable` to its end so content below the fold gets *painted* — an overflow is only reported from `paint()`. |
| `failOnOtherErrors` | on | Off only with a comment. A subject that throws never rendered, so a green result would be a lie. |
| `ignoreErrorsContaining` | `[]` | Sparingly, always with a call-site comment saying why the noise is not the guard's problem. |
| `settleFrames` | 4 | Raise for a slow entrance animation. |

Use `after:` to interact before the check (tap a tab, drag a pane open).

**Never add `pumpAndSettle`.** Several subjects host an indefinite
shimmer/pulse; `pumpAndSettle` would time out on them instead of testing them.
The harness pumps a fixed number of frames on purpose.

## Reading a failure

```
  [overflow] UgamCTA (icon + longest label + trailing amount)
      gu · 375pt · text x1.0 (effective 0.962) · light
      A RenderFlex overflowed by 61 pixels on the right.
      likely owner: UgamCTA
      phase: during layout
      debugCreator: Row ← Padding ← DecoratedBox ← Container ← ⋯
```

`likely owner` is the nearest `Ugam*` ancestor of the render object that
reported — open that file first. The five kinds:

| Kind | Meaning |
| --- | --- |
| `overflow` | `RenderFlex`/`RenderBox` reported `overflowed by N pixels`. |
| `bleed` | A `RenderParagraph` painted outside the device's horizontal bounds — the "pushed off the card" case a `Stack` or a clip hides from `RenderFlex`. |
| `truncation` | Text ellipsised where the caller set `forbidTruncation`. Flutter reports nothing for this. |
| `leakedAnimation` | A ticker was still running after teardown. Not a layout bug, but it is why a run looks like a hang instead of a failure. |
| `error` | Something threw. The subject never rendered, so it is not being guarded. |

## When the guard finds a REAL production bug

Fix the widget. If you cannot right now, mark **that one case** `skip: true`
with a comment naming the file, line, widget and the exact cells that break, and
say what has to change for the skip to come off. Two such cases are live today —
see `UgamTabPills — REAL DEFECT` and `UgamRequestRow — LATENT` in
`components_overflow_test.dart`. A red suite gets ignored within a week; a green
suite with two annotated skips stays actionable.

## The guard is itself under test

`harness_self_test.dart` exists because a layout harness has one interesting
failure mode: **silently detecting nothing**. Flutter reports overflows through
`FlutterError` rather than throwing them, so a harness that captures the wrong
handler, pumps the wrong frame, or never paints the subject reports a clean
sweep over visibly broken UI — forever, because a permanently-green test looks
exactly like a healthy one.

So each case there builds a layout that is *known* to be broken, with a real
Gujarati string, and asserts the harness finds it — plus the isolation
invariants: one fresh `State` per scenario, every tree disposed, teardown errors
blamed on the scenario that owned the tree, diagnostics resolved before unmount,
and each scenario fed its own language.

**If you change `collectOverflow`, run the self-test and make sure it can still
fail.** Comment out the fix you just wrote and watch the relevant case go red. A
guard that has never been seen to fail is not evidence.
