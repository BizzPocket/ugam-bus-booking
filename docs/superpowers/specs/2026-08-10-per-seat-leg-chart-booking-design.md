# Per-seat legs: the chart stops assuming everyone comes back

**Date:** 2026-08-10
**Status:** Design approved — not yet implemented
**Branch:** `feat/money-collection-settlement`
**Follows:** [2026-08-10 plain-language customer booking](2026-08-10-customer-booking-plain-language-design.md) (implemented, `f6e4df6`)

## Problem

Three faults, reported from a real run through the chart flow.

### 1. The count has no leg

`PartyGateScreen` asks "how many people?" and nothing else about the journey. The leg is chosen
*afterwards*, on the chart, by pills that default to round-trip — and switching them **wipes the
selection** ([`seat_selection_screen.dart:536`](../../../lib/screens/seat_selection_screen.dart)).

So a party of four where two stay back with relatives cannot be expressed at all. The whole basket
carries one `TripType`, from `_leg` in the screen state right down to
`chart_claim_seats_multi(p_leg text, …)`, which stamps that single value onto every seat assignment
and every request line ([`068_multi_bus_chart_claim.sql`](../../../supabase/migrations/068_multi_bus_chart_claim.sql)).

**Request mode does not have this limitation.** `RequestLine` carries its own `leg`, and
`booking_requests.trip_type` is already a *derived summary* of the per-line legs
(`summaryTripTypeOf`, [`round_trip_combine.dart:80`](../../../lib/utils/round_trip_combine.dart)).
Chart mode is the odd one out, and the read path in `customer_requests_store.dart:376` already knows
how to keep a per-seat leg when the server stamps one. The plumbing exists; only the chart's write
path assumes uniformity.

### 2. The ladies question is decoration

The gate collects `hasLadies`, threads it through `PartyIntent`, hands it to `autoPick` — and
`autoPick` never reads it. Only `shareOk` affects the picking
([`seat_autopick.dart:246`](../../../lib/utils/seat_autopick.dart)). A question that changes nothing
is a tax on the customer.

### 3. A whole sofa still costs two taps

The 2026-08-10 work replaced the hidden 1→2→off cycle with an explicit whole/half sheet
([`seat_selection_screen.dart:291`](../../../lib/screens/seat_selection_screen.dart), shipped in
`f6e4df6`). That fixed the *discoverability* problem and was the right call. It did not fix the
*effort* problem: a family taking a whole sofa still taps the tile, reads a sheet, and taps again —
to answer a question whose answer was already implied by the party size.

---

## §0 The shape of the fix

**The leg stops being a property of the booking and becomes a property of each seat** — in the gate,
in the picker, in the basket, in the claim payload, and in Postgres.

Everything else follows from that one move. The gate learns to ask for a split; the picker packs one
bucket at a time; the leg pills demote from "what am I buying" to "which map am I looking at"; and
the sofa sheet appears only where the answer is genuinely unknown.

### Decisions taken, and what was rejected

| Decision | Chosen | Rejected |
| --- | --- | --- |
| How legs are asked | Total first, then "everyone both ways?", split block only on "no" | Three always-visible bucket counts (taxes the ~90% all-round-trip case); go/return counts with the overlap inferred (cannot express 4 go-only *and* 2 different return-only people) |
| The ladies question | Removed | Making it gate the sharing (lady-only half-sofas); merging both into one three-way sharing question |
| Leg pills on the chart | Become view tabs; selection survives switching | Single map with a per-tap leg sheet; a two-step go-then-return wizard |
| Whole-sofa tap | One tap when the party still needs ≥2 berths | Always one tap with sharing demoted to a tile chip; keeping the sheet unconditionally |
| Carrying the leg to the server | Extend the existing functions additively | A `_v2` RPC; splitting into one claim per leg bucket client-side |

---

## §1 The gate

`PartyGateScreen` stays **one scrolling screen with progressive reveal**. No new navigation, no back
stack for a customer who is not confident with apps — the split block simply appears when it becomes
relevant.

```
કેટલા લોકો?                      [1][2][3][4][5][6]

બધા બંને બાજુ જાવ-આવ કરશે?            ( હા )  ( ના )
   ↓ revealed only on "ના"
   બંને બાજુ                    [0][1][2][3][4]
   ફક્ત જવાના                  [0][1][2][3][4]
   ફક્ત પાછા આવવાના             [0][1][2][3][4]
   ────────────────────────────
   must total the number above

અજાણ્યા સાથે સોફો વહેંચવો ચાલશે?      ( હા )  ( ના )
```

**Validation.** The three bucket counts must sum to the headline count. Until they do, the CTA is
disabled and the mismatch is stated in words ("૧ વ્યક્તિ બાકી છે"), not by a silent dead button.

Answering "હા" sets `roundTrip = people` and zeroes the other two. Answering "ના" starts all three
buckets at **zero**, not pre-filled — a pre-filled split is already valid, so the customer could walk
past the question without answering it, which is the exact failure this screen exists to prevent.
Changing the headline count re-zeroes the buckets.

