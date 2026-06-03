# Seat Assignment — Phase 1: Data Model Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the data foundation for smart seat assignment — passenger groups, a priority request→approve flow, reserved seats, and locked assignments — with full model + DB coverage.

**Architecture:** Additive only. Two new persisted concepts get DDL (`passenger_groups` table + 3 `passengers` columns). Two concepts live inside existing jsonb blobs and need no DDL (`SeatCell.reserved` inside `buses.layout`, `SeatAssignment.locked` inside `passengers.assigned_seats`). All Dart models follow the existing `toMap`/`fromMap`/`fromString`-with-`orElse` patterns; new fields are backward-compatible (missing key → safe default).

**Tech Stack:** Flutter/Dart, `flutter_test`, Supabase Postgres (offline-first via SyncService). Package name: `occubusbooking`.

---

## File Structure

| File | Responsibility | Action |
|------|----------------|--------|
| `lib/models/priority_status.dart` | `PriorityStatus` enum (none/requested/approved/declined) | Create |
| `lib/models/passenger_group.dart` | `PassengerGroup` model (cross-booking same-bus link) | Create |
| `lib/models/seat_assignment.dart` | add `locked` berth flag | Modify |
| `lib/models/seat_layout.dart` | add `reserved` cell flag to `SeatCell` | Modify |
| `lib/models/passenger.dart` | add `groupId`, `priorityStatus`, `priorityReason` | Modify |
| `supabase/migrations/006_seat_groups_priority.sql` | DDL: table + columns + indexes + RLS | Create |
| `database.sql` | mirror the new table/columns into the canonical schema | Modify |
| `test/models/priority_status_test.dart` | tests | Create |
| `test/models/passenger_group_test.dart` | tests | Create |
| `test/models/seat_assignment_test.dart` | tests | Create |
| `test/models/seat_cell_test.dart` | tests | Create |
| `test/models/passenger_priority_group_test.dart` | tests | Create |

**Critical correctness rules (do not violate):**
- `SeatAssignment` equality/hashCode stay `(busId, seatId)` only — **never** add `locked`, or occupancy lookups (`assignedSeats.contains(...)`) break.
- `SeatCell` equality/hashCode stay `(row, col, position)` only — **never** add `reserved`.
- Booleans serialize **only when true** (`if (locked) 'locked': true`) to keep jsonb lean; `fromMap` defaults missing → `false`.

---

## Task 1: `PriorityStatus` enum

**Files:**
- Create: `lib/models/priority_status.dart`
- Test: `test/models/priority_status_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/models/priority_status_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/priority_status.dart';

void main() {
  group('PriorityStatus', () {
    test('fromString maps known names', () {
      expect(PriorityStatus.fromString('approved'), PriorityStatus.approved);
      expect(PriorityStatus.fromString('requested'), PriorityStatus.requested);
      expect(PriorityStatus.fromString('declined'), PriorityStatus.declined);
      expect(PriorityStatus.fromString('none'), PriorityStatus.none);
    });

    test('fromString falls back to none for null/unknown', () {
      expect(PriorityStatus.fromString(null), PriorityStatus.none);
      expect(PriorityStatus.fromString('garbage'), PriorityStatus.none);
    });

    test('isApproved / isPending helpers', () {
      expect(PriorityStatus.approved.isApproved, isTrue);
      expect(PriorityStatus.requested.isPending, isTrue);
      expect(PriorityStatus.approved.isPending, isFalse);
      expect(PriorityStatus.none.isApproved, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/priority_status_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:occubusbooking/models/priority_status.dart'`.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/models/priority_status.dart
/// Whether a passenger has an approved need for a priority (front / sofa) seat.
///
/// Priority is REQUESTED by the customer (an optional note) and APPROVED by the
/// agent. Only [approved] passengers are seated in front/sofa seats first by the
/// seating engine. Age is never auto-derived into priority.
enum PriorityStatus {
  none,
  requested,
  approved,
  declined;

  bool get isApproved => this == PriorityStatus.approved;
  bool get isPending => this == PriorityStatus.requested;

