# Ugam Booking — Agent-Workflow Realignment

**Date:** 2026-05-06
**Status:** Approved design — ready for implementation planning
**Supersedes (in part):** `2026-05-02-ugam-booking-rebrand-design.md` for the data model and the Bus / Requests / Seat-Assignment screens.

## 1. Why this exists

The app currently doesn't match the agent's real workflow:

- A tour can only hold one bus (`Tour.busDetails`), but the agent regularly books two or more buses per tour.
- A passenger can only request one seat type at a time (`Passenger.seatPreference`), but customers ask for mixed lines like "1 double lower + 1 single upper + 2 seater" in a single message.
- There is a standalone Bus inventory (`bus_list_screen`, `add_bus_form_screen`, `Bus` model) — but the agent doesn't own buses; they are coordinated per-tour with bus owners.
- The customer-side request form opens WhatsApp without writing to the DB, so the agent's Requests screen has nothing to read.
- Seat assignment, Requests, theme handling, and tour-creation entry points are partially built or wired wrong.

This document is the design contract for re-aligning the data model, primary screens, and end-to-end flow with the actual workflow. The implementation plan that follows will sequence the work into shippable phases.

## 2. The agent's real workflow (canonical)

1. **Plan** — agent decides route, date, price per seat. Creates a tour.
2. **Advertise** — agent broadcasts to WhatsApp groups (manual; out of scope for this spec).
3. **Collect requests** — customers open the app, browse public tours, fill the request form (name, phone, seat lines), submit. App writes a Passenger record and hands off to WhatsApp with a pre-filled message addressed to the agent. The DB is the source of truth; WhatsApp is a courtesy notification.
4. **Tally and book buses** — agent watches the running tally on the Requests screen. When demand is clear, contacts bus owner(s), books one or more buses.
5. **Add bus details** — for each bus the owner provided, agent enters details (number, driver, AC, layout) using the visual seat-grid editor.
6. **Assign seats** — agent uses the seat assignment screen to place each passenger's seat-line requests onto specific seats across the buses, manually choosing which bus each passenger goes on.
7. **Pick handler** — agent marks one passenger as the trip handler (on-trip coordinator).
8. **Lock and notify** — agent locks the tour. Notifications go out (initially: WhatsApp deep-link per passenger with their seat IDs and bus details; future: WhatsApp Business API).

## 3. Data model

### 3.1 Tour

```
Tour {
  id
  title, fromCity, toCity, departureDate, returnDate?, pricePerSeat, description?
  status: TourStatus    // see 3.5
  handlerId?            // FK → Passenger.id
  createdBy             // admin phone
  isPublic              // surfaced in customer-mode list
  createdAt, updatedAt
}
```

**Removed:** `busDetails` field. A tour now relates to many `Bus` records via `Bus.tourId`.

### 3.2 Bus

```
Bus {
  id
  tourId                // FK → Tour.id
  name                  // "Bus 1", "Bus 2", … (auto-generated, editable)
  busNumber             // GJ05HU7162
  driverName, driverPhone
  acType                // AC | NonAC
  layout                // see 3.3
  createdAt, updatedAt
}
```

**Bus is no longer a global inventory.** It exists only as a child of a Tour. The previous standalone `Bus` model and screens are deleted.

### 3.3 Bus layout

Each bus has two decks: `lowerDeck` and `upperDeck`. Each deck is a 2D grid of cells:

```
BusLayout {
  rows, cols                                  // grid dimensions chosen by agent
  lowerDeck: List<List<Cell>>                 // rows × cols
  upperDeck: List<List<Cell>>                 // rows × cols (may be all empty for non-sleeper)
}

Cell = Empty | Seat
Seat {
  id              // auto-generated, e.g. "DL3", "SU1", "S2"
  type            // SingleSofa | DoubleSofa | Seater
  position        // Upper | Lower | null  (null only for Seater)
}
```

**Seat ID generation rules**

