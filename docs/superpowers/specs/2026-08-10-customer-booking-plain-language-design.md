# Plain-language customer booking: a chart that proposes instead of interrogates

**Date:** 2026-08-10
**Status:** Design approved — not yet implemented
**Branch:** `feat/money-collection-settlement`
**Follows:** [2026-08-09 customer chart booking](2026-08-09-customer-chart-booking-design.md) (implemented)

## Problem

The 2026-08-09 work fixed the chart's *mechanics* — tile geometry, motion, the cancelled-while-held
bug, a party gate, multi-bus checkout. All of that holds. But the screen is still unusable for the
person it is for, and the previous spec never questioned the underlying interaction. It made a
technical diagram tidier.

The customer is one person booking a Dwarka or Ambaji pilgrimage for three or four relatives, often
coordinating over WhatsApp, frequently on a cheap phone, usually reading Gujarati. Four things fail
that person:

### 1. Seat codes are engineer output

`SU1` is Single Upper 1. `DL1` is Double Lower 1. Nothing on screen decodes them.

Worse, **upper vs lower berth is the single most consequential seat attribute in Indian sleeper
travel** — an elderly or motion-sick passenger must have a lower berth — and it is encoded in one
letter of a reference code. The chart shows the identifier and hides the fact.

### 2. The most socially loaded decision is a hidden gesture

Tapping a double sofa once takes ONE berth: the customer will share that sofa with a stranger.
Tapping again takes it whole. This cycle is documented in code
(`seat_selection_screen.dart:_tapSeat`) and communicated to the customer by a tile splitting in half.

Sharing a sleeper berth with an unknown person is a significant social decision in this market,
especially for women travelling alone. It is currently expressed by an undiscoverable double-tap and
a ₹1,100-vs-₹2,200 price change the customer must infer.

### 3. Price is invisible until after the choice

Tiles carry no price. The leg pills quote a "from" price for the whole bus. A customer cannot see
that the front rows are a ₹1,600 band and the rest ₹1,400 until the footer total moves.

### 4. The metaphor is wrong for the audience

A spatial seat map is the redBus pattern, built for app-native urban buyers who already know it.
These customers think and speak in seat *kinds and counts* — "બે નીચેની બેઠક જોઈએ", *we need two
lower berths* — which is exactly what request mode's `RequestLine(seatType, qty, leg)` already
models. Chart mode bolted a map on top of a data model that never needed one.

### What the previous spec got wrong

The party gate added by 2026-08-09 made this worse. It asks two questions and then still hands over
the same blank puzzle. It added a step without removing the hard one.

---

## §0 The shape of the fix

**The chart stays the main screen, but it stops being a blank puzzle.** It opens with seats already
chosen, in copper, under a plain-language summary. The customer confirms, or taps to change.

The map becomes a *proposal you can edit* rather than a test you have to pass. This keeps the
geometry, motion and multi-bus work already shipped, and removes the part that actually defeats
people: facing 36 unlabelled cells and being asked to solve them.

### The constraint that shapes everything: no roster

**The auto-pick cannot reuse `SeatingEngine.propose`.** It requires `List<Passenger>` — the full
roster — and the customer app never receives one. There is deliberately no anon SELECT on
`passengers` (see `chart_seat_availability`'s header: it exists precisely so a stranger cannot read
who is sitting where off a public tour).

So the picker is NEW, and works only from what the customer legitimately has: the layout, the
anonymised per-seat availability, the leg, and the party's own answers. It leaks nothing, and being
a pure function over public data it is far easier to test than the engine.

The server still re-validates every seat inside an advisory lock, so a bad or stale pick loses
cleanly rather than double-booking.

## §1 Three plain questions

The existing `PartyGateScreen` is rewritten. It keeps question one and replaces the rest.

| Question | Gujarati | Why |
| --- | --- | --- |
| How many people? | કેટલા લોકો? | Drives everything. Already asked. |
| Any ladies in the group? | બહેનો છે? | Feeds the sharing decision and the lady marker. Gender is already collected at checkout, so this only moves earlier. |
| Willing to share a sofa with a stranger? | અજાણ્યા સાથે સોફો વહેંચવો ચાલશે? | Replaces the hidden double-tap. **No means half-sofas are never offered or auto-picked.** |

**Removed: the same-bus / split question.** With an auto-pick, "together" is simply what the picker
tries first. It only splits across buses when one bus cannot hold the party, and then it says so in
the summary. Asking the customer to predict that was asking them to do the picker's job.

**Not asked: elders / lower berths.** Deliberate — it was considered and cut to keep the gate at
three questions. The picker prefers lower berths anyway, and every tile states upper/lower in words,
so the benefit survives without the question.

## §2 The auto-pick

New pure Dart: `lib/utils/seat_autopick.dart`. No Flutter, no I/O, no wall clock.

```
autoPick({layout, availability, leg, people, hasLadies, shareOk, buses}) → List<ChartBusSelection>
```

Rules, in priority order:

1. **Whole party on one bus.** Only spans buses when no single bus has room, and reports that it did.
2. **Adjacent where possible** — same row, then neighbouring rows. Proximity beats price.
3. **Lower berths first.** Silent, unasked, and the reason the elders question could be cut.
4. **Respect `shareOk`.** When false, only whole sofas and singles are eligible; a half-double is
   never proposed and the tile refuses it on tap too.
