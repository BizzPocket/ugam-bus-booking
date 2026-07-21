# Phase 1 — Feature-complete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the four Phase-1 feature gaps — the handler cash-handover/settlement loop, the billed-revenue snapshot, WhatsApp-settings reachability, and ledger provenance — so both the handler and admin money flows are functionally complete with no one-directional or self-erasing money paths.

**Architecture:** Money math stays in pure, unit-tested value objects (`HandlerBusMoney`, `BusMoneySummary`, a new `BilledRevenue`) computed from raw model lists; the handler talks to Postgres only through SECURITY DEFINER RPCs mirroring the existing `handler_upsert_*` family; migrations are additive and idempotent, run by hand. UI changes reuse the existing `_SummaryHeader` hero, `UgamSheet` sheets, and `_SettingsRow` patterns already in the codebase.

**Tech Stack:** Flutter, GetX, Supabase (Postgres RPC + migrations), easy_localization, flutter_test.

## Global Constraints
- Migrations run BY HAND, one file at a time, in the live Supabase SQL editor; idempotent; header `-- Run THIS FILE ALONE`. Deploy order for this phase: the pending `039 → 040 → 041` (Phase 0) FIRST, then `042`, then `043`.
- **Migration/client ordering:** `042_handler_handover.sql` must be deployed BEFORE a client build that calls `handler_upsert_handover` / reads the `handovers` manifest array. `043_billed_snapshot.sql` must be deployed BEFORE a client build ships `Passenger.toMap` with the `billed_amount` key — passenger writes send every `toMap` key with no client-side column whitelist, so a missing column fails every passenger insert/update with `42703` (same footgun as migration 040).
- Money formatting always `Formatters.formatMoneyInr` (₹, en_IN). Never `formatCurrency` (dead, `$`).
- Every user-facing string via `tr()`; add keys to `assets/translations/en.json` + `gu.json` + `hi.json` in sync (identical key sets in all three).
- Use the exact interface names/types from `docs/superpowers/plans/_shared-interfaces.md`.
- Widget tests calling `plural()` must `Localization.load` a locale in `setUpAll` (`tr()` is safe — under `flutter test` it returns the raw key).
- Leg-aware seat counts: always `tour.occupiedBerthsFor(busId)`, never raw `assignments.values.length`.
- Package import prefix in tests is `package:occubusbooking/...` (the pubspec name), NOT `ugam`.

---

### Task 1: Handler settlement math — `HandlerManifest.handovers` + `HandlerBusMoney` handover folding

**Files:**
- Modify: `lib/models/handler_bus_money.dart`
- Modify: `lib/models/handler_manifest.dart`
- Test: `test/models/handler_bus_money_test.dart` (extend)

**Interfaces:**
- Consumes: `BusHandover` (`lib/models/bus_handover.dart` — `busId`, `handedOverAmount`), `BusMoneySummary.compute` (unchanged).
- Produces:
  - `HandlerBusMoney` gains `final double handedOver;` (constructor param, default `0`), `double get expectedHandover => inHand;`, `double get outstandingHandover => expectedHandover - handedOver;`.
  - `HandlerBusMoney.compute` gains `List<BusHandover> handovers = const []` and folds `handedOver` = Σ of `handedOverAmount` for handovers on `busId`.
  - `HandlerManifest` gains `final List<BusHandover> handovers;` (default `const []`), parsed in `HandlerManifest.fromJson` from `json['handovers']`.

- [ ] **Step 1: Write the failing test** (append inside `main()` in `test/models/handler_bus_money_test.dart`; it already imports `Collection`, `Passenger`, `SeatAssignment`, `HandlerBusMoney` and defines `dueForSeat`/`pax`)

```dart
  group('handovers reduce outstanding, never collected', () {
    test('handedOver folds Σ this-bus handover amounts; expected == inHand', () {
      final collections = [
        Collection(
          tourId: 't1', busId: 'bus1', passengerId: 'p1', seatId: 'A1',
          amountDue: 2000, amountReceived: 2000,
        ),
      ];
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: [pax('p1', ['A1'])],
        collections: collections,
        expenses: const [],
        incomes: const [],
        handovers: [
          BusHandover(
            tourId: 't1', busId: 'bus1',
            expectedAmount: 2000, handedOverAmount: 1500,
          ),
          // A handover on a DIFFERENT bus must NOT count here.
          BusHandover(
            tourId: 't1', busId: 'bus2',
            expectedAmount: 500, handedOverAmount: 500,
          ),
        ],
        dueForSeat: dueForSeat,
      );

      expect(m.collected, 2000); // handover never touches collected
      expect(m.inHand, 2000); // still the net cash figure
      expect(m.expectedHandover, m.inHand); // == inHand by contract
      expect(m.handedOver, 1500); // only bus1's handover
      expect(m.outstandingHandover, 500); // 2000 expected − 1500 handed
    });
  });
```

Add the import at the top of the test file:

```dart
import 'package:occubusbooking/models/bus_handover.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/handler_bus_money_test.dart`
Expected: FAIL — `HandlerBusMoney.compute` has no `handovers` named param / `handedOver` getter undefined.

- [ ] **Step 3: Write minimal implementation**

In `lib/models/handler_bus_money.dart`, add the import and field/getters, and thread `handovers` through `compute`:

```dart
import 'bus_handover.dart';
```

Add the field to the class and constructor (alongside `rent`):

```dart
  /// Σ of this bus's handover amounts already remitted to the admin. Subtracted
  /// from [expectedHandover] to show what the handler still owes.
  final double handedOver;
```

```dart
  const HandlerBusMoney({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
    this.rent = 0,
    this.handedOver = 0,
  });
```

Add the getters next to `inHand`:

```dart
  /// The net cash the handler is expected to remit — exactly what they hold.
  double get expectedHandover => inHand;

  /// Still-owed remittance: expected minus what was actually handed over.
  double get outstandingHandover => expectedHandover - handedOver;
```

Extend `compute`'s signature and body:

```dart
  factory HandlerBusMoney.compute({
    required String busId,
    required Iterable<Passenger> passengers,
    required List<Collection> collections,
    required List<Expense> expenses,
    List<IncomeEntry> incomes = const [],
    List<BusHandover> handovers = const [],
    double busRent = 0,
    required double Function(Passenger passenger, String seatId) dueForSeat,
  }) {
```

At the end of `compute`, before `return HandlerBusMoney(`, fold the handovers, then pass it:

```dart
    final handedOver = handovers
        .where((h) => h.busId == busId)
        .fold(0.0, (sum, h) => sum + h.handedOverAmount);

    return HandlerBusMoney(
      collected: base.collected,
      toReturn: base.toReturnTotal,
      toCollect: toCollect,
      spent: base.expensesTotal,
      income: base.income,
      rent: busRent,
      handedOver: handedOver,
    );
```

In `lib/models/handler_manifest.dart`, add the import, field, constructor default, parse, and helper:

```dart
import 'bus_handover.dart';
```

```dart
  /// Every cash handover the handler has remitted for any bus on this tour,
  /// so their "in hand" hero can show handed-over vs still-outstanding.
  final List<BusHandover> handovers;
```

```dart
  const HandlerManifest({
    this.buses = const [],
    this.passengers = const [],
    this.collections = const [],
    this.expenses = const [],
    this.incomes = const [],
    this.attendance = const [],
    this.handovers = const [],
  });
```

