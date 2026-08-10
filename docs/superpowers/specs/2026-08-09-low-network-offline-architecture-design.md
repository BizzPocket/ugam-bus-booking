# Low-network correctness: offline outbox + unified data layer — design

**Status:** design approved in principle, **not yet implementation-ready** — see [Must resolve before writing code](#must-resolve-before-writing-code).
Written 2026-08-09 against `feat/money-collection-settlement` @ `bc468dd`.

**Provenance legend:**
- **[V]** — verified directly in this session (file read or command executed).
- **[R]** — asserted by a discovery subagent, not independently re-read. Consistent across reports unless noted.
- **[DECISION]** — a product call made by the repo owner in the design conversation, not derivable from code.
- **[UNVERIFIED-LIVE]** — a claim about the production database. The repo cannot settle it.

---

## ⚠️ This spec reverses a documented non-goal

`docs/superpowers/specs/2026-08-09-2g-cold-start-design.md` — written the **same day** as this one — lists under *Explicit non-goals*: **[V]**

> Full offline write-queue / SQLite cache was removed intentionally (stale-data risk). Slow **online** is the target; true airplane-mode booking is not.

The repo owner has explicitly overridden this. **[DECISION]** The stated reason is field reality: handlers collect cash on moving buses in areas with no signal, and the current behaviour there is not "degraded" — it is an indefinite hang with no feedback (see Finding 1).

**Whoever implements this must update the 2G cold-start doc's non-goals section** so the two specs do not contradict each other. Do not silently leave both in the repo.

The stale-data risk that motivated the original removal is real and is addressed here by two constraints, not by ignoring it:
1. There is **no general read cache**. Offline reads come from an explicit, user-initiated, per-tour snapshot with a visible timestamp (Component 6). Cache invalidation is what made the old layer untrustworthy; there is no invalidation logic to get wrong.
2. Writes are **append-only intents**, never mirrored row state. The server remains the single source of truth at all times.

---

## Problem

The app has a genuinely good low-network architecture that **only three of ten controllers use**, and which the handler app — the surface most exposed to bad signal — does not use at all.

The 2G work already shipped **[V, per 2g-cold-start-design.md]**: progressive cold start, `SyncReadProjections` narrow selects, 12s wifi / 28s cellular per-page timeouts, a read-concurrency gate (2 cellular / 6 wifi), and non-critical deferral. All of that lives inside `SyncService`.

`CustomerRequestsStore` — the entire backend for the customer and handler apps — bypasses every bit of it.

### Finding 1 — the handler app hangs instead of failing (highest severity)

`lib/services/customer_requests_store.dart` (873 lines) makes **20+ bare `Supabase.instance.client.rpc()` calls** with no timeout, no retry, and no online guard. **[R]**

Consequences on weak signal, in order of severity:
- `handler_upsert_collection`, `handler_upsert_expense`, `handler_upsert_handover` can hang **indefinitely**. The handler does not learn whether the cash was recorded. `SyncService` would have timed out at 28s and retried three times.
- `handler_tour_manifest` and `bus_layouts_for_request` hang the same way, so the roster never paints.
- No offline guard at all, so these are strictly *worse* than the admin path, which at least fails fast.

### Finding 2 — money has no realtime; two handlers silently diverge

Only `TourController` subscribes to `RealtimeService`. **[R]** `MoneyController` and `FinanceController` do not.

Two handlers collecting on the same tour on different devices see neither the other's collections nor the other's handovers until someone manually refreshes. On a money-settlement feature this is a correctness bug, not a freshness nicety.

### Finding 3 — the controller tier split

| Tier | Controllers | Data access | Retry | Projections | Realtime |
|---|---|---|---|---|---|
| Modern | `TourController`, `MoneyController`, `CustomerMemoryController` | `SyncService.smartX` | yes | yes | Tour only |
| Partial | `FinanceController`, `UserController`, `InboxController` | own service layer | no | partial | no |
| Base-level | `PickupController` | raw `Supabase.instance.client` | **no** | **no** | no |
| No data | `ThemeController`, `LocaleController`, `ShellController` | SharedPreferences / none | n/a | n/a | n/a |

`MoneyController` itself is not fully clean: `payment_claims` is read via a direct client call at `lib/controllers/money_controller.dart:289-291`, bypassing `smartFetch`'s retry and timeout. **[R]**

Across `lib/`, **~40 direct `Supabase.instance.client` call sites in 10 files** bypass the protections. **[R]**

### Finding 4 — error handling has four incompatible shapes

`AppSnackBar.error()` (Auth) · `debugPrint()` (User) · `dev.log(name:)` (Pickup) · silent `catch (_)` (CustomerMemory, Inbox). **[R]**
Load-state exposure is equally varied: `loadedOnce` / `loadFailed` / `isLoading`+`hasError`+`errorMessage` / nothing.

### Finding 5 — no production observability

No Sentry, no Crashlytics. **[R]** Every production failure is invisible. This is why the severity ordering above is inferred from code rather than measured.

### Finding 6 — scale and perf (real but not urgent)

- `TourController`: 3275 lines **[V]**, ~93 public methods across 11 domains. **[R]** (ARCHITECTURE.md still says 1561 lines — it is stale. **[V]**)
- `getTour()` is an O(n) `indexWhere` scan called from 200+ sites. **[R]**
- `MoneyController._billedRevenues()` / `_busRents()` recompute per `summaryForBus()` call — ~5× redundant work on a 5-bus tour. **[R]**

These degrade gracefully and are deferred to Wave 3 deliberately.

---

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Build **all four waves**, not one. **[DECISION]** | Owner's call. Mitigated by sequencing them so each wave is independently shippable and verifiable. |
| D2 | **Queue writes locally and replay on reconnect** — full offline, not fail-fast, not handler-only. **[DECISION]** | Handlers must be able to work with zero signal. |
| D3 | Conflict rule: **last writer wins by timestamp**, symmetric between handler and admin. **[DECISION]** | Owner chose this over admin-priority or a review queue. |
| D4 | Timestamps are **server-anchored, not device clock**. | Implementation constraint on D3, added by me. Cheap Android field devices drift; without this, a wrong phone clock decides which cash record survives. Comparison happens server-side inside `ON CONFLICT` so it is atomic. |
| D5 | **No general read cache.** Offline reads are an explicit per-tour snapshot. | Directly addresses the stale-data risk that motivated the original removal. |
| D6 | Every mutation goes through the outbox **even when online**. | Eliminates an `if (offline)` branch. The offline path is exercised on every write instead of being a rarely-tested fallback. |

---

## What makes this tractable: the RPCs are already idempotent

The single most important discovery. **10 of 13** handler/customer RPCs are already safe to replay. **[R — SQL read from `supabase/migrations/`]**

Every money model already generates its own UUID client-side (`id = id ?? const Uuid().v4()` — `Collection`, `Expense`, `IncomeEntry`, `Attendance`, `BusHandover`) **[R]**, and the RPCs upsert on it.

**Safe to replay as-is:**

| RPC | Idempotency mechanism |
|---|---|
| `handler_upsert_collection` | `on conflict (passenger_id, bus_id, seat_id) do update` |
| `handler_upsert_expense` | `on conflict (id) do update` |
| `handler_upsert_income` | `on conflict (id) do update` |
| `handler_upsert_handover` | `on conflict (id) do update ... where source = 'handler'` |
| `handler_upsert_attendance` | `on conflict (passenger_id, bus_id, leg) do update` |
| `handler_delete_expense` / `_income` / `_handover` | delete-by-id is a no-op when already gone |
| `handler_complete_outbound_leg` | explicit guard: returns 0 if no `journey_done = false` riders remain |
| `booking_request_customer_cancel` | gate: returns false if status ≠ `pending` |
| `booking_request_customer_request_cancel` | gate: returns false if `cancel_requested_at` is set |

Critically, **no RPC uses relative arithmetic** (`amount = amount + p_amount`). All assignment is absolute, which is what makes replay safe. **[R]**

**NOT safe to replay — must be fixed or excluded:**

| RPC | Problem | Consequence if queued unfixed |
|---|---|---|
| `claim_upi_advance` | plain `INSERT`, server-generated id, no unique constraint | replay creates a **duplicate payment claim** |
| `claim_upi_advance_for_hold` | same | same |

**Caveat:** `handler_upsert_attendance` sets `marked_at = now()` inside its `ON CONFLICT`, so a replay rewrites the timestamp to replay-time. **[R]** Final state (present/absent) is correct; the audit trail drifts. Acceptable, or fix in the same migration.

---

## Architecture

Three new components, three changes to existing code.

### Component 1 — `ServerClock` (new, small)

Tracks the offset between device and server time. The **only** permitted time source for stamping a mutation.

- Reads the `Date` header off every successful Supabase response; stores `offset = serverTime - deviceTime`.
- Persists the offset (SharedPreferences) so it survives a cold start with no signal.
- `ServerClock.now()` returns `DateTime.now().toUtc() + offset`.
- Exposes `hasSyncedOnce` — if the app has never been online, the offset is unknown and queued ops must be flagged as having an untrusted timestamp.

### Component 2 — `Outbox` (new)

A durable FIFO log in SQLite.

```sql
CREATE TABLE outbox_ops (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,  -- strict ordering
  kind       TEXT NOT NULL,     -- 'insert' | 'update' | 'delete' | 'rpc'
  target     TEXT NOT NULL,     -- table name or RPC name
  entity_id  TEXT NOT NULL,     -- client UUID; the basis of replay safety
  payload    TEXT NOT NULL,     -- JSON
  client_ts  INTEGER NOT NULL,  -- ServerClock.now() at edit time (epoch ms)
  ts_trusted INTEGER NOT NULL,  -- 0 if ServerClock had never synced
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  state      TEXT NOT NULL DEFAULT 'pending'  -- pending | sending | failed
);
CREATE INDEX outbox_pending ON outbox_ops(state, seq);
CREATE UNIQUE INDEX outbox_coalesce ON outbox_ops(target, entity_id) WHERE state = 'pending';
```

Two behaviours are load-bearing:

- **Strict FIFO by `seq`.** A delete must never replay before its own insert. Do not parallelise the drain.
- **Coalescing.** The partial unique index enforces one pending op per `(target, entity_id)`; enqueueing a second replaces `payload` and `client_ts`. A handler correcting the same collection five times offline drains as **one** write.

  Two details an implementer must get right:
  - **Keep the original `seq` when coalescing.** Bumping it to the tail would reorder that entity's write relative to other entities and can break an insert→delete pair.
  - The index is scoped to `state = 'pending'` on purpose, so a new edit **does not** coalesce into an op already in `'sending'`. That op is in flight and its payload must not mutate underneath the request; the new edit queues behind it and wins by `client_ts`.

  Coalescing is only valid because every queued write is an absolute-assignment upsert (see previous section). **If a relative-arithmetic RPC (`amount = amount + x`) is ever added, coalescing silently corrupts it.** Guard this with a test.

### Component 3 — `OutboxDrainer` (new)

- Watches `SyncService.isOnline`; drains FIFO on transition to online and after each successful send.
- Reuses the existing `SyncRetryPolicy.isRetryable()` — do **not** write a second retry classifier. **[R: policy already distinguishes retryable network/5xx/503 from terminal auth/RLS/constraint errors]**
- Terminal error → `state = 'failed'`, surfaced in a visible "sync problems" list. **Never silently dropped.**
- Exponential backoff between drain sweeps, reusing the existing 400ms → 1.2s → 3.6s ladder.

### Component 4 — `MutationGateway` (replaces two write paths)

The single entry point for every mutation in the app.

- `SyncService.smartInsert/smartUpdate/smartDelete` become thin wrappers that enqueue.
- All 20+ `CustomerRequestsStore` RPC writes route through it.
- This is the piece that **forces** the controller unification: once there is exactly one write API, `PickupController`'s raw `client.from()` calls have nowhere else to go.

Excluded from the outbox (must stay synchronous and online):
- Auth (`AdminAuthService`) — session establishment cannot be deferred.
- `claim_upi_advance*` until the migration lands (see Wave 1) — a user watching a payment confirm needs a real answer, and it is not replay-safe.

### Component 5 — Migrations

1. Add `p_client_ts` to each handler upsert RPC; guard the conflict clause with
   `where excluded.client_ts >= <table>.updated_at` — implements D3/D4 atomically server-side.
2. Give `claim_upi_advance` and `claim_upi_advance_for_hold` a client-supplied idempotency key with a unique constraint, so they become queueable.
3. Optional: stop rewriting `marked_at` in `handler_upsert_attendance`'s conflict clause.

⚠️ Migrations in this project are **applied by hand, one file at a time**, and migrations 039/040/041 are reportedly still pending manual deploy. Confirm the live migration state before adding more.

### Component 6 — `TourSnapshot` (Wave 2)

Explicit per-tour offline download: handler manifest, bus layouts, and the handler's money rows, stored as JSON blobs in SQLite keyed by `tourId`.

Deliberately **not** a general read cache — no invalidation logic, no staleness heuristics. The handler taps "Make available offline", sees a download timestamp, and can re-download. This is the concrete form of D5.

---

## Data flow

**Write (identical online and offline):**

```
controller optimistic local mutation
  → MutationGateway.enqueue(op)      // stamps ServerClock.now()
  → Outbox persists to SQLite        // survives app kill
  → returns immediately              // UI already updated
  → OutboxDrainer sends when able
       ├─ success  → delete row
       ├─ retryable → attempts++, backoff, retry
       └─ terminal → state='failed', surface in sync-problems list
```

**Read, handler offline:** `TourSnapshot` if present, else the existing online path.

---

## The behavioural change this forces

**Today:** a failed write throws; the controller catches, calls `refreshTours()`, and shows a red snackbar. That pattern appears at 35+ call sites in `TourController` alone. **[R]**

**After:** writes do not throw — they enqueue and return. Therefore:

- Optimistic state means **"pending"**, not "committed". It needs a visible indicator.
- Revert happens only on *terminal* failure, arriving asynchronously — possibly while the user is on a different screen.
- The snackbar changes meaning: from "your edit failed" to "3 edits couldn't sync — review them".

This is the riskiest part of the program. It changes how the app *feels*, and it invalidates the error-path assertions in a large number of existing tests. **Budget for it explicitly.**

---

## Waves

Each wave must ship green and be independently verifiable. Do not start a wave before the previous one's tests pass.

### Wave 0 — stop the bleeding (smallest, highest value)
- Route all `CustomerRequestsStore` RPCs — **reads and writes alike** — through the existing timeout + `SyncRetryPolicy` harness. **No behaviour change beyond: hangs become bounded failures.**

  Wave 1 later moves the *writes* off this synchronous path onto the outbox. That is intentional overlap, not wasted work: Wave 0 is a small, independently shippable fix that stops the worst failure mode immediately, and the *reads* keep using the Wave 0 harness permanently.
- Move `payment_claims` (`money_controller.dart:289`) onto `smartFetch`.
- Wire Crashlytics or Sentry (Firebase is already initialised in `main.dart` **[R]**).
- **Exit criteria:** no bare `client.rpc()` without a timeout; a forced-airplane-mode handler action fails within 30s with a real message.

### Wave 1 — the outbox
- `ServerClock`, `Outbox`, `OutboxDrainer`, `MutationGateway`.
- Migrations for `p_client_ts` guards and UPI idempotency keys.
- Pending-state UI + sync-problems list.
- **Exit criteria:** kill the app mid-write with no signal, relaunch, restore signal — the write lands exactly once.

### Wave 2 — handler offline snapshot
- `TourSnapshot` download/restore; "available offline" affordance.
- **Exit criteria:** a handler in airplane mode can open a downloaded tour, see the roster, and record a collection that later syncs.

### Wave 3 — unification and perf
- Migrate `PickupController`, `UserController`, `FinanceController` onto `MutationGateway` + `SyncReadProjections`.
- Eliminate remaining direct `Supabase.instance.client` sites.
- Add realtime to the money tables (Finding 2).
- Standardise error handling on one shape; one load-state contract.
- O(1) `getTour` index; memoise `_billedRevenues`/`_busRents` per summary pass.
- Split `TourController` along its 11 domains.
- Delete the dead `SyncService` cache stubs (`getCachedList`, `invalidateCache`, `pendingEntityIdsForTable` — confirmed zero call sites **[R]**).
- Refresh `ARCHITECTURE.md`, which is stale.

---

## Testing

The **1006 currently-passing tests are the safety net and must stay green throughout.** **[R — per session history]**

New coverage required:
- `Outbox`: FIFO ordering, coalescing correctness, durability across simulated process kill.
- `ServerClock`: fake-clock tests including "device clock is 3 days wrong" and "never synced".
- `OutboxDrainer`: flaky-link simulation; terminal-vs-retryable classification; backoff.
- **Replay idempotency, one test per queueable RPC:** enqueue the same op twice, assert exactly one row. This is the test that protects the money.
- Conflict rule: older `client_ts` must not overwrite a newer `updated_at`.

Existing suites most likely to break: anything asserting that a failed write throws or triggers `refreshTours()`.

---

## Must resolve before writing code

1. **Storage engine.** `sqflite` is **not** currently a direct dependency; it appears only transitively via `supabase_flutter` on macOS. `path_provider` is absent entirely. **[R]** Adding a durable queue requires re-adding `sqflite` + `path_provider`, or choosing Hive/Drift. **This is an unmade decision.**
2. **Live migration state.** Are 039/040/041 deployed? Wave 1's migrations stack on top. **[UNVERIFIED-LIVE]**
3. **UPI claims scope.** Fix them to be queueable, or keep them online-only with an explicit "connect to confirm payment" message? Wave 1 assumes the fix.
4. **Pending-state UX.** Needs a design pass before Wave 1 ships — the spec defines the mechanism, not the visual language. Must respect the existing cockpit density tokens.
5. **Concurrent-agent hazard.** Another AI agent edits this working tree live. Re-run analyze/tests before believing a failure.

---

## Out of scope

- Offline **reads** for the admin app. Admin is office-side; Wave 2 covers the handler only.
- Offline auth / first login. Requires an existing session.
- Multi-device conflict *resolution UI* beyond the failed-op list — D3 resolves conflicts automatically by timestamp.
- The seating engine, design system, and i18n are untouched.
