# Remote UI Control (SDUI) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** [`2026-08-12-sdui-remote-ui-control-design.md`](../specs/2026-08-12-sdui-remote-ui-control-design.md)

**Goal:** Bring every remotely-controllable surface of the app under four published documents, in an order where each phase de-risks the next, without ever breaking an offline handler.

**Tech Stack:** Flutter/Dart, GetX, easy_localization (en/gu/hi), Supabase Storage (public buckets), `flutter_test`.

---

## Global constraints

- **Flutter is not on PATH.** Use `C:/src/flutter/bin/flutter` for every `flutter` / `dart` command.
- **All three locales change together.** Any new `tr()` key goes into `en.json`, `gu.json` and `hi.json` in the same commit. Parity is currently 2596 keys each — keep it exact.
- **Gujarati is the default locale** and must never fall back to English.
- **A concurrent agent edits this working tree.** Re-run any `flutter analyze` / `flutter test` failure once before believing it. Always `git add` explicit paths — never `git add -A`.
- **Never break the dormant default.** With every document absent or empty, the app must behave exactly as it does today. This is asserted by test in P1.7 and re-asserted in P2.6 and P3.8.
- **Closed registries.** An unknown slot, block type, screen id or section id is *skipped*, never rendered and never fatal.
- **Nothing on the boot path awaits a fetch.**
- **Do not put behaviour in a document.** Documents carry data; the binary owns all logic (spec §3.1).

---

## Dependency graph

```
P1.1 delete duplicate registry
  └─► P1.2 wire 2 orphan slots
        └─► P1.3 author content.json
              ├─► P1.5 validator script
              └─► P1.6 publish + device verify ◄── P1.4 publish i18n overlay
                    └─► P1.7 dormant-default test
                          └─► P1.8 operator runbook
                                │
                                ▼
                          P2.1 flag registry ──► P2.2 gate seat choice
                                                   └─► P2.3 gate remaining features
                                                         └─► P2.4 tunables
                                                               └─► P2.5 publish + verify
                                                                     └─► P2.6 dormant re-assert
                                                                           │
                                                                           ▼
                                                    P3.1 ScreenLayout model ──► P3.2 section registry
                                                          └─► P3.3 layout service
                                                                └─► P3.4 SectionHost widget
                                                                      └─► P3.5 pilot screen
                                                                            └─► P3.6 rollout
                                                                                  └─► P3.7 kill switch
                                                                                        └─► P3.8 final verify
```

**Hard ordering rules:**

- **P2 requires P1.6.** Flags are useless if publishing is unproven — you would be debugging two unknowns at once.
- **P3 requires P2.7** (the `remote_layout` kill switch, delivered in P2.3). Layout SDUI must ship with its own off-switch already live, or a bad document has no remedy short of a store release.
- **P1.4 is independent of P1.1–P1.3** and may run in parallel; it only joins at P1.6.

---

# PHASE 1 — Content & copy

**Why this phase exists:** it needs no new architecture and it proves the publish pipeline. Until one document has travelled repo → bucket → device → screen, every later phase rests on an unverified assumption.

**Exit criteria:** a block authored in the repo renders on a real device with no rebuild; one string changed via overlay changes in the app; 10/10 slots placed; duplicate registry gone.

---

### P1.1 — Delete the duplicate slot registry

**Depends on:** nothing.
**Why:** `lib/models/content_slot_id.dart` is untracked, referenced by nothing, and its names have already drifted from the live `ContentSlots` (`customerRequestsTop` vs the real `customerMyRequestsTop`). Two registries is how someone publishes to a slot that silently never renders. Resolve before authoring any content against slot names.

**Files:** Delete `lib/models/content_slot_id.dart`.

- [ ] **Step 1:** Confirm it is still unreferenced — `grep -rn "ContentSlotId" lib/ test/`. Expected: matches only inside the file itself.
- [ ] **Step 2:** Delete the file.
- [ ] **Step 3:** `C:/src/flutter/bin/flutter analyze` — expect zero errors.
- [ ] **Step 4:** Commit: `chore(sdui): drop the duplicate slot registry`

---

