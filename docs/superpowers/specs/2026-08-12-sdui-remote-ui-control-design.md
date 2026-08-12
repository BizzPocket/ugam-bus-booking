# Remote UI Control (SDUI) — Design & Feasibility

**Date:** 2026-08-12
**Branch:** `feat/money-collection-settlement`
**App version at writing:** `1.0.23+26`
**Status:** draft, awaiting review

**Goal (user's words):** *"I need each and every block to be SDUI so we can change the entire UI from remote."*

This document decides what that can honestly mean for this app, what it must never mean, and in what order to build it. It is deliberately a *feasibility* document first and an architecture document second, because the request as stated is partly impossible and partly already built — and both of those facts change the plan.

---

## 1. Executive summary

| Question | Answer |
|---|---|
| Can we change **content** (notices, offers, FAQ, stats) remotely? | **Yes — today.** Built, live, empty. |
| Can we change **any wording in the app** remotely? | **Yes — today.** Built, live, nothing published. |
| Can we **turn features off** remotely? | **Almost.** Service built and warmed; no code reads it yet. |
| Can we **restyle / relayout screens** remotely? | **Yes, for a defined set of surfaces.** Needs new work. |
| Can we change **the seat chart, cash collection, or forms** remotely? | **No — and we must not try.** See §4. |
| Can we ship **arbitrary UI changes** with no store release? | **No on iOS. Partly on Android.** See §3. |

**The headline finding:** three of the four remote channels this app needs are already written, wired into `main.dart`, ETag-cached and fail-soft. Every one of them is serving an empty document. The gap between "SDUI does nothing" and "SDUI controls the app" is far smaller than it looks — most of Phase 1 and 2 is *publishing*, not building.

---

## 2. Verified current state

Everything in this section was checked against the live endpoints and the source on 2026-08-12, not inferred.

### 2.1 The three existing channels

All three are compiled in from `config/ota.json` via `--dart-define-from-file`, used by `scripts/build_ios_release.sh:42`. All three treat an empty URL as dormant — no network call, compiled-in defaults. That default is deliberately safe.

| Channel | Config | Service | Live state |
|---|---|---|---|
| Flags | `REMOTE_FLAGS_URL` | `RemoteFlagsService` | `200`, `{"min_supported_build":0,"recommended_build":0,"maintenance_mode":false,"kill":{},"tunables":{}}` |
| Content | `REMOTE_CONTENT_URL` | `RemoteContentService` | `200`, `{"blocks": []}` |
| i18n overlay | `I18N_OVERLAY_BASE_URL` | `RemoteTranslationLoader` / `TranslationOverlaySync` | **`400` — no object published** for gu/en/hi |

### 2.2 Content SDUI — what exists

- **7 block types**, a closed registry: `notice`, `banner`, `link`, `cta`, `faq`, `stat`, `divider` (`content_block.dart:230`).
- **10 slots** declared in `ContentSlots`, named `surface.screen.position`.
- **8 slots wired** into screens. **2 declared but never placed:** `customer.tour_list.empty` and `admin.home.top`.
- **Rich targeting already in the model** (`BlockTargeting`): platform, `minBuild`/`maxBuild`, locale, role, and a `from`/`to` time window. Evaluated client-side against facts the app already knows, so targeting costs no round trip and works offline.
- **Renderer** `content_block_view.dart` (349 lines) maps every type onto the Ugam design system — `UgamCTA`, `UgamExpander`, `UgamHeroStat`.
- **A worked example document** exists at `config/ota-publish/content.sample.json`, covering every type, slot and targeting rule, written in Gujarati.
- **Tests:** `test/models/content_block_test.dart`.

### 2.3 Flags — what exists

`RemoteFlags` already models everything Phase 2 needs:

```dart
int minSupportedBuild;   // hard update gate
int recommendedBuild;    // soft nudge
bool maintenanceMode;
Map<String, bool> kill;  // isKilled('feature')
Map<String, num> tunables; // tunable('name')
```

The **launch gate is wired** — `LaunchBlockOverlay` wraps the app at `app.dart:102`, and the service is registered permanent at `app.dart:121`.

**`isKilled()` and `tunable()` have zero call sites.** The switches exist and reach the device; nothing asks them anything. That is the whole of Phase 2.

### 2.4 A duplicate registry exists and must be resolved

`lib/models/content_slot_id.dart` is untracked, referenced by nothing, and declares a **second, competing** slot registry whose names have already drifted from the live one (`customerRequestsTop` vs the real `customerMyRequestsTop`). Two registries is how somebody publishes to a slot name that silently never renders. It is deleted in Phase 1.

---

## 3. Feasibility: the hard limits

This section exists because the goal as stated — *change the entire UI from remote* — runs into three walls that no amount of architecture removes.

### 3.1 Store policy

Apple **App Store Review Guideline 2.5.2** prohibits downloading and executing code that changes the app's features or functionality. Declarative content interpreted by already-shipped code is fine and is what every major app does; shipping a new *program* is not.

**Consequence:** the server may describe *what to show using components the binary already contains*. It may never deliver behaviour. This is not a limitation we can engineer around — it is the boundary the design must sit inside. Every phase below stays on the legal side of it by construction: the server sends data, the app owns all logic.

### 3.2 Code push is already ruled out

Shorebird was evaluated on 2026-08-09 and found **non-viable for iOS**. The prior OTA analysis put ~55.6% of changes as shippable via the channels above and ~20.2% blocked behind translations and assets. Nothing in this design revisits that; it takes it as settled.

**Consequence:** a genuine layout change to a surface with no SDUI coverage requires a store release. The way to reduce release frequency is to *increase coverage* (Phase 3), not to find a code-push loophole.

### 3.3 Offline is a product requirement, not a nice-to-have

Handlers run buses through rural Gujarat with intermittent or absent signal. `content_block.dart:25` records the decision already taken:

> *"the chart geometry, the collect sheet and the handover form stay native: handlers work offline on moving buses, and a surface that must be fetched cannot render at all without signal."*

**Consequence:** any surface a handler needs mid-trip must render correctly from the binary alone, with zero successful fetches, forever. Remote content may *decorate* those surfaces; it may never be required to draw them.

### 3.4 What follows from all three

| Layer | Remotely changeable? | Mechanism |
|---|---|---|
| Text of any string | ✅ fully | i18n overlay |
| Content blocks in slots | ✅ fully | content.json |
| Feature on/off, numeric knobs | ✅ fully | flags.json |
| Section order, visibility, tone within a screen | ✅ (Phase 3) | layout.json |
| Which components exist at all | ❌ | requires a release |
| Business logic, validation, money math | ❌ **by design** | must never be remote |
| Seat chart geometry, collect sheet, handover form | ❌ **by design** | offline floor (§4) |

---

## 4. The native floor

A permanent, non-negotiable list of surfaces that stay native regardless of how far SDUI expands. This exists so a future phase cannot quietly erode it.

1. **Seat chart geometry** — the grid, tiles, availability painting, tap handling.
2. **Cash collection sheet** — recording money offline is the handler's core job.
3. **Handover form** — settlement integrity.
4. **All money arithmetic** — fares, splits, ledger, P&L.
5. **All validation and write paths** — anything that decides whether a booking is legal.

These may be *decorated* by a content slot above or below them. They may never *depend* on a fetch to render.

**Rule of thumb for any future slot:** if a handler with a dead connection on a moving bus cannot do their job without this rendering, it does not go remote.

---

## 5. Architecture

### 5.1 Four channels, one shape

All four channels share the same proven shape, already implemented twice in this repo (`cached_remote_document.dart` generalises it):

```
public bucket object  ──HTTP GET (ETag)──►  fetch with timeout
                                             │
                                    ┌────────┴────────┐
                                    │ 200: parse      │  304 / error / timeout
                                    │ validate size   │        │
                                    │ cache to prefs  │        ▼
                                    └────────┬────────┘   use last-good cache,
                                             │            else compiled-in default
                                             ▼
                                    render, fail-soft
```

Invariants every channel keeps, and Phase 3 must keep too:

- **Dormant when unconfigured.** Empty URL ⇒ no network call at all.
- **Size-capped.** 32 KB flags/content, 64 KB i18n. A wrong file is refused, not cached.
- **Tolerant parsing.** Unknown keys ignored; wrong-typed values fall back to default; a malformed document never throws.
- **Closed registries.** Unknown block type or slot name is skipped, never rendered. This is what lets you publish for a new release without breaking old installs.
- **Never on the critical path.** Boot does not await a fetch.

### 5.2 Channel responsibilities

| Channel | Owns | Does not own |
|---|---|---|
| `flags.json` | whether a feature runs, numeric knobs, update gate | anything visual |
| `i18n/*.json` | the words | where words appear |
| `content.json` | additive blocks in declared slots | existing native widgets |
| `layout.json` *(Phase 3)* | order/visibility/tone of **existing native sections** | creating new components |

The Phase 3 boundary is the important one: **`layout.json` rearranges sections the binary already has. It never invents UI.** That keeps it inside §3.1 and preserves an offline fallback — with no document, every screen renders its compiled-in default order.

### 5.3 Phase 3 model sketch

```
ScreenLayout {
  screen: 'admin.tour_detail',   // closed registry, like slots
  sections: [
    { id: 'money_summary', visible: true,  order: 0, tone: 'neutral' },
    { id: 'bus_list',      visible: true,  order: 1 },
    { id: 'pnl_hero',      visible: false, order: 2 },   // hidden remotely
  ],
  when: { platforms, minBuild, maxBuild, locales, roles, from, to }
}
```

Each screen registers its sections by stable id. The screen renders `sections` in the given order, skipping unknown ids and appending any registered-but-unlisted section at the end — so a section added in a later build still appears for clients on an older document. `BlockTargeting` is reused verbatim; it is already the right shape.

---

## 6. Phasing and rationale

Ordered so each phase de-risks the next and ships value on its own.

### Phase 1 — Content & copy (no new architecture)

**Why first:** it is the only phase that needs no new code paths, and it proves the publish pipeline end-to-end. Until a document has gone from repo → bucket → device → screen once, every later phase is building on an unverified assumption.

Author real blocks; wire the 2 orphan slots; publish an i18n overlay; delete the duplicate registry; write the operator runbook.

### Phase 2 — Flags (small code, large safety win)

**Why second:** it needs the pipeline Phase 1 proves, and it is the highest safety-per-line work in the project. It converts "we must ship a build to stop this" into "we edit a JSON."

Concretely: it is how you pause customer seat choice without a release — the thing originally wanted as a code-level gate.

### Phase 3 — Layout SDUI (new architecture)

**Why last:** it is the only phase with real risk, and both earlier phases reduce it — Phase 1 proves publishing, Phase 2 provides the kill switch that turns layout control off if a published document misbehaves. Building this first would mean weeks before anything is remotely controllable, with no safety net.

Scoped to the safe surfaces in §4's complement.

---

## 7. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| A bad document breaks a screen for every install | High | Closed registries + tolerant parsing + size cap already enforce this. Phase 2 adds `kill: {"remote_layout": true}` as the panic switch. Reverting = re-upload the previous file; it reaches every client. |
| Layout SDUI erodes the native floor over time | High | §4 is explicit and permanent; every new slot/section is checked against the offline rule of thumb. |
| Store review objects to remote layout | Medium | Data-only, components ship in the binary, no behaviour delivered (§3.1). |
| Two slot registries diverge | Medium | Resolved in Phase 1 by deleting `content_slot_id.dart`. |
| Operator publishes malformed JSON | Medium | Sample document + runbook + a validator script in Phase 1. |
| Stale cache after a bad publish | Low | ETag + 15-minute minimum fetch interval; a corrected file propagates within one interval. |

---

## 8. Success criteria

- **Phase 1:** a block authored in the repo renders on a real device without a rebuild; changing one string via the overlay changes it in the app; `content_slot_id.dart` gone; 10/10 slots placed.
- **Phase 2:** `isKilled()` gates at least the seat-choice entry points, and flipping the flag pauses customer seat selection on a live install with no release.
- **Phase 3:** at least one screen's section order and visibility are controlled by `layout.json`, and with the document absent that screen renders exactly as it does today.

**Global invariant, checked every phase:** with all four documents deleted, the app must behave exactly as it does now.

---

## 9. Non-goals

- Code push / Shorebird (§3.2).
- Remote business logic, validation or money math (§4).
- Remote control of seat chart geometry, collect sheet, handover form (§4).
- A visual editor for operators. Documents are hand-edited JSON with a validator; a UI for authoring is a separate project if it is ever wanted.
- Percentage rollouts / A-B testing. `RemoteFlagsConfig` already notes the fetcher is swappable for Firebase Remote Config if that is wanted later; it is not in scope here.