  String get displayName {
    switch (this) {
      case PriorityStatus.none:
        return 'None';
      case PriorityStatus.requested:
        return 'Priority requested';
      case PriorityStatus.approved:
        return 'Priority approved';
      case PriorityStatus.declined:
        return 'Priority declined';
    }
  }

  static PriorityStatus fromString(String? value) {
    if (value == null) return PriorityStatus.none;
    return PriorityStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PriorityStatus.none,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/priority_status_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/models/priority_status.dart test/models/priority_status_test.dart
git commit -m "feat(model): add PriorityStatus enum for priority-seat request/approve"
```

---

## Task 2: `SeatAssignment.locked`

**Files:**
- Modify: `lib/models/seat_assignment.dart`
- Test: `test/models/seat_assignment_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/models/seat_assignment_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_assignment.dart';

void main() {
  group('SeatAssignment.locked', () {
    test('defaults to false and is omitted from toMap when false', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'DL3');
      expect(a.locked, isFalse);
      expect(a.toMap().containsKey('locked'), isFalse);
    });

    test('serializes locked=true and round-trips', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'DL3', locked: true);
      expect(a.toMap()['locked'], true);
      final back = SeatAssignment.fromMap(a.toMap());
      expect(back.locked, isTrue);
    });

    test('fromMap defaults locked to false when key missing', () {
      final a = SeatAssignment.fromMap({'busId': 'b1', 'seatId': 'DL3'});
      expect(a.locked, isFalse);
    });

    test('equality and hashCode ignore locked (occupancy lookups must work)', () {
      const free = SeatAssignment(busId: 'b1', seatId: 'DL3');
      const locked = SeatAssignment(busId: 'b1', seatId: 'DL3', locked: true);
      expect(free, equals(locked));
      expect(free.hashCode, locked.hashCode);
      expect([free].contains(locked), isTrue);
    });