### P1.2 — Place the two orphan slots

**Depends on:** P1.1.
**Why:** `customer.tour_list.empty` and `admin.home.top` are declared in `ContentSlots` but never rendered. The first is the highest-value slot in the app — its own docstring says *"an empty screen is a wasted one"* — and an empty tour list is exactly when a customer most needs to be told something.

**Files:**
- Modify `lib/screens/customer_tour_list_screen.dart` — render `ContentSlot(ContentSlots.customerTourListEmpty)` in the empty state, *instead of* the stock empty widget when the slot has blocks, falling back to the stock widget when it does not.
- Modify the admin home screen (`lib/screens/dashboard_screen.dart`) — `ContentSlot(ContentSlots.adminHomeTop)` above existing content.
- Test: `test/screens/content_slot_placement_test.dart` (create).

**Interfaces:** consumes `ContentSlot` / `ContentSlots`; produces no new API.

- [ ] **Step 1:** Write the failing test — with no blocks the stock empty state still shows; with a block for that slot, the block shows.
- [ ] **Step 2:** Run it; expect failure.
- [ ] **Step 3:** Implement both placements.
- [ ] **Step 4:** `flutter test` + `flutter analyze` — green, zero errors.
- [ ] **Step 5:** Commit: `feat(sdui): place the empty-state and admin-home slots`

---

### P1.3 — Author the real content document

**Depends on:** P1.2 (all 10 slots must exist before authoring against them).
**Why:** the entire feature currently delivers nothing because `content.json` is `{"blocks": []}`. This is the task that turns infrastructure into product.

**Files:** `config/ota-publish/content.json`.

**Content decisions required from the operator** — this task is blocked on real copy, not code. Draft in Gujarati first (default locale), then en/hi.

- [ ] **Step 1:** Read `config/ota-publish/content.sample.json` — it already demonstrates every type, slot and targeting rule.
- [ ] **Step 2:** Author blocks for at minimum: `customer.tour_list.top` (a live announcement), `customer.tour_list.empty` (what to do when no tours), `customer.my_requests.empty` (how to book), `customer.more.top` (support contact).
- [ ] **Step 3:** Use `when` targeting on at least one block, to exercise it — e.g. a festival notice with `from`/`to`.
- [ ] **Step 4:** Keep the document under 32 KB (`RemoteContentConfig.maxBytes`).
- [ ] **Step 5:** Commit: `content(sdui): the first real content document`

---

### P1.4 — Publish an i18n overlay

**Depends on:** nothing (parallel with P1.1–P1.3).
**Why:** the overlay channel is built and configured but **no object exists** — `i18n/gu.json` returns `400`. Until one is published, "fix wording remotely" is untested.

**Files:** `config/ota-publish/i18n/gu.json` (create), plus `en.json`, `hi.json`.

- [ ] **Step 1:** Create a minimal delta — a single leaf override, e.g. one `chart_summary` string. The loader merges recursively, so a delta may override one leaf without restating the file.
- [ ] **Step 2:** Keep each under 64 KB (`TranslationOverlayConfig.maxBytes`).
- [ ] **Step 3:** Upload to the `i18n` bucket as `gu.json` / `en.json` / `hi.json`.
- [ ] **Step 4:** Verify each returns `200` — currently `400`.
- [ ] **Step 5:** Commit the repo copies: `content(i18n): first published overlay delta`

---

### P1.5 — Document validator script

**Depends on:** P1.3.
**Why:** documents are hand-edited JSON published straight to production. One malformed file reaches every install. A validator that runs before upload is the cheapest possible guard.

**Files:** `scripts/validate_ota_docs.dart` (create).

**Validates:** JSON parses; size under cap; every `slot` is in `ContentSlots.all`; every `type` is in `ContentBlock.knownTypes`; every `tone` in `knownTones`; block `id`s unique; `from` < `to` where both present.

- [ ] **Step 1:** Write the script, reading the registries from `lib/models/content_block.dart` so it cannot drift.
- [ ] **Step 2:** Run against `content.sample.json` — expect pass; against a deliberately broken fixture — expect a clear failure naming the offending block id.
- [ ] **Step 3:** Commit: `tools(sdui): validate a content document before publishing`