- IDs assigned in row-major order (left→right, top→bottom) within each deck.
- Prefix encodes type + position: `SU` Single Upper, `SL` Single Lower, `DU` Double Upper, `DL` Double Lower, `S` Seater (Seater has no position prefix).
- `Seater` cells are valid only on the `lowerDeck`. Placing a Seater on the upper deck is a validation error.
- Layout edit lock is **per-bus**, not per-tour: a bus's layout can be edited as long as none of its seats are currently assigned (see 4.4 for the full rule). This lets the agent keep adding/refining buses even while assigning seats on others.

### 3.4 Passenger

```
Passenger {
  id
  tourId                          // FK → Tour.id
  userId?                         // FK → customer-app user (null if no account)
  name, phone, ageGroup
  requestLines: List<RequestLine> // see below
  assignedSeats: List<Assignment> // see below
  paymentStatus
  isHandler                       // mirrors Tour.handlerId for convenience
  createdAt
}

RequestLine { seatType, position?, qty }
  // e.g. (DoubleSofa, Lower, 1), (SingleSofa, Upper, 1), (Seater, null, 2)

Assignment { busId, seatId }
  // e.g. (bus_1_id, "DL3")
```

**Idempotency:** the natural key is `(tourId, phone)`. A customer resubmitting from the app updates their existing record — no duplicates.

**Removed:** `Passenger.seatPreference` (single value), replaced by `requestLines`. `Passenger.assignedSeats: List<String>` is replaced by `List<Assignment>` so each assignment knows which bus it belongs to.

### 3.5 Tour status state machine

```
planning  → collecting  → busBooked  → assigning  → locked  → completed
```

| Transition | Trigger |
|---|---|
| `planning → collecting` | First Passenger record arrives for this tour (auto). |
| `collecting → busBooked` | Agent adds the first Bus to this tour (auto). |
| `busBooked → assigning` | Agent taps "Continue assigning seats" on Requests screen (manual). Note: agent can keep adding more buses while in `assigning`; the bus layout editor stays open until tour is locked. |
| `assigning → locked` | Agent taps "Lock tour" — only enabled when all passengers' requestLines are fully assigned **and** a handler is picked (manual). |
| `locked → completed` | Agent taps "Mark completed" after the trip (manual). |

Layout edits are allowed in `planning`, `collecting`, `busBooked`, and `assigning`, but only for buses with no current assignments. Any bus with assignments locks its layout until those assignments are cleared.

## 4. Screens

### 4.1 Tours list (existing, fixed)

- Reactive list bound to the Tour collection (fixes "My Tours not in sync"): when a new tour is created, the list refreshes automatically without manual reload.
- Visual style aligned with the rest of the app — same theme, same card style as Dashboard's tour list. Removes the "feels different" inconsistency.
- Adds a `+` FAB → `CreateTourScreen` (fixes the "can only create from home" issue).

### 4.2 Tour detail

For each tour, the agent has tabs:

1. **Overview** — title, route, dates, price, status badge, handler info.
2. **Requests** — see 4.3.
3. **Buses** — list of attached buses, each with summary (driver, capacity, fill %); `+ Add bus` button opens 4.4.
4. **Assignment** — see 4.5.
5. **Notify** — see 4.6.

Tabs gate by status: e.g. Assignment is read-only until at least one Bus is added; Notify is enabled only when status is `locked`.

### 4.3 Requests screen

The agent's view of incoming app submissions during the collection window.

**Layout**

- **Tally bar** (top, large, color-coded): seat-type breakdown across all current Passengers. Example:
  > 42 Double Lower • 18 Double Upper • 12 Single Lower • 8 Single Upper • 6 Seater
  > 86 seats across 35 passengers
  Tapping a chip filters the list below.
- **Passenger list** (middle, newest-first): each row shows name, phone, time-since-submitted, seat-line summary as chips, age-group badge if not "adult". Tap row → passenger detail (editable). Swipe-left or kebab menu: Edit, Delete, Mark as Handler.
- **Sticky action bar** (bottom):
  - "Add buses for this tour" (visible once tally has ≥1 seat) → opens bus add flow.
  - Once any bus is added, button changes to "Continue assigning seats" → opens 4.5 and advances status to `assigning`.