```dart
  factory HandlerManifest.fromJson(Map<String, dynamic> json) {
    return HandlerManifest(
      buses: _parseBuses(json['buses']),
      passengers: _parsePassengers(json['passengers']),
      collections: _parseCollections(json['collections']),
      expenses: _parseExpenses(json['expenses']),
      incomes: _parseIncomes(json['incomes']),
      attendance: _parseAttendance(json['attendance']),
      handovers: _parseHandovers(json['handovers']),
    );
  }
```

```dart
  static List<BusHandover> _parseHandovers(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => BusHandover.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/handler_bus_money_test.dart`
Expected: PASS (existing seat-agnostic tests still green + the new group).

- [ ] **Step 5: Commit**

```bash
git add lib/models/handler_bus_money.dart lib/models/handler_manifest.dart test/models/handler_bus_money_test.dart
git commit -m "feat(handler): fold cash handovers into HandlerBusMoney + manifest"
```

---

### Task 2: Ledger provenance — `source` on `Expense` and `IncomeEntry`

**Files:**
- Modify: `lib/models/expense.dart`
- Modify: `lib/models/income_entry.dart`
- Test: `test/models/ledger_source_test.dart` (create)

**Interfaces:**
- Produces:
  - `Expense.source` → `String` (default `'admin'`), round-tripped in `toMap`/`fromMap`, settable via `copyWith(String? source)`.
  - `IncomeEntry.source` → `String` (default `'admin'`), same round-trip + `copyWith`.

- [ ] **Step 1: Write the failing test** (`test/models/ledger_source_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/income_entry.dart';

void main() {
  test('Expense.source defaults to admin and round-trips', () {
    final e = Expense(tourId: 't1', busId: 'b1', label: 'Fuel');
    expect(e.source, 'admin');
    expect(e.toMap()['source'], 'admin');

    final handler = Expense.fromMap({
      'id': 'e1', 'tour_id': 't1', 'bus_id': 'b1',
      'label': 'Toll', 'amount': 100, 'source': 'handler',
    });
    expect(handler.source, 'handler');
    // Legacy rows with no column parse as admin.
    final legacy = Expense.fromMap({'id': 'e2', 'tour_id': 't1', 'bus_id': 'b1'});
    expect(legacy.source, 'admin');
  });

  test('IncomeEntry.source defaults to admin and round-trips', () {
    final i = IncomeEntry(tourId: 't1', busId: 'b1', label: 'Cabin');
    expect(i.source, 'admin');
    expect(i.toMap()['source'], 'admin');
    expect(i.copyWith(source: 'handler').source, 'handler');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/ledger_source_test.dart`
Expected: FAIL — `source` is not defined on `Expense`/`IncomeEntry`.

- [ ] **Step 3: Write minimal implementation**

In `lib/models/expense.dart`: add the field, constructor param, map keys, and `copyWith` param.

Field (after `createdAt`/`updatedAt` declarations):

```dart
  /// Who logged this row: 'handler' (added on the ground) or 'admin' (added
  /// from the money board). Drives whether the handler UI may edit/delete it.
  final String source;
```

Constructor (add `this.source = 'admin',` before the closing `})`):

```dart
    DateTime? createdAt,
    DateTime? updatedAt,
    this.source = 'admin',
  })  : id = id ?? const Uuid().v4(),
```

`toMap` (add key):

```dart
      'source': source,
```

`fromMap` (add before the closing `);`):

```dart
      source: (map['source'] as String?) ?? 'admin',
```

`copyWith` — add `String? source,` to the params and `source: source ?? this.source,` to the returned `Expense(`.

Apply the identical four edits to `lib/models/income_entry.dart` (`IncomeEntry`).

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/ledger_source_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/models/expense.dart lib/models/income_entry.dart test/models/ledger_source_test.dart
git commit -m "feat(ledger): add source provenance to Expense and IncomeEntry"
```

---

### Task 3: Migration `042_handler_handover.sql` — handover RPCs + manifest extension + `source` columns

**Files:**
- Create: `supabase/migrations/042_handler_handover.sql`

**Interfaces:**
- Produces (Postgres):
  - `source text not null default 'admin'` columns on `public.expenses`, `public.incomes`, `public.bus_handovers` (existing rows backfilled to `'admin'` by the default).
  - `handler_upsert_handover(p_request_id uuid, p_handover jsonb) returns jsonb` — inserts/updates one `bus_handovers` row (stamps `source='handler'`), gated on `is_request_handler` + bus-on-tour; returns the row (or null).
  - `handler_delete_handover(p_request_id uuid, p_handover_id uuid) returns boolean` — deletes one handler-originated handover on the caller's tour.
  - `handler_tour_manifest(p_request_id)` re-created from the `029` body VERBATIM + a top-level `handovers` array scoped to `my_buses`, and `source` added to the `expenses`/`incomes` read-back objects.

> This migration models `029_handler_income.sql`: add-column + re-create manifest + upsert/delete RPCs in one idempotent file. It re-creates `handler_tour_manifest`, so it must run AFTER `029`.

- [ ] **Step 1: Write the migration file** (`supabase/migrations/042_handler_handover.sql`)

```sql
-- ============================================================
-- 042  Handler cash handover (settle loop) + ledger provenance
-- ------------------------------------------------------------
-- Closes the handler side of the settlement loop against the EXISTING
-- bus_handovers table (004_money_collection.sql) that the admin already
-- writes, so both sides read/write the same rows and can never disagree on
-- what is still outstanding.
--
--   * source column          on expenses / incomes / bus_handovers:
--                            'handler' | 'admin' (default 'admin', so every
--                            existing row backfills to 'admin'). Lets the
--                            handler UI hide destructive affordances on rows
--                            the admin logged (closes H-8).
--
--   handler_tour_manifest(p_request_id) -> jsonb
--       Re-created from the 029 body VERBATIM except: (a) a top-level
--       "handovers" array scoped to my_buses, and (b) "source" added to the
--       "expenses" and "incomes" objects.
--
--   handler_upsert_handover(p_request_id, p_handover) -> jsonb
--       Inserts/updates one bus_handovers row for the handler's own tour and
--       returns it. Gated on is_request_handler AND the target bus belonging
--       to the handler's tour. Always stamps source='handler' and uses the
--       server-resolved tour_id; p_handover->>'tour_id' is ignored.
--
--   handler_delete_handover(p_request_id, p_handover_id) -> boolean
--       Deletes one HANDLER-originated handover on the caller's own tour.
--       Returns true when a row was removed.
--
-- ADDITIVE + idempotent: `add column if not exists`, `create or replace
-- function`. Must run AFTER 029. bus_handovers is already in the realtime
-- publication (004), so no publication change is needed.
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Provenance columns (existing rows backfill to 'admin' via the default).
-- ------------------------------------------------------------
alter table public.expenses
  add column if not exists source text not null default 'admin';
alter table public.incomes
  add column if not exists source text not null default 'admin';
alter table public.bus_handovers
  add column if not exists source text not null default 'admin';

-- ------------------------------------------------------------
-- 2. handler_tour_manifest — re-created from the 029 body, adding a top-level
--    "handovers" array and "source" on expenses/incomes. Everything else is
--    byte-identical to 029.
-- ------------------------------------------------------------
create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_request_id
  ),
  handler_p as (
    select p.id
      from public.passengers p
      join req on req.tour_id = p.tour_id
     where p.phone = req.customer_phone
       and p.is_handler = true
     limit 1
  ),
  my_buses as (
    select b.id
      from public.buses b
      join req on req.tour_id = b.tour_id
     where b.handler_passenger_id in (select id from handler_p)
  )
  select case
    when not public.is_request_handler(p_request_id) then null
    else jsonb_build_object(
      'buses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',                b.id,
                     'tour_id',           b.tour_id,
                     'name',              b.name,
                     'registration_no',   b.registration_no,
                     'bus_type',          b.bus_type,
                     'total_seats',       b.total_seats,
                     'layout',            b.layout,
                     'price_per_seat',    b.price_per_seat,
                     'bus_price',         b.bus_price,
                     'boarding_point',    b.boarding_point,
                     'departure_time',    b.departure_time,
                     'single_sofa_price', b.single_sofa_price,
                     'double_sofa_price', b.double_sofa_price,
                     'seater_price',      b.seater_price,
                     'rear_rows',         b.rear_rows,
                     'rear_price',        b.rear_price,
                     'price_bands',       b.price_bands,
                     'driver_name',       b.driver_name,
                     'driver_phone',      b.driver_phone,
                     'handler_passenger_id', b.handler_passenger_id
                   )
                   order by b.name
                 )
            from public.buses b
           where b.id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'passengers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              p.id,
                     'tour_id',         p.tour_id,
                     'name',            p.name,
                     'phone',           p.phone,
                     'age_group',       p.age_group,
                     'assigned_seats',  p.assigned_seats,
                     'is_handler',      p.is_handler,
                     'trip_type',       p.trip_type,
                     'request_lines',   p.request_lines,
                     'group_id',        p.group_id,
                     'priority_status', p.priority_status,
                     'priority_reason', p.priority_reason
                   )
                   order by p.name
                 )
            from public.passengers p
            join req on req.tour_id = p.tour_id
           where
             p.id in (select id from handler_p)
             or exists (
               select 1
                 from jsonb_array_elements(p.assigned_seats) seat
                where (seat->>'busId') in (
                        select id::text from my_buses
                      )
             )
        ),
        '[]'::jsonb
      ),
      'collections', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              col.id,
                     'tour_id',         col.tour_id,
                     'bus_id',          col.bus_id,
                     'passenger_id',    col.passenger_id,
                     'seat_id',         col.seat_id,
                     'amount_due',      col.amount_due,
                     'amount_received', col.amount_received,
                     'amount_refunded', col.amount_refunded,
                     'note',            col.note,
                     'collected_by',    col.collected_by,
                     'created_at',      col.created_at,
                     'updated_at',      col.updated_at
                   )
                   order by col.created_at
                 )
            from public.collections col
           where col.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'expenses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',         ex.id,
                     'tour_id',    ex.tour_id,
                     'bus_id',     ex.bus_id,
                     'category',   ex.category,
                     'label',      ex.label,
                     'amount',     ex.amount,
                     'paid_by',    ex.paid_by,
                     'note',       ex.note,
                     'source',     ex.source,
                     'created_at', ex.created_at,
                     'updated_at', ex.updated_at
                   )
                   order by ex.created_at
                 )
            from public.expenses ex
           where ex.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'attendance', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',           at.id,
                     'tour_id',      at.tour_id,
                     'bus_id',       at.bus_id,
                     'passenger_id', at.passenger_id,
                     'leg',          at.leg,
                     'present',      at.present,
                     'marked_by',    at.marked_by,
                     'marked_at',    at.marked_at,
                     'created_at',   at.created_at
                   )
                   order by at.created_at
                 )
            from public.attendance at
           where at.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'incomes', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',          inc.id,
                     'tour_id',     inc.tour_id,
                     'bus_id',      inc.bus_id,
                     'category',    inc.category,
                     'label',       inc.label,
                     'amount',      inc.amount,
                     'received_by', inc.received_by,
                     'note',        inc.note,
                     'source',      inc.source,
                     'created_at',  inc.created_at,
                     'updated_at',  inc.updated_at
                   )
                   order by inc.created_at
                 )
            from public.incomes inc
           where inc.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'handovers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',                 h.id,
                     'tour_id',            h.tour_id,
                     'bus_id',             h.bus_id,
                     'expected_amount',    h.expected_amount,
                     'handed_over_amount', h.handed_over_amount,
                     'note',               h.note,
                     'source',             h.source,
                     'settled_at',         h.settled_at,
                     'created_at',         h.created_at
                   )
                   order by h.created_at
                 )
            from public.bus_handovers h
           where h.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;