---

### P1.6 — Publish and verify on a real device

**Depends on:** P1.3, P1.4, P1.5.
**Why:** this is the task the whole phase exists for. Nothing is proven until a document renders on hardware.

- [ ] **Step 1:** Run the validator over `config/ota-publish/content.json`.
- [ ] **Step 2:** Upload to the `app-config` bucket as `content.json`.
- [ ] **Step 3:** Confirm `curl` returns the new document.
- [ ] **Step 4:** On a device with a build carrying `--dart-define-from-file=config/ota.json`, open the customer tour list. The block renders.
- [ ] **Step 5:** Change one word in the document, re-upload, confirm it reaches the device within the fetch interval.
- [ ] **Step 6:** Confirm the overlay string from P1.4 shows in Gujarati.
- [ ] **Step 7:** Record the round-trip latency observed, in the runbook (P1.8).

---

### P1.7 — Dormant-default regression test

**Depends on:** P1.6.
**Why:** the single most important invariant in this whole design — with every document empty or absent, the app behaves exactly as today. It must be a test, not a promise, because every later phase can break it.

**Files:** `test/services/ota_dormant_test.dart` (create).

- [ ] **Step 1:** Assert: empty URL ⇒ `RemoteContentConfig.enabled == false`, `RemoteFlagsConfig.enabled == false`, `TranslationOverlayConfig.enabled == false`.
- [ ] **Step 2:** Assert an empty `{"blocks":[]}` document renders no blocks and every slot falls back to its native default.
- [ ] **Step 3:** Assert a *malformed* document does not throw and leaves defaults intact.
- [ ] **Step 4:** `flutter test` green.
- [ ] **Step 5:** Commit: `test(sdui): the app is unchanged when every document is empty`

---

### P1.8 — Operator runbook

**Depends on:** P1.6, P1.7.
**Why:** the person publishing will not be the person who wrote this. `config/ota-publish/README.md` documents the mechanism but not the *procedure*.

**Files:** extend `config/ota-publish/README.md`.

- [ ] **Step 1:** Document: validate → upload → verify → how to revert (re-upload the previous file; it reaches every client).
- [ ] **Step 2:** Document the propagation delay measured in P1.6 Step 7.
- [ ] **Step 3:** Document the slot catalogue — all 10, with a sentence on what each is for.
- [ ] **Step 4:** Commit: `docs(sdui): operator runbook for publishing`

---

# PHASE 2 — Remote flags

**Why this phase exists:** `RemoteFlagsService` is built, warmed and reaching devices; `isKilled()` and `tunable()` have **zero call sites**. The switches exist and nothing asks them anything. This is the highest safety-per-line work available.

**Depends on:** P1.6 — do not debug flags and publishing simultaneously.

**Exit criteria:** flipping a flag pauses customer seat choice on a live install with no release.

---

### P2.1 — Define the flag registry

**Depends on:** P1.6.
**Why:** flag names are a published contract. A renamed flag silently stops working — the same failure mode as a renamed slot. They need one declared home, like `ContentSlots`.

**Files:** `lib/config/feature_flags.dart` (create).

**Produces:** `class FeatureFlags` with `static const String` names, and a `Set<String> all`.

Initial set: `customer_seat_choice`, `customer_online_payment`, `handler_location_tracking`, `remote_layout` (reserved for P3.7), `whatsapp_sending`.

- [ ] **Step 1:** Create the registry with a docstring per flag stating what turning it off *does to the user*.
- [ ] **Step 2:** Commit: `feat(flags): declare the feature-flag registry`

---

### P2.2 — Gate customer seat choice

**Depends on:** P2.1.
**Why:** this is the concrete thing originally wanted — pausing customer seat selection — and it is the proof the mechanism works. Doing it as a flag rather than a code gate means it can be undone without a release.

**Files:** modify `lib/screens/customer_tour_detail_screen.dart` (sticky CTA, ~line 913), `lib/screens/customer_tour_list_screen.dart` (one-tap Book, ~line 261).