`PartyIntent` is rewritten. `hasLadies` is **deleted outright** — gender is still collected at
checkout, and the lady marker on the chart is read from occupancy data, so nothing else depends on
it.

```dart
class PartyIntent {
  final int roundTrip;
  final int outboundOnly;
  final int returnOnly;
  final bool shareOk;

  int get people => roundTrip + outboundOnly + returnOnly;

  /// Deep link / returning rider: one traveller, both ways, willing to share.
  static const solo = PartyIntent(roundTrip: 1);
}
```

**Accepted trade-off:** with the ladies question gone, a half-sofa carries no gender guarantee. The
sheet still names the stranger in words before any money moves, and `shareOk: false` remains the way
to refuse sharing entirely.

## §2 The picker

`autoPick` takes the intent and runs **three passes, most-constrained first**:

1. `roundTrip` — packed first because it is hardest to satisfy: the berth must be free on **both**
   legs. `freeBerths(leg: TripType.roundTrip)` already computes exactly this.
2. `outboundOnly`
3. `returnOnly`

Each pass sees that bucket's leg availability, and excludes every cell an earlier pass already took.
A bucket with a count of zero is skipped entirely. Within a pass, every existing rule survives
unchanged: whole party on one bus, adjacent where possible, lower berths first, whole sofas for
pairs, cheaper only as the final tie-break. The `hasLadies` parameter is removed from the signature.

**The return type changes.** `autoPick` currently returns `List<ChartBusSelection>` and signals
failure with an empty list, which the screen reads into a single `_noRoom` flag. A per-bucket
shortfall cannot be expressed that way, so it returns a small result object instead:

```dart
class AutoPickResult {
  final List<ChartBusSelection> selections;

  /// Berths the picker could NOT place, per bucket. Empty when everyone fits.
  final Map<TripType, int> shortfall;
}
```

If any bucket cannot be seated, the partial selection is still returned and the summary bar states
the gap in that leg's words — "પાછા આવવા માટે ૨ બેઠક નથી" — rather than showing a blanket empty
chart. `_noRoom` is replaced by `shortfall.isNotEmpty`.

**Deliberate simplification: one tile is always one person.** `seating_engine.dart:25-28` correctly
notes that disjoint legs may reuse the same physical berth (an outbound-only and a return-only
passenger can share one). The customer picker will **not** exploit this. Reuse would put two
different people on one tile across two tabs, and would make the claim payload carry duplicate
`seatId`s that the server's uniqueness handling was never written for. Berth reuse stays what it is
today: the operator's optimisation, via `SeatingEngine`.

## §3 The chart

`_leg` is renamed `_viewLeg` and demoted to a view filter.

- **A tab appears only when it has a bucket to fill.** The **જવાનું** tab is present when
  `roundTrip + outboundOnly > 0`; the **આવવાનું** tab when `returnOnly > 0`. A return-only party
  therefore sees one map and no tab strip at all, exactly like a round-trip party does today.
- **Switching tabs no longer clears `_basket`.** This is a behaviour change, not a refactor.
- A round-trip seat renders on **both** tabs, carrying a small **બંને** mark. Untapping it on either
  tab removes it from both — it is one berth on one booking.
- Tap fill order on the go tab: fill the `roundTrip` bucket first, then `outboundOnly`. The return
  tab fills `returnOnly` only.
- Availability per tab is computed against that tab's leg, except round-trip picks, which are
  computed against `TripType.roundTrip` so they are only offered where both legs are free.

The summary bar states the mix in words: `2 બંને · 2 ફક્ત જવાના`.

## §4 The sofa

Inside `_tapSeat`, for a cell of capacity 2, after the existing `free > 0` guard:

```
shareOk == false          → wanted = 2, no sheet    (already true today)
berths still needed >= 2  → wanted = 2, no sheet    ← the fix
otherwise                 → sheet: આખો ₹2,200 / અડધો ₹1,100
```

**"Berths still needed" is per bucket, not global.** It counts the berths outstanding in the bucket
*this tap will fill* — the one resolved by §3's fill order — because that is the bucket this sofa can
serve. A party of 4 with 1 round-trip berth left and 3 go-only berths left must still be asked
whole-or-half when it taps a sofa on the round-trip fill, since only one of its berths can go there.
Using the global remainder would silently take a whole sofa and overshoot the bucket.

The sheet therefore survives exactly one case: the bucket being filled has a single berth left, so
whole-or-half is a real question. Separately, when `free == 1` because someone already holds the
other berth, the whole option is impossible and the sheet appears with `someoneAlreadyThere: true`
regardless of how many berths remain.

The stale docstring above `_tapSeat` still describes the removed 1→2→off cycle
([`seat_selection_screen.dart:249-254`](../../../lib/screens/seat_selection_screen.dart)) and is
corrected as part of this work.