5. **Whole sofas for pairs.** An even-sized party prefers whole doubles over scattered singles.
6. **Cheaper first** as the final tie-break only, so it never overrides sitting together.

Returns an empty list when the party cannot be seated; the summary bar then explains the shortfall
instead of showing a silent blank chart.

## §3 The summary bar

Sits above the deck, replacing the party meter added on 2026-08-09.

```
✓ તમારી 3 બેઠક તૈયાર — બધા એક જ ગ્રુપમાં
  2 નીચેની · 1 ઉપરની                    ₹3,300
                                        [ બદલો ]
```

States, in plain words: how many are held, whether they are together, the upper/lower split, the
total, and one way out. When the party had to be split it says which buses, because that is a fact
the customer must not discover at the boarding point.

## §4 Tiles that say what they are

The customer tile grows from 40×42 to **56×52** and carries meaning instead of an identifier.

```
   ┌──────────┐        ┌──────────────────────┐
   │  ▂▂▂▂▂   │        │   ▂▂▂▂▂  સોફા 2 જણ   │
   │   નીચે    │        │        ₹2,200        │
   │  ₹1,400  │        │  અડધો ₹1,100 ચાલશે   │
   │      SU1 │        │                  DU1 │
   └──────────┘        └──────────────────────┘
```

- **Upper/lower in words** (ઉપર / નીચે), plus a berth glyph sitting high or low in the tile.
- **Price on the face**, so band pricing is visible before the tap rather than after.
- **A double sofa is marked "2 જણ"** — it seats two.
- **The seat code is demoted** to small corner text. It still has to match the printed ticket and the
  organiser's chart, so it cannot be deleted — only stop being the headline.

> **Correction made during implementation.** An earlier draft of this section said a double sofa
> should render as ONE WIDE tile "because that is what it physically is". That was wrong.
> `SeatGridCols` puts `doubleUpper` at column 3 and `doubleLower` at column 4, so `DU1` and `DL1` are
> two SEPARATE two-person sofas on different deck levels — not two halves of one. Merging them into a
> wide tile would misrepresent the bus. All tiles keep a uniform footprint; only the label changes.

**Density.** The recorded rule is that spacing tokens were deliberately compressed to a cockpit
density and must not be re-widened. That rule was set for the OPERATOR app. This changes only
`ChartSeatMetrics` — the customer seat tile — and touches no shared token and no operator or handler
chart. Called out because it looks like a violation and is not one.

## §5 Sharing becomes a question

Tapping a double sofa opens a two-line sheet instead of cycling silently:

```
┌────────────────────────────────┐
│  આ સોફો કેવી રીતે લવો છો?       │
│  ( આખો — ફક્ત અમે      ₹2,200 ) │
│  ( અડધો — બીજું કોઈ આવશે ₹1,100 ) │
└────────────────────────────────┘
```

The stranger is named in words, with both prices, before any money is committed. When the gate
answered `shareOk: false` the half option is not shown at all.

This removes the 1→2→off cycle from `_tapSeat` for doubles. Singles stay a plain on/off.

## §6 What is kept from 2026-08-09

Nothing shipped is discarded:

- `ChartSeatMetrics` — kept, values changed. The fixed-footprint invariant and its test still hold.
- `ChartSeatSkeleton`, `availabilityEquals`, the motion work — all unchanged.
- `ChartBasket` and multi-bus checkout — now the auto-pick's output path when a party must split.
- The hold/payment lifecycle (`chart_hold_status`, `HoldCountdownStrip`, migration 067) — untouched.
- `party_fit.dart` — still used by the picker to decide whether a bus can take the party.
- `PartyGateScreen` — rewritten in place, not replaced.

## §7 Testing

- **Pure Dart** — `autoPick` under: party of 1–6; no room; exactly-enough room; `shareOk` false with
  only half-doubles free; ladies present; forced multi-bus split; lower-berth preference; adjacency
  preferred over price.
- **Widget** — chart opens with seats pre-selected; summary bar states the right counts; the share
  sheet offers one option when `shareOk` is false and two when true; tiles report the new footprint
  (extends the existing geometry test rather than replacing it).
- **Regression** — every 2026-08-09 test must still pass unchanged, especially the tile-footprint
  invariant and the tap-cycle tests, which will need updating where the double-tap is deliberately
  replaced by the sheet.

Widget tests using `plural()` must load a locale in `setUpAll`; `tr()` is safe.

## §8 Build order

1. **`seat_autopick.dart`** — pure, fully tested, no UI. The riskiest logic, isolated first.
2. **Tile redesign** (§4) — visible on its own, independent of the picker.
3. **Share sheet** (§5) — replaces the double-tap.
4. **Gate rewrite** (§1) — three questions.
5. **Summary bar + pre-fill** (§3) — wires the picker into the chart.

## §9 Risks

- **A bad auto-pick is worse than none.** If it seats a party apart when it did not need to, trust in
  the whole screen goes. §7's adjacency and lower-berth cases are the guard.
- **Gujarati string width.** "અજાણ્યા સાથે સોફો વહેંચવો ચાલશે?" is long; the tile and sheet layouts
  must be checked at the largest system font on a small phone.
- **Seat codes must remain findable.** The organiser reads `SU1` off their chart and the handler
  calls it out at boarding. Demoting it is safe; hiding it is not.
- **Concurrent agent in this working tree** — re-run before believing any analyze/test failure.
- **Migrations 067 and 068 from the previous spec are still undeployed.** This design adds none.