**Behaviour when killed:** chart-mode tours fall back to the legacy request flow — `CustomerBookingRequestScreen` — which is already the default for every non-chart tour. The customer can still book; they simply do not pick their own seat.

- [ ] **Step 1:** Write failing tests: with the flag killed, both entry points route to the request form even for `BookingMode.chart`.
- [ ] **Step 2:** Run; expect failure.
- [ ] **Step 3:** Implement, reading `Get.find<RemoteFlagsService>().isKilled(FeatureFlags.customerSeatChoice)` with a registered-check so tests without the service still pass.
- [ ] **Step 4:** `flutter test` + `flutter analyze`.
- [ ] **Step 5:** Commit: `feat(flags): customer seat choice can be paused remotely`

---

### P2.3 — Gate the remaining features

**Depends on:** P2.2.
**Why:** one gate proves the pattern; the rest make it useful. Includes `remote_layout`, which P3 requires to exist *before* it ships.

- [ ] **Step 1:** Gate online payment, WhatsApp sending, handler location tracking, each with a test.
- [ ] **Step 2:** Add the `remote_layout` flag read (no consumer yet — P3.7 wires it).
- [ ] **Step 3:** `flutter test` + `flutter analyze`.
- [ ] **Step 4:** Commit: `feat(flags): kill switches for payment, messaging and tracking`

---

### P2.4 — Wire the tunables

**Depends on:** P2.3.
**Why:** `tunables` exists and is unread. Values worth tuning without a release: seat-hold TTL, availability poll interval, network timeout.

- [ ] **Step 1:** Replace the relevant hard-coded constants with `tunable('name') ?? <existing default>`. The `?? default` is mandatory — an absent tunable must change nothing.
- [ ] **Step 2:** Test that an absent tunable yields exactly today's constant.
- [ ] **Step 3:** Commit: `feat(flags): poll interval and hold TTL are tunable remotely`

---

### P2.5 — Publish and verify

**Depends on:** P2.4.

- [ ] **Step 1:** Publish `flags.json` with `{"kill": {"customer_seat_choice": true}}`.
- [ ] **Step 2:** On a live install, confirm the seat chart entry points now route to the request form.
- [ ] **Step 3:** Revert to `{}`; confirm seat choice returns.
- [ ] **Step 4:** Record in the runbook.

---

### P2.6 — Re-assert the dormant default

**Depends on:** P2.5.

- [ ] **Step 1:** Extend `test/services/ota_dormant_test.dart` — with `kill: {}` every feature is on and every tunable equals its compiled-in constant.
- [ ] **Step 2:** `flutter test` green.
- [ ] **Step 3:** Commit: `test(flags): an empty flag document changes nothing`

---

# PHASE 3 — Layout SDUI

**Why this phase exists:** it is the only part of *"change the entire UI from remote"* that is not already built. It is also the only part with real risk.

**Depends on:** P2.3 — the `remote_layout` kill switch must be live *before* this ships, so a bad layout document can be switched off without a release.

**Scope:** reorder, hide and re-tone **sections the binary already contains**, on surfaces outside the native floor (spec §4). It never invents UI. With no document, every screen renders its compiled-in default.

**Exit criteria:** one screen's section order and visibility are remote-controlled, and with the document absent that screen renders exactly as today.

---

### P3.1 — `ScreenLayout` model

**Depends on:** P2.3.

**Files:** `lib/models/screen_layout.dart`, `test/models/screen_layout_test.dart`.

**Produces:** `ScreenLayout { screen, sections: List<LayoutSection>, when: BlockTargeting }`, `LayoutSection { id, visible, order, tone }`. Reuses `BlockTargeting` verbatim — it is already the right shape.

- [ ] **Step 1:** Tests first: unknown section id is skipped; a registered-but-unlisted section appends at the end (so a section added in a later build still appears for clients on an older document); malformed input yields defaults, never throws.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Commit: `feat(layout): the screen-layout model`

---

### P3.2 — Screen and section registry

**Depends on:** P3.1.
**Why:** closed registry, exactly like `ContentSlots`. Names are a published contract.

**Files:** `lib/models/layout_registry.dart`.