## §5 The server — migration 089

**Approach: extend the existing functions in place, additively.** Every seat in the payload *may*
carry its own `leg`; the function resolves it as `coalesce(seat->>'leg', p_leg)`. A client that omits
it — every build currently on the Play Store — gets today's behaviour unchanged. No signature
change, so no grant/revoke churn and no `to_regprocedure` probing on the client.

Three functions change:

| Function | Change |
| --- | --- |
| `chart_validate_bus_seats` | `v_wants_go` / `v_wants_ret` computed **per seat** from its resolved leg, not once from `p_leg` |
| `chart_claim_seats_multi` | `request_lines` grouped by (type, position, **leg**); `assigned_seats` stamped with each seat's own leg; `booking_requests.trip_type` written as the derived summary — round-trip if any seat is round-trip or the legs are mixed, else the single shared value (mirrors `summaryTripTypeOf`) |
| `chart_hold_seats` | Same per-seat resolution, so the advance-paying path does not silently flatten the legs |

Client side, `ChartPick` gains a `leg`; `requestLinesFor` and `assignmentsFor` group by it instead of
taking one; `toClaimMap` emits `{seatId, berths, leg}`.

**Why not the alternatives.** A `_v2` RPC means version sprawl, client probing, and two code paths
that must stay correct together. Splitting into one claim per leg bucket needs no migration at all,
but it is not atomic: the return-only claim can fail *after* the go claim has already created a
booking row, leaving a customer half-booked with no way back. Rejected on that alone.

## §6 Pricing

`_total` applies `Bus.tripFactor(pick.leg)` per pick rather than one global factor —
`tripFactor` is 1.0 for round-trip and 0.5 for a single leg
([`bus_details.dart:502`](../../../lib/models/bus_details.dart)). `_berthPrice` gains a leg argument.
The leg pills lose their "from ₹X" role when they become view tabs; the mixed total lives in the
summary bar, which is now the only place a total is quoted.

## §7 Testing

**Pure Dart — `autoPick`:** every bucket combination including all-zero-but-one; a split whose sum
matches the headline; room on the go leg but not the return (asserting `shortfall` names the return
bucket and the go picks survive); `shareOk: false` with only half-doubles free; round-trip packed
before one-way; no cell used by two passes; everyone fits ⇒ `shortfall` is empty.

**Pure Dart — `chart_selection`:** `requestLinesFor` groups by (type, position, leg) and emits one
line per distinct leg; `assignmentsFor` stamps each pick's own leg; `claimPayload` carries `leg`;
`summaryTripTypeOf`-equivalent derivation for a mixed basket.

**Widget:** the split block appears only on "ના" and blocks the CTA until the counts sum; the return
tab is absent when `returnOnly == 0`; switching tabs preserves the basket; a round-trip seat shows on
both tabs and untaps from both; one tap takes a whole sofa when ≥2 berths remain **in the bucket
being filled** and opens the sheet when 1 remains, including the case where the global remainder is
larger than the bucket's.

**Regression:** every existing test must pass. The ones asserting `hasLadies`, the single-leg claim
payload, and the unconditional sofa sheet are updated, not deleted — each replaced by its per-leg
equivalent.

Widget tests using `plural()` must load a locale in `setUpAll`; `tr()` is safe.

## §8 Build order

1. **`PartyIntent` + gate** (§1) — pure model change plus one screen, no server dependency.
2. **`autoPick` three-pass rewrite** (§2) — pure Dart, fully tested before any UI consumes it.
3. **`ChartPick.leg` + `chart_selection`** (§5, client half) — still pure Dart.
4. **Chart tabs + basket survival + per-pick pricing** (§3, §6).
5. **Sofa tap rule** (§4) — smallest change, independent of everything above.
6. **Migration 089** (§5, server half) — last, because it is the only step that cannot be reverted by
   a rebuild.

## §9 Risks

- **Deployment blocker.** Migrations 067 and 068 are staged but **not deployed**. 089 extends 068's
  functions and cannot land before them. Verify the live DB state before writing 089, do not assume.
- **Old clients must be proven unaffected**, not assumed. The `coalesce` fallback is the entire
  backward-compatibility story for the 1.0.21 builds already on the stores; it needs an explicit test
  that a payload with no per-seat `leg` produces byte-identical rows to today.
- **The 6-berth cap counts cells, not berths** (`_maxSeats = 6`, and migration 048 caps
  `jsonb_array_length(p_seats) > 6`). These were already two different rules; mixed legs must not
  widen the gap between them.
- **A wrong split is worse than no split.** If the picker seats a go-only passenger on a round-trip
  berth, the customer pays double for a leg they never take. §7's "no cell used by two passes" case
  is the guard.
- **Gujarati string width.** "બધા બંને બાજુ જાવ-આવ કરશે?" and the three bucket labels must be checked
  at the largest system font on a small phone.
- **Concurrent agent in this working tree** — re-run before believing any analyze or test failure.