**Deliberately not present:** manual `+ Add Request` entry, WhatsApp message paste/parser, source filter. All requests come from the customer app.

### 4.4 Bus add / layout editor

Two-step flow.

**Step 1 — Basics form**

- Bus name (default `"Bus N"` where N is the next sequence number for the tour, editable)
- Bus number (e.g. `GJ05HU7162`)
- Driver name, driver phone
- AC type: AC / Non-AC
- Layout dimensions: rows × cols

**Step 2 — Visual layout editor**

- Two tabs: **Lower Deck** and **Upper Deck**.
- Each tab shows a grid sized to rows × cols.
- Tap a cell to cycle through states:
  - On Lower Deck: `Empty → Single Sofa → Double Sofa → Seater → Empty`
  - On Upper Deck: `Empty → Single Sofa → Double Sofa → Empty` (no Seater on upper)
- Each placed seat shows its auto-generated ID inside the cell; IDs renumber if seats are added/removed before save.
- Save button persists the bus to the tour.

The same grid view, read-only, is reused on the Seat Assignment screen so the agent learns one mental model.

**Edit constraints**

- A bus's layout can be edited as long as it has no active seat assignments.
- If any of its seats are assigned to a passenger, layout edits are blocked with a message: "Clear seat assignments for this bus before editing layout." Editing basics (driver, AC, etc.) is always allowed.

### 4.5 Seat assignment screen

Two-pane (tablet) / stacked (phone) layout.

**Left pane — Passenger list**

- Grouped collapsible sections: Unassigned (N) / Partially (N) / Done (N).
- Each row: name, phone, request summary (e.g. `1 DL + 1 SU + 2 S`), progress chip (e.g. `2/4` or `✓ 4/4`).
- Tap a passenger → selects them; right pane updates.

**Right pane — Seat grid**

- Bus selector tabs at top: `Bus 1 (24/30)` `Bus 2 (15/40)` — fill ratio.
- Deck tabs below: `Lower` / `Upper`.
- Grid (read-only layout from 4.4), but cells now show assignment state:
  - Empty (aisle/door): muted, no interaction.
  - Available: colored by type, seat ID inside, tappable.
  - Assigned to selected passenger: bold border + ✓ marker.
  - Assigned to someone else: gray with the other passenger's first name; tap → small popup with their full info and a "Reassign to current passenger" button (with confirm).
- Above the grid: pending request lines for the selected passenger as chips with progress (`Double Lower 0/1`, `Single Upper 0/1`, `Seater 0/2`).

**Interaction rules**

- Tap an available seat → if its `(type, position)` matches a pending request line with remaining qty, assign it. Chip ticks down; passenger progress updates.
- Tap an own assigned seat → unassign. Frees the cell.
- Tap a non-matching available seat → toast: *"Passenger didn't request a Double Upper. Edit their request first."* Agent can edit request lines from the passenger detail (back-link in the same screen).

**Top bar utilities**

- "Auto-pick next" button → when the current passenger is fully assigned, jumps focus to the next unassigned passenger.
- "Lock tour" button → enabled only when 100% of all passengers' request lines are assigned AND a handler is picked. Confirms then advances status to `locked`.

### 4.6 Notify screen

Out of scope to redesign in this document. Initial v1 keeps the existing WhatsApp deep-link per-passenger pattern, but updates the message template to include each passenger's bus and seat IDs.

## 5. Customer-mode request flow (rebuilt)

`customer_booking_request_screen.dart` is rewritten.

**Form**

- Name (required)
- Phone (required, pre-filled if logged in)
- Age group (optional, default Adult)
- Seat-line steppers (one per type/position):
  - Double Sofa Lower
  - Double Sofa Upper
  - Single Sofa Lower
  - Single Sofa Upper
  - Seater
- Note (optional)

**Submit ("Confirm & open WhatsApp")**

In order:

1. **DB write** — create or update a Passenger record under the tour (idempotency key: `(tourId, phone)`). On failure, show error and abort.
2. **Status side-effect** — if this is the first request on the tour, advance tour status `planning → collecting`.
3. **WhatsApp deep-link** — open WA addressed to the agent's number (currently sourced from `tour.createdBy`; in 6.4 we expose this as a Settings field) with a pre-filled message in the customer's voice. Example:

   > Hi, mare 1 Double Lower, 1 Single Upper joie che for *Manali Tour 12 Jun*. — Ramesh