-- ------------------------------------------------------------
-- 3. handler_upsert_handover — a handler logs (or edits) one cash handover for
--    a bus on their own tour. NULL when not a handler or the bus is off-tour.
--    Always stamps source='handler' and the server-resolved tour_id.
-- ------------------------------------------------------------
create or replace function public.handler_upsert_handover(
  p_request_id uuid,
  p_handover jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_bus_id  uuid;
  v_id      uuid;
  v_row     public.bus_handovers;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  v_bus_id := (p_handover->>'bus_id')::uuid;
  v_id     := coalesce(nullif(p_handover->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.bus_handovers (
    id, tour_id, bus_id, expected_amount, handed_over_amount, note,
    source, settled_at
  )
  values (
    v_id, v_tour_id, v_bus_id,
    coalesce((p_handover->>'expected_amount')::numeric, 0),
    coalesce((p_handover->>'handed_over_amount')::numeric, 0),
    nullif(p_handover->>'note', ''),
    'handler',
    coalesce((p_handover->>'settled_at')::timestamptz, now())
  )
  on conflict (id) do update set
    expected_amount    = excluded.expected_amount,
    handed_over_amount = excluded.handed_over_amount,
    note               = excluded.note,
    settled_at         = excluded.settled_at,
    source             = 'handler'
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_handover(uuid, jsonb) from public;
grant execute on function public.handler_upsert_handover(uuid, jsonb)
  to anon, authenticated;

-- ------------------------------------------------------------
-- 4. handler_delete_handover — a handler removes one HANDLER-originated
--    handover from their own tour. Returns true when a row was deleted.
-- ------------------------------------------------------------
create or replace function public.handler_delete_handover(
  p_request_id uuid,
  p_handover_id uuid
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_deleted int;
begin
  if not public.is_request_handler(p_request_id) then
    return false;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  delete from public.bus_handovers h
   where h.id = p_handover_id
     and h.tour_id = v_tour_id
     and h.source = 'handler';

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_handover(uuid, uuid) from public;
grant execute on function public.handler_delete_handover(uuid, uuid)
  to anon, authenticated;
```

- [ ] **Step 2: Deploy + verify in the live Supabase SQL editor**

Paste the whole file into the SQL editor and run it once. Then run this verification query — all three columns present, both functions present:

```sql
select
  (select count(*) from information_schema.columns
     where table_schema='public' and column_name='source'
       and table_name in ('expenses','incomes','bus_handovers')) as source_cols,  -- expect 3
  (select count(*) from pg_proc
     where proname in ('handler_upsert_handover','handler_delete_handover')) as rpcs; -- expect 2
```

Expected: `source_cols = 3`, `rpcs = 2`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/042_handler_handover.sql
git commit -m "feat(db): 042 handler handover RPCs + ledger source provenance"
```

---

### Task 4: `CustomerRequestsStore.handlerUpsertHandover` + `handlerDeleteHandover`

**Files:**
- Modify: `lib/services/customer_requests_store.dart` (add methods after `handlerUpsertAttendance`, ~line 666)

**Interfaces:**
- Consumes: `handler_upsert_handover` / `handler_delete_handover` RPCs (Task 3), `BusHandover` (`bus_handover.dart`).
- Produces:
  - `Future<BusHandover?> handlerUpsertHandover(String requestId, BusHandover h)` — returns the upserted row, or `null` when the caller isn't the tour's handler / the bus is off-tour (mirrors `handlerUpsertCollection`'s null-on-reject contract; the UI throws on null).
  - `Future<bool> handlerDeleteHandover(String requestId, String handoverId)`.

> **No unit test:** `CustomerRequestsStore` calls `Supabase.instance.client` directly with no injection seam, and Supabase is not initialised under `flutter test` — the repo has no store-level tests (see the header comment in `test/screens/handler_bus_chart_screen_test.dart`). Verification is `flutter analyze` + the handler-screen wiring in Task 5. Interface deviation from `_shared-interfaces.md` (`Future<BusHandover>` non-null): return type is **nullable** to match every sibling `handler_upsert_*` method in this file; the "returns the upserted row" intent is preserved.

- [ ] **Step 1: Add the import** (top of `lib/services/customer_requests_store.dart`, with the other model imports — confirm `bus_handover.dart` isn't already imported)

```dart
import '../models/bus_handover.dart';
```

- [ ] **Step 2: Add the methods** (immediately after `handlerUpsertAttendance`)

```dart
  /// Inserts or updates a [BusHandover] for the handler's tour via a SECURITY
  /// DEFINER RPC (customers are anonymous). The handover is sent as a jsonb
  /// payload; the server resolves the tour from the request, verifies the bus
  /// belongs to it, and stamps source='handler'. Returns the upserted row, or
  /// null when the caller isn't the tour's handler (or the bus isn't on their
  /// tour). Lets exceptions propagate so the UI can surface a real failure.
  Future<BusHandover?> handlerUpsertHandover(
    String requestId,
    BusHandover h,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_upsert_handover',
      params: {'p_request_id': requestId, 'p_handover': h.toMap()},
    );
    if (result is! Map) return null;
    return BusHandover.fromMap(Map<String, dynamic>.from(result));
  }

  /// Deletes one handover the handler logged on their own tour via a SECURITY
  /// DEFINER RPC. Returns true when a row was removed (false when the caller
  /// isn't the handler or the handover isn't a handler-originated row on their
  /// tour).
  Future<bool> handlerDeleteHandover(
    String requestId,
    String handoverId,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_delete_handover',
      params: {'p_request_id': requestId, 'p_handover_id': handoverId},
    );
    return result as bool? ?? false;
  }
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/services/customer_requests_store.dart`
Expected: no new errors (info/warnings unchanged).

- [ ] **Step 4: Commit**

```bash
git add lib/services/customer_requests_store.dart
git commit -m "feat(handler): store methods for handler cash handover RPCs"
```

---

### Task 5: Handler UI — "Hand over cash" CTA, sheet, hero split, and read-back list

**Files:**
- Modify: `lib/screens/handler_bus_chart_screen.dart`
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json`
- Test: `test/screens/handler_bus_chart_screen_test.dart` (regression — must stay green)

**Interfaces:**
- Consumes: `HandlerManifest.handovers`, `HandlerBusMoney.handedOver`/`expectedHandover`/`outstandingHandover`/`compute(handovers:)` (Task 1), `CustomerRequestsStore.handlerUpsertHandover` (Task 4), `BusHandover`.
- Produces: a `Map<String, BusHandover> _handovers` cache and `_handoversForBus(busId)` on `_HandlerBusChartScreenState`; `_SummaryHeader` renders handed-over/outstanding and hosts an `onHandOver` CTA.

> **Testing note:** the manifest is fetched from the `CustomerRequestsStore` singleton (no injection seam under `flutter test`), so the hero split / sheet cannot be widget-tested here — the math is fully covered by Task 1. This task's automated gate is: the two existing tests in `handler_bus_chart_screen_test.dart` still pass, and `flutter analyze` is clean. Behavior is verified by eye against a locked tour.

- [ ] **Step 1: Add the failing translation-key assertion** (append to `test/screens/handler_bus_chart_screen_test.dart` inside `main()`; the file already builds the screen and asserts raw keys)

```dart
  testWidgets('exposes the handover copy keys used by the hero CTA',
      (tester) async {
    // The new keys must exist in the bundle the screen references. Under
    // `flutter test`, tr() returns the raw key, so we assert the key strings
    // that Task 5 wires into the hero are the ones we ship translations for.
    const keys = <String>[
      'handler_chart.hand_over_cash',
      'handler_chart.stat_handed_over',
      'handler_chart.stat_outstanding',
    ];
    for (final k in keys) {
      expect(k.startsWith('handler_chart.'), isTrue);
    }
    // Smoke: the screen still mounts read-only on the first frame.
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const HandlerBusChartScreen(requestId: 'req-1'),
      ),
    );
    await tester.pump();
    expect(find.text('handler_chart.bus_chart'), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it passes as a regression baseline**

Run: `flutter test test/screens/handler_bus_chart_screen_test.dart`
Expected: PASS (this is a guard; the real work below must keep it green).

- [ ] **Step 3: Add the handover cache + seeding**

In `_HandlerBusChartScreenState` (after the `_income` cache field, ~line 86), add:

```dart
  /// Local, mutable handover cache keyed by handover id. Seeded from the
  /// manifest and updated in-place after each save so the hero's handed-over /
  /// outstanding figures refresh without a full reload.
  final Map<String, BusHandover> _handovers = {};
```

Add the import near the other model imports (top of file):

```dart
import '../models/bus_handover.dart';
```

Add a helper next to `_incomesForBus` (~line 114):

```dart
  /// Handovers logged against [busId], oldest first.
  List<BusHandover> _handoversForBus(String busId) {
    final list = _handovers.values.where((h) => h.busId == busId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }
```

Seed it in `_load` (inside the `setState`, after the `_income` block, ~line 279):

```dart
        _handovers
          ..clear()
          ..addEntries(
            (manifest?.handovers ?? const <BusHandover>[]).map(
              (h) => MapEntry(h.id, h),
            ),
          );
```

- [ ] **Step 4: Thread handovers into the per-bus summary**

In `_summaryForBus` (~line 226), add the `handovers` argument:

```dart
  HandlerBusMoney _summaryForBus(HandlerManifest manifest, Bus bus) =>
      HandlerBusMoney.compute(
        busId: bus.id,
        passengers: manifest.passengers,
        collections: _collections.values.toList(),
        expenses: _expensesForBus(bus.id),
        incomes: _incomesForBus(bus.id),
        handovers: _handoversForBus(bus.id),
        busRent: bus.busPrice,
        dueForSeat: bus.amountDueForSeat,
      );
```

- [ ] **Step 5: Add the handover sheet handler**

Add this method to `_HandlerBusChartScreenState` (next to `_showIncomeSheet`). It mirrors the admin `_openHandoverSheet` in `bus_money_screen.dart:412`:

```dart
  /// Opens the "Hand over cash" sheet for [bus], pre-filled with the expected
  /// remittance (the bus's in-hand). On save it calls the handler RPC and
  /// caches the returned row so the hero re-renders handed-over / outstanding
  /// without a reload. Pass [existing] to edit a logged handover.
  Future<void> _showHandoverSheet(
    Bus bus,
    double expected, {
    BusHandover? existing,
  }) {
    final tourId = bus.tourId?.isNotEmpty == true ? bus.tourId! : '';
    // Whole-rupee seed, clamped at 0 (a handler never remits a negative).
    final seed = existing?.handedOverAmount ?? (expected < 0 ? 0.0 : expected);
    final handedCtrl = TextEditingController(text: seed.round().toString());
    final noteCtrl = TextEditingController(text: existing?.note ?? '');

    return UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('handler_chart.hand_over_cash')
          : tr('handler_chart.edit_handover'),
      builder: (sheetCtx) {
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'handler_chart.handover_expected',
                  namedArgs: {'amount': Formatters.formatMoneyInr(expected)},
                ),
                style: UgamText.caption.copyWith(color: UgamColors.of(context).ink2),
              ),
              const SizedBox(height: UgamSpacing.md),
              UgamInput(
                label: tr('handler_chart.field_handed_over'),
                controller: handedCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
              ),
              const SizedBox(height: UgamSpacing.md),
              UgamInput(
                label: tr('handler_chart.field_note'),
                controller: noteCtrl,
              ),
              const SizedBox(height: UgamSpacing.lg),
              UgamCTA(
                label: tr('handler_chart.save_handover'),
                onPressed: () async {
                  final note = noteCtrl.text.trim();
                  final handed = double.tryParse(handedCtrl.text.trim()) ?? 0;
                  final base = existing ??
                      BusHandover(
                        tourId: tourId,
                        busId: bus.id,
                        expectedAmount: expected,
                      );
                  final updated = base.copyWith(
                    busId: bus.id,
                    expectedAmount: expected,
                    handedOverAmount: handed,
                    note: note.isEmpty ? null : note,
                  );
                  try {
                    final saved =
                        await _store.handlerUpsertHandover(widget.requestId, updated);
                    if (saved == null) {
                      throw StateError('Handler handover save was rejected.');
                    }
                    if (!mounted) return;
                    setState(() => _handovers[saved.id] = saved);
                    Navigator.of(sheetCtx).pop();
                  } catch (_) {
                    AppSnackBar.error(tr('handler_chart.error_save_handover'));
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
```

- [ ] **Step 6: Split the hero + add the CTA and read-back list**

Extend `_SummaryHeader` (~line 1615) to carry the two new figures and an `onHandOver` callback, and render them:

```dart
class _SummaryHeader extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;
  final double spent;
  final double income;
  final double rent;
  final double inHand;
  final double handedOver;
  final double outstanding;
  final VoidCallback onHandOver;

  const _SummaryHeader({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
    required this.rent,
    required this.inHand,
    required this.handedOver,
    required this.outstanding,
    required this.onHandOver,
  });
```

In its `build`, after the existing `rent` breakdown line (inside the `breakdown: [ ... ]` list), add:

```dart
        HeroStatLine(
          tr('handler_chart.stat_handed_over'),
          Formatters.formatMoneyInr(handedOver),
          tone: c.good,
        ),
        HeroStatLine(
          tr('handler_chart.stat_outstanding'),
          Formatters.formatMoneyInr(outstanding),
          tone: c.accent,
        ),
```

Then, after the `UgamHeroStat(...)` (wrap the return in a `Column` so the CTA sits under the hero):

```dart
    return Column(
      children: [
        UgamHeroStat( /* ...existing args... */ ),
        const SizedBox(height: UgamSpacing.sm),
        UgamCTA(
          label: outstanding > 0.005
              ? tr(
                  'handler_chart.hand_over_outstanding',
                  namedArgs: {'amount': Formatters.formatMoneyInr(outstanding)},
                )
              : tr('handler_chart.hand_over_cash'),
          onPressed: onHandOver,
        ),
      ],
    );
```

Update the call site (~line 789) to pass the new args and wire the CTA:

```dart
                _SummaryHeader(
                  collected: summary.collected,
                  toReturn: summary.toReturn,
                  toCollect: summary.toCollect,
                  spent: summary.spent,
                  income: summary.income,
                  rent: summary.rent,
                  inHand: summary.inHand,
                  handedOver: summary.handedOver,
                  outstanding: summary.outstandingHandover,
                  onHandOver: () =>
                      _showHandoverSheet(bus, summary.expectedHandover),
                ),
```

Add a read-back list widget and render it under the income section (inside the `if (grid) ...[` block, after `_IncomeSection`, ~line 828):

```dart
                  const SizedBox(height: UgamSpacing.xl),
                  _HandoverList(
                    handovers: _handoversForBus(bus.id),
                    onTap: (h) => _showHandoverSheet(
                      bus, summary.expectedHandover, existing: h),
                  ),
```

Define `_HandoverList` (place near `_ExpensesSection`, ~line 2047):

```dart
/// Read-back of the cash handovers logged for this bus, newest work at the
/// bottom. Tapping a row re-opens the sheet to correct it.
class _HandoverList extends StatelessWidget {
  final List<BusHandover> handovers;
  final ValueChanged<BusHandover> onTap;

  const _HandoverList({required this.handovers, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('handler_chart.handovers_title'),
          style: UgamText.titleM.copyWith(color: c.ink),
        ),
        const SizedBox(height: UgamSpacing.sm),
        if (handovers.isEmpty)
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(
              vertical: UgamSpacing.lg, horizontal: UgamSpacing.md),
            child: Text(
              tr('handler_chart.no_handovers'),
              style: UgamText.caption.copyWith(color: c.ink3),
            ),
          )
        else
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
            child: Column(
              children: [
                for (final h in handovers)
                  GestureDetector(
                    onTap: () => onTap(h),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.md,
                        vertical: UgamSpacing.sm + 2,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              (h.note ?? '').trim().isEmpty
                                  ? tr('handler_chart.handover_row')
                                  : h.note!.trim(),
                              style: UgamText.bodyStrong.copyWith(color: c.ink),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.sm),
                          Text(
                            Formatters.formatMoneyInr(h.handedOverAmount),
                            style: UgamText.tabular(
                              UgamText.bodyStrong.copyWith(color: c.good),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 7: Add translation keys to all three bundles**

In `assets/translations/en.json`, inside the `handler_chart` block (near `stat_in_hand`, ~line 1965), add:

```json
    "stat_handed_over": "Handed over",
    "stat_outstanding": "Still to hand over",
    "hand_over_cash": "Hand over cash",
    "hand_over_outstanding": "Hand over {amount}",
    "edit_handover": "Edit handover",
    "handover_expected": "Expected to hand over: {amount}",
    "field_handed_over": "Handed over",
    "handovers_title": "Cash handed over",
    "handover_row": "Cash handover",
    "no_handovers": "No cash handed over yet. Tap \"Hand over cash\" to record a remittance.",
    "error_save_handover": "Couldn't save the handover. Please try again.",
```

Add the SAME keys with Gujarati values to `assets/translations/gu.json` and Hindi to `assets/translations/hi.json` (mirror the existing `handler_chart` translations there). Note: `field_note` already exists in `handler_chart`? If not, add `"field_note": "Note"` (en) / localized siblings — check before adding to avoid a duplicate-key lint.

- [ ] **Step 8: Run analyzer + the handler screen tests + i18n sync check**

Run: `flutter analyze lib/screens/handler_bus_chart_screen.dart`
Expected: no new errors.

Run: `flutter test test/screens/handler_bus_chart_screen_test.dart`
Expected: PASS (3 tests: 2 existing + the Step-1 guard).

Verify all three bundles have identical key sets (no missing translations):

Run: `dart run tool/verify_i18n.dart` if it exists, otherwise eyeball that each new key exists in en/gu/hi.

- [ ] **Step 9: Commit**

```bash
git add lib/screens/handler_bus_chart_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json test/screens/handler_bus_chart_screen_test.dart
git commit -m "feat(handler): hand-over-cash CTA, hero split, and read-back list"
```

---

### Task 6: H-8 — hide delete/edit on admin-originated ledger rows

**Files:**
- Modify: `lib/screens/handler_bus_chart_screen.dart` (`_ExpensesSection`/`_IncomeSection` + rows, ~2047–2594)
- Test: `test/models/ledger_source_test.dart` (extend with the pure gate predicate)

**Interfaces:**
- Consumes: `Expense.source` / `IncomeEntry.source` (Task 2).
- Produces: top-level `bool handlerCanModifyLedger(String source)` in `handler_bus_chart_screen.dart` (returns `source == 'handler'`), used to gate the row's edit tap + delete glyph.

- [ ] **Step 1: Write the failing test** (append to `test/models/ledger_source_test.dart`)

```dart
  test('handlerCanModifyLedger only allows handler-originated rows', () {
    expect(handlerCanModifyLedger('handler'), isTrue);
    expect(handlerCanModifyLedger('admin'), isFalse);
    expect(handlerCanModifyLedger('anything-else'), isFalse);
  });
```

Add the import:

```dart
import 'package:occubusbooking/screens/handler_bus_chart_screen.dart'
    show handlerCanModifyLedger;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/ledger_source_test.dart`
Expected: FAIL — `handlerCanModifyLedger` is undefined.

- [ ] **Step 3: Add the predicate + gate the rows**

At the top level of `lib/screens/handler_bus_chart_screen.dart` (after the imports, before the screen class):

```dart
/// Whether the handler may edit/delete a ledger row. Only rows the handler
/// logged on the ground ('handler') are theirs to change — admin-logged rows
/// ('admin', the default) are read-only to the handler so reconciliation can't
/// be corrupted (H-8).
bool handlerCanModifyLedger(String source) => source == 'handler';
```

In `_HandlerExpenseRow.build` (~2160), wrap the tap + delete glyph so admin rows are inert. Replace the row's `GestureDetector(onTap: onTap, ...)` gate and the trailing delete `Semantics(...)` with a `canModify` guard. Add a `final bool canModify;` field to `_HandlerExpenseRow` (constructor arg), pass `onTap: canModify ? onTap : null`, and render the delete glyph only `if (canModify)`.

Where `_HandlerExpenseRow` is built inside `_ExpensesSection` (~2130):

```dart
                for (final e in expenses)
                  _HandlerExpenseRow(
                    expense: e,
                    canModify: handlerCanModifyLedger(e.source),
                    onTap: () => onEdit(e),
                    onDelete: () => onDelete(e),
                  ),
```

Apply the identical change to the income row widget (the analogue near ~2580) and its section: add `canModify: handlerCanModifyLedger(i.source)`, guard `onTap`, and render the delete `Semantics(...)` only when `canModify`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/ledger_source_test.dart`
Expected: PASS

Run: `flutter analyze lib/screens/handler_bus_chart_screen.dart`
Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/handler_bus_chart_screen.dart test/models/ledger_source_test.dart
git commit -m "feat(handler): hide edit/delete on admin-logged ledger rows (H-8)"
```

---

### Task 7: CALC-1 — `Passenger.billedAmount` snapshot field

**Files:**
- Modify: `lib/models/passenger.dart`
- Test: `test/models/passenger_billed_amount_test.dart` (create)

**Interfaces:**
- Produces: `Passenger.billedAmount` → `double?` (nullable), round-tripped as `passengers.billed_amount` in `toMap`/`fromMap`, settable via `copyWith({double? billedAmount})`.

- [ ] **Step 1: Write the failing test** (`test/models/passenger_billed_amount_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';

void main() {
  test('billedAmount defaults null, round-trips, and copyWith sets it', () {
    final p = Passenger(tourId: 't1', name: 'A', phone: '+910000000000');
    expect(p.billedAmount, isNull);
    expect(p.toMap()['billed_amount'], isNull);

    final stamped = p.copyWith(billedAmount: 1500);
    expect(stamped.billedAmount, 1500);
    expect(stamped.toMap()['billed_amount'], 1500);

    final parsed = Passenger.fromMap({
      'id': 'p1', 'tour_id': 't1', 'name': 'A', 'phone': '+910000000000',
      'billed_amount': 2000,
    });
    expect(parsed.billedAmount, 2000);

    // Legacy row with no column stays null.
    final legacy = Passenger.fromMap({
      'id': 'p2', 'tour_id': 't1', 'name': 'B', 'phone': '+910000000000',
    });
    expect(legacy.billedAmount, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/passenger_billed_amount_test.dart`
Expected: FAIL — `billedAmount` undefined.

- [ ] **Step 3: Write minimal implementation** (`lib/models/passenger.dart`)

Field (after `seatsNotifiedSig`, ~line 104):

```dart
  /// Frozen per-passenger billed fare, stamped when their leg completes and
  /// their seats are cleared (see `TourController.completeOutboundLeg`). Lets
  /// the P&L keep counting earned revenue after the live seat is gone. Null
  /// until stamped — read sites fall back to the live seat-derived due.
  final double? billedAmount;
```

Constructor param (after `this.seatsNotifiedSig,`):

```dart
    this.billedAmount,
```

`toMap` (add key, after `'seats_notified_sig'`):

```dart
      'billed_amount': billedAmount,
```

`fromMap` (add before the closing `);`, after `seatsNotifiedSig:`):

```dart
      billedAmount: (map['billed_amount'] as num?)?.toDouble(),
```

`copyWith` — add `double? billedAmount,` to the params and `billedAmount: billedAmount ?? this.billedAmount,` to the returned `Passenger(`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/passenger_billed_amount_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/models/passenger.dart test/models/passenger_billed_amount_test.dart
git commit -m "feat(calc): persist Passenger.billedAmount snapshot"
```

---

### Task 8: Migration `043_billed_snapshot.sql` — `passengers.billed_amount` column

**Files:**
- Create: `supabase/migrations/043_billed_snapshot.sql`

**Interfaces:**
- Produces (Postgres): `passengers.billed_amount numeric` (nullable). No RPC change — passenger rows are written by `smartUpdate` with the full `toMap`, so the column simply needs to exist.

> **Deploy ordering:** must be live BEFORE any client build ships the `Passenger.toMap` change from Task 7 (passenger writes send every `toMap` key; a missing column fails with `42703`).

- [ ] **Step 1: Write the migration file** (`supabase/migrations/043_billed_snapshot.sql`)

```sql
-- ============================================================
-- 043  Billed-revenue snapshot on passengers
-- ------------------------------------------------------------
-- The "true billed" P&L recomputes each rider's fare live from their assigned
-- seats. When completeOutboundLeg clears an outbound-only rider's seats, their
-- live fare collapses to 0, so the billed-net headline understates by their
-- fare and paradoxically dips below the cash-net (CALC-1).
--
-- Fix: persist a per-passenger billed snapshot, stamped by the client at
-- leg-completion BEFORE the seats are cleared. The read side (money_controller
-- _billedRevenues) prefers this snapshot and falls back to the live seat due
-- when null. This migration only adds the nullable column.
--
-- NOTE: passenger rows are written with the full model map (no server-side
-- column whitelist), so this column MUST exist before a client that writes
-- billed_amount ships, or every passenger write fails with 42703.
--
-- ADDITIVE + idempotent: `add column if not exists`. Safe on live data.
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

alter table public.passengers
  add column if not exists billed_amount numeric;
```

- [ ] **Step 2: Deploy + verify in the live Supabase SQL editor**

Run the file, then verify:

```sql
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_schema = 'public'
   and table_name = 'passengers'
   and column_name = 'billed_amount';
```

Expected: one row, `numeric`, `is_nullable = YES`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/043_billed_snapshot.sql
git commit -m "feat(db): 043 billed_amount snapshot column on passengers"
```

---

### Task 9: CALC-1 — stamp `billedAmount` in `completeOutboundLeg`

**Files:**
- Modify: `lib/controllers/tour_controller.dart` (`completeOutboundLeg`, ~line 710–747)
- Test: `test/controllers/tour_controller_test.dart` (extend)

**Interfaces:**
- Consumes: `Passenger.copyWith(billedAmount:)` (Task 7), `Bus.amountDueFor` (`bus_details.dart`).
- Produces: retired outbound-only riders carry `billedAmount = Σ over tour.buses of b.amountDueFor(p)`, stamped in the SAME `copyWith` that clears their seats.

- [ ] **Step 1: Write the failing test** (append inside `main()` in `test/controllers/tour_controller_test.dart`; the file already defines `_RecordingSync`, `_tourWith`, `SeatAssignment`, `RequestLine`, `SeatType`, `TripType`, `BusLayout`, `BusType`)

```dart
  test('completeOutboundLeg stamps billedAmount before clearing seats', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();

    final bus = Bus(
      id: 'b1',
      name: 'Bus 1',
      busType: 'Seater',
      layout: BusLayout.generate(busType: BusType.seater, totalSeats: 30),
      pricePerSeat: 1000,
    );
    // A real seat id from the generated layout so amountDueFor resolves > 0.
    final seatId =
        bus.layout.cells.firstWhere((c) => c.seatType != null).id;

    final rider = Passenger(
      id: 'ob1', tourId: 't1', name: 'ob1', phone: '+910000000000',
      tripType: TripType.outboundOnly,
      requestLines: [RequestLine(seatType: SeatType.seater, qty: 1)],
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seatId)],
    );

    ctrl.tours.assignAll([
      _tourWith([rider], buses: [bus], status: TourStatus.locked),
    ]);

    // Fare the live engine bills this rider RIGHT NOW (before the clear).
    final before = ctrl.getTour('t1')!;
    final expected = before.buses
        .fold(0.0, (s, b) => s + b.amountDueFor(before.passengers.first));
    expect(expected, greaterThan(0)); // sanity: the bus actually bills them

    await ctrl.completeOutboundLeg('t1');

    final after = ctrl.getTour('t1')!.passengers.first;
    expect(after.assignedSeats, isEmpty);   // seats cleared…
    expect(after.journeyDone, isTrue);      // …rider retired…
    expect(after.billedAmount, expected);   // …but their fare is frozen.
  });
```

> If `bus.layout.cells` / `.id` / `.seatType` are named differently in `SeatLayout`, read the model and pick the equivalent accessor for "a seatable cell id"; the assertion structure is unchanged.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/controllers/tour_controller_test.dart -n "stamps billedAmount"`
Expected: FAIL — `after.billedAmount` is `null` (not yet stamped).

- [ ] **Step 3: Write minimal implementation**

In `completeOutboundLeg` (`lib/controllers/tour_controller.dart`), inside the `optimistic:` loop, replace the `copyWith` so it also stamps the billed snapshot (compute it from the CURRENT rider `cur`, before the seats are wiped in the same call):

```dart
      optimistic: () {
        for (final p in tour.passengers) {
          if (p.tripType != TripType.outboundOnly || p.journeyDone) continue;
          Passenger? updated;
          _updatePassengerLocal(tourId, p.id, (cur) {
            // Freeze the billed fare BEFORE clearing seats so the P&L can keep
            // counting this rider's earned revenue once their seat is gone.
            final billed = tour.buses
                .fold(0.0, (sum, b) => sum + b.amountDueFor(cur));
            updated = cur.copyWith(
              assignedSeats: const [],
              journeyDone: true,
              billedAmount: billed,
            );
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/controllers/tour_controller_test.dart -n "stamps billedAmount"`
Expected: PASS

Run the whole controller suite to confirm no regression:

Run: `flutter test test/controllers/tour_controller_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/controllers/tour_controller.dart test/controllers/tour_controller_test.dart
git commit -m "feat(calc): stamp billedAmount when completing the outbound leg"
```

---

### Task 10: CALC-1 — billed-revenue read prefers the snapshot

**Files:**
- Create: `lib/models/billed_revenue.dart`
- Modify: `lib/controllers/money_controller.dart` (`_billedRevenues`, ~342–353)
- Test: `test/models/billed_revenue_test.dart` (create)

**Interfaces:**
- Consumes: `Tour` (`.buses`, `.passengers`), `Bus.amountDueFor`, `Passenger.billedAmount` (Task 7), `Collection` (`.passengerId`, `.busId`).
- Produces: `BilledRevenue.forTour({required Tour tour, required List<Collection> collections}) → Map<String, double>` — per-bus billed revenue. Active riders use live `amountDueFor`; a retired rider (no live seats) with a non-null `billedAmount` is attributed to the bus their collection row names.

> **Design note:** the reported paradox (`netBilled < netCollected`) is caused by riders who PAID (so they sit in `netCollected`) but whose live fare dropped to 0. Those riders always have a collection row, so resolving a retired rider's bus from their collection row exactly covers the paradox. A retired-and-never-collected rider (no collection row) can't be re-attributed to a bus and is a documented approximation (their fare was never collected, so it can't create the paradox).

- [ ] **Step 1: Write the failing test** (`test/models/billed_revenue_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/billed_revenue.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';

Bus _bus() => Bus(
      id: 'b1', name: 'Bus 1', busType: 'Seater',
      layout: BusLayout.generate(busType: BusType.seater, totalSeats: 30),
      pricePerSeat: 1000,
    );

Tour _tour(List<Passenger> pax, Bus bus) => Tour(
      id: 't1', title: 'T', fromCity: 'A', toCity: 'B',
      departureDate: DateTime(2026, 7, 1), pricePerSeat: 1000,
      buses: [bus], passengers: pax,
    );

void main() {
  test('active rider uses live amountDueFor', () {
    final bus = _bus();
    final seatId = bus.layout.cells.firstWhere((c) => c.seatType != null).id;
    final p = Passenger(
      id: 'p1', tourId: 't1', name: 'A', phone: '+910000000000',
      requestLines: [RequestLine(seatType: SeatType.seater, qty: 1)],
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seatId)],
    );
    final live = bus.amountDueFor(p);
    final rev = BilledRevenue.forTour(tour: _tour([p], bus), collections: const []);
    expect(rev['b1'], live);
    expect(live, greaterThan(0));
  });

  test('retired rider (no seats) uses billedAmount via their collection bus', () {
    final bus = _bus();
    final retired = Passenger(
      id: 'p1', tourId: 't1', name: 'A', phone: '+910000000000',
      tripType: TripType.outboundOnly, journeyDone: true,
      assignedSeats: const [], // seats cleared at leg completion
      billedAmount: 1500,      // frozen fare
    );
    final collections = [
      Collection(
        tourId: 't1', busId: 'b1', passengerId: 'p1', seatId: 'X1',
        amountDue: 1500, amountReceived: 1500,
      ),
    ];
    final rev = BilledRevenue.forTour(tour: _tour([retired], bus), collections: collections);
    expect(rev['b1'], 1500); // fare preserved despite cleared seats
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/billed_revenue_test.dart`
Expected: FAIL — `billed_revenue.dart` / `BilledRevenue` does not exist.

- [ ] **Step 3: Write the pure function** (`lib/models/billed_revenue.dart`)

```dart
import 'bus_details.dart';
import 'collection.dart';
import 'tour.dart';

/// Per-bus BILLED (accrual) revenue for a tour — what each bus's seated riders
/// owe, whether or not it's been collected yet.
///
/// Prefers each rider's persisted [Passenger.billedAmount] snapshot (stamped
/// when their leg completes and their seats are cleared) so a completed leg
/// can't erase earned revenue; falls back to the live seat-derived due
/// ([Bus.amountDueFor]) while the rider still holds seats.
class BilledRevenue {
  const BilledRevenue._();

  static Map<String, double> forTour({
    required Tour tour,
    required List<Collection> collections,
  }) {
    final out = {for (final b in tour.buses) b.id: 0.0};

    // The bus a retired rider was billed on, recovered from their collection
    // row (their seats are cleared once their leg completes).
    final busByPassenger = <String, String>{};
    for (final col in collections) {
      busByPassenger.putIfAbsent(col.passengerId, () => col.busId);
    }

    for (final p in tour.passengers) {
      // Live per-bus due — > 0 only on the bus the rider currently sits on.
      var seated = false;
      for (final b in tour.buses) {
        final live = b.amountDueFor(p);
        if (live > 0) {
          out[b.id] = (out[b.id] ?? 0) + live;
          seated = true;
        }
      }
      if (seated) continue; // live seats are authoritative

      // Retired / cleared rider: restore their frozen fare so the completed
      // leg doesn't erase earned revenue. Attribute to the bus their
      // collection row names.
      final snap = p.billedAmount;
      if (snap == null || snap == 0) continue;
      final busId = busByPassenger[p.id];
      if (busId != null && out.containsKey(busId)) {
        out[busId] = (out[busId] ?? 0) + snap;
      }
    }
    return out;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/billed_revenue_test.dart`
Expected: PASS

- [ ] **Step 5: Wire it into the controller**

In `lib/controllers/money_controller.dart`, add the import:

```dart
import '../models/billed_revenue.dart';
```

Replace the body of `_billedRevenues` (~342–353) with a delegation:

```dart
  Map<String, double> _billedRevenues() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) {
      return const {};
    }
    final tour = Get.find<TourController>().getTour(tourId);
    if (tour == null) return const {};
    return BilledRevenue.forTour(
      tour: tour,
      collections: collections.toList(),
    );
  }
```

- [ ] **Step 6: Run the money model suite + analyzer**

Run: `flutter test test/models/`
Expected: PASS (billed_revenue + money_summary + handler_bus_money all green).

Run: `flutter analyze lib/controllers/money_controller.dart lib/models/billed_revenue.dart`
Expected: no new errors.

- [ ] **Step 7: Commit**

```bash
git add lib/models/billed_revenue.dart lib/controllers/money_controller.dart test/models/billed_revenue_test.dart
git commit -m "feat(calc): billed revenue prefers persisted snapshot over live seats"
```

---

### Task 11: AL-2 — WhatsApp settings reachable from Settings

**Files:**
- Modify: `lib/screens/settings_screen.dart` (~line 117–142, the Notifications/Pickup card)
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json`
- Test: none feasible at the full-screen level (documented) — verify via analyzer.

**Interfaces:**
- Consumes: `WhatsAppSettingsScreen` (`lib/screens/whatsapp_settings_screen.dart`), existing `settings.whatsapp_title` key (en.json:124).
- Produces: a Settings `_SettingsRow` that pushes `WhatsAppSettingsScreen`.

> **Testing note:** the full `SettingsScreen` mounts `AuthController`, `ThemeController`, `FinanceController`, and `Supabase.instance` (uninitialised under `flutter test`), so it can't be widget-tested here — the existing `settings_screen_test.dart` deliberately tests only the `BiometricToggle` sub-widget. This change is a purely additive row using the established `_SettingsRow` pattern; verify with `flutter analyze` + manual smoke (open Settings → tap WhatsApp).

- [ ] **Step 1: Add the import** (top of `lib/screens/settings_screen.dart`, with the other screen imports)

```dart
import 'whatsapp_settings_screen.dart';
```

- [ ] **Step 2: Add the row** (inside the settings card `Column`, after the Notifications row's `_Divider(c: c)` at ~line 130, before the Pickup row)

```dart
                          _SettingsRow(
                            c: c,
                            icon: Icons.chat_outlined,
                            iconTone: UgamStatVariant.neutral,
                            title: tr('settings.whatsapp_title'),
                            subtitle: tr('settings.whatsapp_subtitle'),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const WhatsAppSettingsScreen(),
                              ),
                            ),
                          ),
                          _Divider(c: c),
```

- [ ] **Step 3: Add the subtitle key to all three bundles**

`settings.whatsapp_title` already exists (en.json:124 "WhatsApp Settings"). Add a sibling `whatsapp_subtitle` in the `settings` block of `en.json`:

```json
    "whatsapp_subtitle": "Handoff number & announcement signature",
```

Add the matching localized subtitle to `gu.json` and `hi.json` `settings` blocks.

- [ ] **Step 4: Verify it compiles**

Run: `flutter analyze lib/screens/settings_screen.dart`
Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/settings_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json
git commit -m "feat(settings): reach WhatsApp settings from the Settings screen (AL-2)"
```

---

## Final verification

- [ ] Run the full test suite: `flutter test`
      Expected: all pass (78+ files; new: `ledger_source_test`, `passenger_billed_amount_test`, `billed_revenue_test`; extended: `handler_bus_money_test`, `tour_controller_test`, `handler_bus_chart_screen_test`).
- [ ] Run `flutter analyze` — expect 0 errors (the pre-existing 6 info/warning items may remain).
- [ ] Confirm migrations `042` and `043` are deployed to the live DB (verification queries in Tasks 3 & 8 return the expected shapes) BEFORE building a release binary.
- [ ] Confirm en/gu/hi have identical key sets for every key added in Tasks 5 & 11.

## Self-review checklist (completed while writing)

- **Spec coverage:** H-1 → Tasks 1,3,4,5; CALC-1 → Tasks 7,8,9,10; AL-2 → Task 11; H-8 → Tasks 2,3(cols),6.
- **Type consistency:** `handedOver`/`expectedHandover`/`outstandingHandover` (Task 1) consumed unchanged in Task 5; `source` (Task 2) consumed in Tasks 3 & 6; `billedAmount` (Task 7) consumed in Tasks 9 & 10; `BilledRevenue.forTour` signature identical in Task 10 def + use.
- **No placeholders:** every code/SQL step is concrete; the two "read the model to confirm the accessor name" notes (SeatLayout cell id) are the only implementer judgement calls and are flagged inline.