    test('copyWith toggles locked, keeps identity', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'DL3');
      final b = a.copyWith(locked: true);
      expect(b.busId, 'b1');
      expect(b.seatId, 'DL3');
      expect(b.locked, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/seat_assignment_test.dart`
Expected: FAIL — `locked` named param / `copyWith` not defined.

- [ ] **Step 3: Write minimal implementation**

Replace the entire contents of `lib/models/seat_assignment.dart` with:

```dart
/// A single seat assignment: ties a passenger to a specific seat on a specific bus.
///
/// Example: `SeatAssignment(busId: "bus_abc", seatId: "DL3")`
///
/// [locked] marks a berth the agent placed/confirmed by hand. A seating-engine
/// re-generate must never move a locked assignment. It is NOT part of identity:
/// equality/hashCode key off (busId, seatId) only, so occupancy lookups
/// (`assignedSeats.contains(target)`) keep working regardless of lock state.
class SeatAssignment {
  final String busId;
  final String seatId;
  final bool locked;

  const SeatAssignment({
    required this.busId,
    required this.seatId,
    this.locked = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'busId': busId,
      'seatId': seatId,
      if (locked) 'locked': true,
    };
  }

  factory SeatAssignment.fromMap(Map<String, dynamic> map) {
    return SeatAssignment(
      busId: map['busId'] as String,
      seatId: map['seatId'] as String,
      locked: map['locked'] as bool? ?? false,
    );
  }

  SeatAssignment copyWith({bool? locked}) {
    return SeatAssignment(
      busId: busId,
      seatId: seatId,
      locked: locked ?? this.locked,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeatAssignment && other.busId == busId && other.seatId == seatId;

  @override
  int get hashCode => Object.hash(busId, seatId);

  @override
  String toString() => 'SeatAssignment($busId:$seatId${locked ? ' locked' : ''})';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/seat_assignment_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/models/seat_assignment.dart test/models/seat_assignment_test.dart
git commit -m "feat(model): add locked flag to SeatAssignment (survives re-generate)"
```

---

## Task 3: `SeatCell.reserved`

**Files:**
- Modify: `lib/models/seat_layout.dart` (the `SeatCell` class, lines ~38–114)
- Test: `test/models/seat_cell_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/models/seat_cell_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';

void main() {
  group('SeatCell.reserved', () {
    test('defaults to false and is omitted from toMap when false', () {
      const c = SeatCell(
        row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1',
      );
      expect(c.reserved, isFalse);
      expect(c.toMap().containsKey('reserved'), isFalse);
    });

    test('serializes reserved=true and round-trips', () {
      const c = SeatCell(
        row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1', reserved: true,
      );
      expect(c.toMap()['reserved'], true);
      final back = SeatCell.fromMap(c.toMap());
      expect(back.reserved, isTrue);
      expect(back.seatId, 'ST1');
    });

    test('fromMap defaults reserved to false when key missing', () {
      final c = SeatCell.fromMap({'row': 1, 'col': 1});
      expect(c.reserved, isFalse);
    });

    test('equality/hashCode ignore reserved (identity is row,col,position)', () {
      const a = SeatCell(row: 2, col: 3, seatType: SeatType.doubleSofa,
          position: SeatPosition.upper, seatId: 'DU2');
      const b = SeatCell(row: 2, col: 3, seatType: SeatType.doubleSofa,
          position: SeatPosition.upper, seatId: 'DU2', reserved: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith sets reserved', () {
      const c = SeatCell(row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1');
      expect(c.copyWith(reserved: true).reserved, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/seat_cell_test.dart`
Expected: FAIL — `reserved` named param not defined.

- [ ] **Step 3: Write minimal implementation**

In `lib/models/seat_layout.dart`, change the `SeatCell` field list + constructor (lines ~39–51) to add `reserved`:

```dart
class SeatCell {
  final int row;
  final int col;
  final SeatType? seatType;
  final SeatPosition? position; // null for Seater and for empty cells
  final String? seatId; // auto-generated, e.g. "DL3"

  /// True when the agent has held this seat back (driver area, VIP hold, etc.).
  /// The seating engine never auto-fills a reserved seat. Not part of identity.
  final bool reserved;

  const SeatCell({
    required this.row,
    required this.col,
    this.seatType,
    this.position,
    this.seatId,
    this.reserved = false,
  });
```

Update `toMap()` (lines ~65–73) to include `reserved` only when true:

```dart
  Map<String, dynamic> toMap() {
    return {
      'row': row,
      'col': col,
      if (seatType != null) 'seatType': seatType!.name,
      if (position != null) 'position': position!.name,
      if (seatId != null) 'seatId': seatId,
      if (reserved) 'reserved': true,
    };
  }
```

Update `fromMap()` (lines ~75–84) to parse `reserved`:

```dart
  factory SeatCell.fromMap(Map<String, dynamic> map) {
    final typeStr = map['seatType'] as String?;
    return SeatCell(
      row: (map['row'] as num).toInt(),
      col: (map['col'] as num).toInt(),
      seatType: typeStr != null ? SeatType.fromString(typeStr) : null,
      position: SeatPosition.fromString(map['position'] as String?),
      seatId: map['seatId'] as String?,
      reserved: map['reserved'] as bool? ?? false,
    );
  }
```

Update `copyWith()` (lines ~86–102) to carry `reserved` (clearSeat still returns a bare empty cell):

```dart
  SeatCell copyWith({
    SeatType? seatType,
    SeatPosition? position,
    String? seatId,
    bool? reserved,
    bool clearSeat = false,
  }) {
    if (clearSeat) {
      return SeatCell(row: row, col: col);
    }
    return SeatCell(
      row: row,
      col: col,
      seatType: seatType ?? this.seatType,
      position: position ?? this.position,
      seatId: seatId ?? this.seatId,
      reserved: reserved ?? this.reserved,
    );
  }
```

Leave `operator ==` and `hashCode` (lines ~104–113) UNCHANGED — identity stays `(row, col, position)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/seat_cell_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/models/seat_layout.dart test/models/seat_cell_test.dart
git commit -m "feat(model): add reserved flag to SeatCell (engine never auto-fills)"
```

---

## Task 4: `PassengerGroup` model

**Files:**
- Create: `lib/models/passenger_group.dart`
- Test: `test/models/passenger_group_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/models/passenger_group_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger_group.dart';

void main() {
  group('PassengerGroup', () {
    test('generates an id and defaults colorIndex to 0', () {
      final g = PassengerGroup(tourId: 't1', label: 'Patel family');
      expect(g.id, isNotEmpty);
      expect(g.colorIndex, 0);
      expect(g.tourId, 't1');
      expect(g.label, 'Patel family');
    });

    test('round-trips through toMap/fromMap', () {
      final g = PassengerGroup(
        id: 'g1', tourId: 't1', label: 'Surat group', colorIndex: 3,
      );
      final back = PassengerGroup.fromMap(g.toMap());
      expect(back.id, 'g1');
      expect(back.tourId, 't1');
      expect(back.label, 'Surat group');
      expect(back.colorIndex, 3);
    });

    test('toMap uses snake_case keys matching Postgres', () {
      final g = PassengerGroup(id: 'g1', tourId: 't1', label: 'x', colorIndex: 2);
      final m = g.toMap();
      expect(m.keys, containsAll(['id', 'tour_id', 'label', 'color_index', 'created_at']));
    });

    test('equality is by id', () {
      final a = PassengerGroup(id: 'g1', tourId: 't1', label: 'a');
      final b = PassengerGroup(id: 'g1', tourId: 't1', label: 'b');
      expect(a, equals(b));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/passenger_group_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../passenger_group.dart'`.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/models/passenger_group.dart
import 'package:uuid/uuid.dart';

/// A named group of passengers (separate bookings) that must ride the SAME bus.
///
/// Created by the agent. Seats from ONE booking are already a single unit (one
/// [Passenger] row); a [PassengerGroup] links DIFFERENT passenger rows
/// (e.g. "A & C") so the seating engine keeps them on one bus and a move can
/// cascade to the whole group.
class PassengerGroup {
  final String id;
  final String tourId;
  final String label;

  /// Index into the UI palette used to colour this group's ring on seat tiles.
  final int colorIndex;

  final DateTime createdAt;

  PassengerGroup({
    String? id,
    required this.tourId,
    required this.label,
    this.colorIndex = 0,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'label': label,
      'color_index': colorIndex,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory PassengerGroup.fromMap(Map<String, dynamic> map) {
    return PassengerGroup(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      label: (map['label'] ?? '').toString(),
      colorIndex: (map['color_index'] as num?)?.toInt() ?? 0,
      createdAt: _parseDate(map['created_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  PassengerGroup copyWith({String? label, int? colorIndex}) {
    return PassengerGroup(
      id: id,
      tourId: tourId,
      label: label ?? this.label,
      colorIndex: colorIndex ?? this.colorIndex,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PassengerGroup && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/passenger_group_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/models/passenger_group.dart test/models/passenger_group_test.dart
git commit -m "feat(model): add PassengerGroup (cross-booking same-bus link)"
```

---

## Task 5: `Passenger` — groupId, priorityStatus, priorityReason

**Files:**
- Modify: `lib/models/passenger.dart`
- Test: `test/models/passenger_priority_group_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/models/passenger_priority_group_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/priority_status.dart';

void main() {
  group('Passenger priority + group fields', () {
    test('defaults: no group, priority none, no reason', () {
      final p = Passenger(tourId: 't1', name: 'Suresh', phone: '9327148044');
      expect(p.groupId, isNull);
      expect(p.priorityStatus, PriorityStatus.none);
      expect(p.priorityReason, isNull);
      expect(p.isPriorityApproved, isFalse);
    });

    test('round-trips group + priority through toMap/fromMap', () {
      final p = Passenger(
        id: 'p1', tourId: 't1', name: 'Lila ben', phone: '9000000000',
        groupId: 'g1',
        priorityStatus: PriorityStatus.approved,
        priorityReason: 'elderly, needs front',
      );
      final m = p.toMap();
      expect(m['group_id'], 'g1');
      expect(m['priority_status'], 'approved');
      expect(m['priority_reason'], 'elderly, needs front');

      final back = Passenger.fromMap(m);
      expect(back.groupId, 'g1');
      expect(back.priorityStatus, PriorityStatus.approved);
      expect(back.priorityReason, 'elderly, needs front');
      expect(back.isPriorityApproved, isTrue);
    });

    test('fromMap tolerates missing columns (old rows)', () {
      final p = Passenger.fromMap({
        'id': 'p1', 'tour_id': 't1', 'name': 'x', 'phone': '9000000000',
      });
      expect(p.groupId, isNull);
      expect(p.priorityStatus, PriorityStatus.none);
      expect(p.priorityReason, isNull);
    });

    test('copyWith sets priorityStatus and groupId', () {
      final p = Passenger(tourId: 't1', name: 'x', phone: '9000000000');
      final c = p.copyWith(
        priorityStatus: PriorityStatus.requested,
        groupId: 'g9',
      );
      expect(c.priorityStatus, PriorityStatus.requested);
      expect(c.groupId, 'g9');
      expect(c.isPriorityPending, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/passenger_priority_group_test.dart`
Expected: FAIL — `groupId` / `priorityStatus` / `priorityReason` not defined.

- [ ] **Step 3: Write minimal implementation**

In `lib/models/passenger.dart`:

(a) Add the import after line 5 (`import 'seat_assignment.dart';`):

```dart
import 'priority_status.dart';
```

(b) Add three fields after the `tripType` field (after line 43):

```dart
  /// Cross-booking group this passenger belongs to (null = ungrouped).
  /// Members of the same group are kept on one bus by the seating engine.
  final String? groupId;

  /// Whether this passenger has an approved priority (front/sofa) need.
  /// Requested by the customer, approved by the agent.
  final PriorityStatus priorityStatus;

  /// Short reason for the priority request (e.g. "elderly, needs front").
  final String? priorityReason;
```

(c) Add constructor params (inside the constructor arg list, after `this.tripType = TripType.roundTrip,` on line 60):

```dart
    this.groupId,
    this.priorityStatus = PriorityStatus.none,
    this.priorityReason,
```

(d) Add convenience getters after `progressLabel` (after line 90):

```dart
  bool get isPriorityApproved => priorityStatus.isApproved;
  bool get isPriorityPending => priorityStatus.isPending;
```

(e) In `toMap()` add three entries before `'created_at'` (line 109):

```dart
      'group_id': groupId,
      'priority_status': priorityStatus.name,
      'priority_reason': priorityReason,
```

(f) In `Passenger.fromMap()` add three args before `createdAt:` (line 131):

```dart
      groupId: map['group_id'] as String?,
      priorityStatus: PriorityStatus.fromString(map['priority_status'] as String?),
      priorityReason: map['priority_reason'] as String?,
```

(g) In `copyWith()` add params (after `TripType? tripType,` on line 181):

```dart
    String? groupId,
    PriorityStatus? priorityStatus,
    String? priorityReason,
```

and add to the returned `Passenger(...)` (after `tripType: tripType ?? this.tripType,` on line 196):

```dart
      groupId: groupId ?? this.groupId,
      priorityStatus: priorityStatus ?? this.priorityStatus,
      priorityReason: priorityReason ?? this.priorityReason,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/passenger_priority_group_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full model suite to confirm no regressions**

Run: `flutter test test/models/`
Expected: PASS (all model tests green).

- [ ] **Step 6: Commit**

```bash
git add lib/models/passenger.dart test/models/passenger_priority_group_test.dart
git commit -m "feat(model): add groupId + priority request/approve fields to Passenger"
```

---

## Task 6: Migration + canonical schema

**Files:**
- Create: `supabase/migrations/006_seat_groups_priority.sql`
- Modify: `database.sql` (passengers section ~213–236)

> No automated test (SQL DDL). Verification = the migration applies cleanly in the Supabase SQL editor and the columns/table exist.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/006_seat_groups_priority.sql
-- ============================================================
-- 006  Passenger groups + priority seating
-- ------------------------------------------------------------
-- Adds cross-booking GROUPS (passengers that must ride the same bus) and a
-- PRIORITY (front/sofa) request->approve flow used by the seating engine.
--
--   passenger_groups          one named group per tour
--   passengers.group_id       links a passenger row into a group
--   passengers.priority_status / priority_reason
--
-- Reserved seats (per seat) and locked assignments (per berth) live inside the
-- existing buses.layout / passengers.assigned_seats jsonb and need no DDL.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

create table if not exists public.passenger_groups (
  id          uuid primary key default gen_random_uuid(),
  tour_id     uuid not null references public.tours(id) on delete cascade,
  label       text not null,
  color_index int  not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists passenger_groups_tour_idx
  on public.passenger_groups(tour_id);

alter table public.passengers
  add column if not exists group_id uuid
    references public.passenger_groups(id) on delete set null;

alter table public.passengers
  add column if not exists priority_status text not null default 'none';

alter table public.passengers
  add column if not exists priority_reason text;

create index if not exists passengers_group_idx
  on public.passengers(tour_id, group_id);

-- RLS: a group is owned through its parent tour (same shape as collections).
alter table public.passenger_groups enable row level security;

create policy "passenger_groups_owner_all" on public.passenger_groups
  for all to authenticated
  using (
    exists (
      select 1 from public.tours t
       where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.tours t
       where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()
    )
  );
```

- [ ] **Step 2: Mirror into `database.sql`**

In `database.sql`, inside the `create table public.passengers (...)` block, add three columns after the `note text,` line (line 226):

```sql
  group_id        uuid references public.passenger_groups(id) on delete set null,
  priority_status text not null default 'none',
  priority_reason text,
```

Immediately after the existing `passengers_user_idx` index (line 232), add:

```sql
create index passengers_group_idx on public.passengers(tour_id, group_id);
```

And add a new section BEFORE the `-- 5. passengers` section header (before line 208) so the table exists before `passengers.group_id` references it:

```sql
-- ============================================================
-- 4b. passenger_groups
--    Cross-booking groups that must ride the same bus.
--    Mirrors PassengerGroup.toMap() in lib/models/passenger_group.dart
-- ============================================================

create table public.passenger_groups (
  id          uuid primary key default gen_random_uuid(),
  tour_id     uuid not null references public.tours(id) on delete cascade,
  label       text not null,
  color_index int  not null default 0,
  created_at  timestamptz not null default now()
);

create index passenger_groups_tour_idx on public.passenger_groups(tour_id);

alter table public.passenger_groups enable row level security;
create policy "passenger_groups_owner_all" on public.passenger_groups
  for all to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                       where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()));
```

- [ ] **Step 3: Verify the SQL parses (lightweight)**

Run: `grep -n "passenger_groups" database.sql supabase/migrations/006_seat_groups_priority.sql`
Expected: matches in both files (table create + references). (No live DB in CI; apply in Supabase editor before release.)

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/006_seat_groups_priority.sql database.sql
git commit -m "feat(db): migration 006 — passenger_groups + priority columns"
```

---

## Self-Review

**Spec coverage (vs §4 of the design spec):**
- §4.1 Groups → Task 4 (`PassengerGroup`) + Task 5 (`Passenger.groupId`) + Task 6 (table + column + index). ✓
- §4.2 Priority → Task 1 (`PriorityStatus`) + Task 5 (`priorityStatus`/`priorityReason`) + Task 6 (columns). ✓
- §4.3 Reserved (`SeatCell.reserved`) → Task 3. Locked (`SeatAssignment.locked`) → Task 2. ✓ (jsonb-internal, no DDL — matches spec.)
- §4.4 Migration + model updates → Task 6 + Tasks 1–5. ✓
- Capture UI (agent tagging / approval queue) is intentionally **NOT** in Phase 1 — it overlaps the customer-form brief and lands in a later phase. Noted in spec §9.

**Placeholder scan:** No TBD/TODO; every code step has complete code; every run step has an exact command + expected result. ✓

**Type consistency:** `PriorityStatus.fromString`/`.name` used identically in Task 1 and Task 5. `SeatAssignment.copyWith({bool? locked})` defined in Task 2, used nowhere else yet. `SeatCell.copyWith({..., bool? reserved, ...})` consistent. snake_case Postgres keys (`group_id`, `priority_status`, `priority_reason`, `color_index`) match between Dart `toMap` (Tasks 4–5) and SQL (Task 6). ✓

**Correctness guards:** equality/hashCode left unchanged for both `SeatAssignment` (busId,seatId) and `SeatCell` (row,col,position); booleans omitted-when-false in jsonb. ✓