- [ ] **Step 1:** Declare screens and their section ids. **Exclude every native-floor surface** (spec §4) — the registry is where that boundary is enforced in code.
- [ ] **Step 2:** Document per screen why each section is safe to reorder.
- [ ] **Step 3:** Commit: `feat(layout): closed registry of screens and sections`

---

### P3.3 — Layout service

**Depends on:** P3.2.
**Files:** `lib/services/remote_layout_service.dart`, `lib/config/remote_layout_config.dart`.

**Why a fourth channel rather than extending content.json:** different cadence, different size profile, and an independent kill switch. A bad layout must not require reverting content.

- [ ] **Step 1:** Build on `cached_remote_document.dart` — do not hand-roll a third fetcher.
- [ ] **Step 2:** `REMOTE_LAYOUT_URL` dart-define, empty default, 32 KB cap.
- [ ] **Step 3:** Add the key to `config/ota.json`.
- [ ] **Step 4:** Tests: dormant when unconfigured; last-good cache on failure; unknown screen skipped.
- [ ] **Step 5:** Commit: `feat(layout): the remote layout channel`

---

### P3.4 — `SectionHost` widget

**Depends on:** P3.3.
**Why:** one widget that takes a screen id and a map of `sectionId -> WidgetBuilder`, and renders them in remote order. Screens declare sections; they do not each re-implement ordering.

**Files:** `lib/components/section_host.dart`, `test/components/section_host_test.dart`.

- [ ] **Step 1:** Tests first: no document ⇒ declaration order; document ⇒ its order; `visible:false` hides; unknown id skipped; unlisted section appended.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Commit: `feat(layout): SectionHost renders sections in remote order`

---

### P3.5 — Pilot on one screen

**Depends on:** P3.4.
**Why:** prove it on a low-risk, high-value surface before touching others. **Recommended pilot:** the customer tour detail screen — customer-facing, no offline requirement, and already carries a content slot.

- [ ] **Step 1:** Convert its sections to `SectionHost` declarations.
- [ ] **Step 2:** Test: with no document it renders **byte-identically** to today.
- [ ] **Step 3:** Publish a layout document reordering two sections; verify on device.
- [ ] **Step 4:** Commit: `feat(layout): customer tour detail is remotely arrangeable`

---

### P3.6 — Roll out to the remaining safe screens

**Depends on:** P3.5.

- [ ] **Step 1:** One screen per commit, each with a renders-identically-when-dormant test.
- [ ] **Step 2:** **Stop at the native floor.** Do not convert the seat chart, collect sheet or handover form.

---

### P3.7 — Wire the layout kill switch

**Depends on:** P3.6, P2.3.
**Why:** the panic button. If a published layout breaks a screen, `kill: {"remote_layout": true}` restores compiled-in defaults everywhere without a release.

- [ ] **Step 1:** `SectionHost` ignores the remote document entirely when the flag is killed.
- [ ] **Step 2:** Test it.
- [ ] **Step 3:** Verify live: publish a deliberately broken layout, kill the flag, confirm recovery.
- [ ] **Step 4:** Commit: `feat(layout): remote layout has an off switch`

---

### P3.8 — Final verification

**Depends on:** P3.7.

- [ ] **Step 1:** `flutter analyze` — zero errors.
- [ ] **Step 2:** `flutter test` — full suite green, count higher than the 1637 baseline.
- [ ] **Step 3:** Delete all four documents from the buckets; confirm the app behaves exactly as before any of this work.
- [ ] **Step 4:** i18n parity — all three locales identical key sets.
- [ ] **Step 5:** Update the runbook with the layout channel.
- [ ] **Step 6:** Report: what is now remotely controllable, and what deliberately is not.

---

## Verification before completion

- [ ] The global invariant holds: **every document deleted ⇒ app unchanged.** Asserted by test at P1.7, P2.6 and P3.8.
- [ ] The native floor (spec §4) is intact — no seat-chart, collect-sheet or handover surface takes a remote dependency.
- [ ] Every new `tr()` key exists in all three locales.
- [ ] One slot registry, one flag registry, one layout registry. No duplicates.
- [ ] The runbook lets somebody who did not write this publish and revert safely.