If the customer never sends the WA message, no data is lost — DB is already updated. The WA send is courtesy-only.

**Resubmission** — opening the form again as the same phone pre-fills previous values; submit updates the existing record and re-sends a fresh WA message.

## 6. Loose-ends fixes

### 6.1 Tour creation entry points

Add a `+` FAB to `tours_screen.dart` that pushes `CreateTourScreen`. Same handler as the dashboard entry.

### 6.2 Theme propagation bug

`app.dart:22` hardcodes `themeMode: ThemeMode.system`. The `ThemeController` calls `Get.changeThemeMode()` (controllers/theme_controller.dart:17), but `MaterialApp` is not bound to the controller, so theme changes only "stick" on screens that read `themeCtrl.isDarkMode.value` directly — currently only `tours_screen.dart:43`.

Fix: wrap `GetMaterialApp` in `Obx`, bind `themeMode` to `themeCtrl.isDarkMode.value ? ThemeMode.dark : ThemeMode.light`. Theme toggle then propagates everywhere.

Consolidate the theme-toggle UI into Settings (single source).

### 6.3 My Tours list sync + visual alignment

- Bind the Tours list to the reactive `TourController` collection so creating a new tour refreshes the list automatically (no manual reload).
- Visually align the My Tours card style with the Dashboard tour list — same theme, same card.

### 6.4 Settings additions

Add a Settings field: **Agent WhatsApp number** — used as the deep-link target for customer submissions. Defaults to the admin's login phone (`tour.createdBy`); editable.

### 6.5 Code deletion

- Delete `lib/screens/bus_list_screen.dart`.
- Delete `lib/screens/add_bus_form_screen.dart`.
- Delete the standalone global `Bus` collection / repository code.
- Delete `Tour.busDetails` field, `BusDetails` model.
- Delete `Passenger.seatPreference` field.
- Migrate any references in routes, controllers, and main_shell.

## 7. Out of scope (tracked for later)

- Bus owner contacts list (deferred per Question 8 / Option C).
- Bus layout templates / saved layouts per bus number.
- WhatsApp Business API integration.
- Seat-type substitution flow ("ran out of lower, give them upper") — currently handled by editing the passenger's request line manually.
- Reactive layout edit while assignments exist (with auto-reflow). Current rule: clear assignments first.

## 8. Risks and tradeoffs

- **Visual seat-grid editor is the heaviest piece of UI work** in the project (estimated 3-5 days alone). Selected over simpler alternatives because the agent needs visual context at assignment time to keep families adjacent.
- **Customer phone is the natural key.** A typo creates a duplicate Passenger record under a different phone. Mitigated by old customers not typo'ing their own number and by edit/delete affordances on the Passenger detail.
- **No moderation step on customer-app submissions.** Trusted customer base assumption. If spam emerges, add phone verification or a manual approve toggle later.
- **One spec covering data model + 4 screens + customer flow is broad.** The implementation plan must phase the work to keep each shippable slice small. Suggested ordering: data model migration → bus add + layout editor → seat assignment → requests screen rebuild → customer flow rewrite → loose-ends fixes. Each phase deletable/revertible independently.

## 9. Implementation phasing (preview, refined in plan)

Suggested phases for the implementation plan:

1. **Schema migration + standalone-bus deletion** — safe foundation; no UI changes visible to user yet beyond the deleted screens.
2. **Bus add flow + visual layout editor** — first piece of net-new UI.
3. **Seat assignment screen rebuild** — depends on (2) for the read-only grid.
4. **Requests screen rebuild + tour-status auto-transitions** — independent of (3); could parallelize if needed.
5. **Customer flow rewrite (DB write + WA handoff)** — touches customer-mode only.
6. **Loose ends** — theme fix, FAB, settings field, my-tours sync.

The plan document will firm up dependencies, file lists per phase, and verification criteria.
