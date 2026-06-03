# Ugam Booking — Application & Technical Brief
### For a design/theme agent. Contains NO color/theme decisions — that is your deliverable.

---

## 0. Your task (read first)

Design a complete **visual theme / design system** for this app. This document tells you
**what the app is** and **how it is built and structured**, so your theme fits the real
surfaces and constraints. It deliberately contains **no palette, no hex values, no
"mood"** — those are *your* output.

Your deliverable is defined precisely in **§9 — Token Contract**: fill every slot of
`UgamColorSet` for **dark (primary)** and **light (mirror)**, plus the `Brand` seed
colors, with rationale. The whole app re-skins from that one file.

---

## 1. What the app is

A mobile app for booking seats on **community yatra (pilgrimage) bus trips**. A tour
**agent** plans a trip, collects seat requests from community members over WhatsApp,
adds buses, assigns every passenger to a physical berth, then locks and runs the trip.
Community **customers** browse upcoming tours and submit their own seat requests in-app.

Two audiences, one codebase:
- **Admin / agent** (primary) — does fast, repetitive operational work: triaging
  requests, assigning seats on a bus grid, sending WhatsApp updates. Often on a phone,
  outdoors, in variable light → **dark mode is the primary, default experience.**
- **Customer** (secondary) — a community member browsing tours and requesting seats.

---

## 2. Brand context (input, not instructions)

- Brand: **Ugam Foj / DEVAM — Bhedapipaliya Dham** (`devam.org`). A **devotional
  Gujarati** community brand — it must read as warm, rooted, and trustworthy, **not as
  generic SaaS or fintech.**
- Name meaning: **"ઉગમ" = rising / dawn.** The logo is a **rising-sun + the Gujarati
  word ઉગમ + a side-view yatra bus** (sun rising behind the bus on the horizon).
- This is *context to inform your palette* — the specific colors are your call. (A prior
  attempt at a gold scheme was rejected; you are free to choose the direction. Concrete
  reference apps are welcome; avoid vague abstract "moods.")

---

## 3. Platforms & form factor

- **Flutter**, shipping **iOS + Android**.
- **Portrait only** (orientation locked). Phone-first; on wide screens content is capped
  and centered (no true tablet/desktop layout).
- **Material 3** under the hood, but the app renders almost entirely from a **custom
  design system** (see §9), not stock Material widgets.
- **Dark is the primary mode; light is a full mirror, not a fallback.** Both must be
  first-class.

---

## 4. Tech stack

| Concern | Choice |
|---|---|
| Framework | Flutter (Dart) |
| State / DI / routing | **GetX** (`get`) — `Get.find`, `Get.to`, `GetPage` routes |
| Backend | **Supabase** — Postgres, Realtime, Auth (refresh tokens in secure storage) |
| Offline | **sqflite** local DB, offline-first, `sync_service` + `connectivity_plus` |
| i18n | **easy_localization** — **Gujarati (default)**, English, Hindi |
| Type | **Inter** (bundled variable TTF; no runtime font fetch) |
| Misc | `url_launcher` (WhatsApp deep-link handoff), `flutter_contacts`, `crypto` (admin password hashing), `shared_preferences` (theme/locale) |

---

## 5. Architecture / folder structure (`lib/`)

```
models/        Domain types + enums (see §6)
controllers/   GetX controllers: auth, locale, theme, tour, user
services/      supabase, realtime, sync, offline_database, whatsapp,
               admin_auth, user, contact_sync, customer_requests_store
screens/       All full-page screens (see §8)
components/    App-level composite widgets (tour_card, tour_status_badge, …)
widgets/       Bottom sheets (edit_request, language_picker, customer_seat_layout)
design/        ← THE DESIGN SYSTEM you will theme (see §9)
  tokens.dart        colors + radius + spacing + motion (SINGLE SOURCE)
  text_styles.dart   typography scale (Inter)
  theme.dart         builds Material ThemeData from tokens
  components/         ugam_* reusable UI primitives
routes/        GetX route table
config/        supabase_config, i18n_config
content/       static legal/help copy
utils/         formatters, validators, responsive, snackbar, constants
```

---

## 6. Domain model (what the UI must represent)

- **Tour** — a trip. Has a **status lifecycle** that drives a lot of UI state:
  `planning → collecting → busBooked → assigning → locked → completed`.
  Each status has a display name, an accent role, and gates (e.g. seat layout is only
  editable in some states). A **phase indicator** visualizes this.
- **Bus** — belongs to a tour. Holds a **`BusLayout`**: two **decks** (lower + upper),
  each a grid of **seat cells**. Seat types: **Single Sofa** (1 berth), **Double Sofa**
  (**2 berths** — physically seats two people), **Seater**. Capacity is counted in
  **berths**, not tiles.
- **Passenger** — a person on a tour. Has **request lines** (e.g. "Double Sofa ×1 +
  Single Sofa ×1"), **assigned seats** (berth-level), **age group** (child/adult/senior),
  **payment status**, **trip type** (one-way/round), and flags: **waitlisted**,
  **handler**, **ladies** (an "attention" highlight role). Shows `assigned/requested`.
- **Request** — a customer-submitted seat request that an agent triages
  (new / waitlist / assigned).
- **Users** — **Admin** (agent, password-hashed) and **Customer** (community member).

State surfaces the theme must style: **status badges, progress/assigned counters,
waitlist/ladies/handler highlights, seat-occupancy states** (free / held / paired-double /
selected / blocked).

---

## 7. Information architecture & navigation

**Admin app — 5-tab bottom dock** (`main_shell`):
1. **Home** (dashboard / overview)  — `Icons.home_rounded`
2. **Tours** (list + detail + create/edit)  — `Icons.location_on_rounded`
3. **Requests** (triage incoming seat requests)  — `Icons.chat_bubble_rounded`
4. **Assign** (seat-grid assignment)  — `Icons.grid_view_rounded`
5. **Notify** (compose WhatsApp updates)  — `Icons.notifications_rounded`

**Customer flow** (separate routes, not the dock): tour list → tour detail → booking
request → my requests → more.

**Entry / auth:** splash → login → (admin-setup | admin home | customer home).

---

## 8. Screen inventory (surfaces to design)

**Admin**
- `splash`, `login`, `admin_setup`
- `dashboard` (home / stats)
- `tours` (list), `tour_detail`, `create_tour`, `edit_tour`
- `requests` (triage list with per-request action rows)
- `manage_buses`, `add_bus` (3-step capacity wizard), `bus_status` (read-only seat grid)
- `seat_assignment` (overview across buses) + `tour_seat_assignment` (the working
  assignment editor — drag/drop berths, the densest screen in the app)
- `notify` (WhatsApp message composer), `settings`

**Customer**
- `customer_tour_list`, `customer_tour_detail`, `customer_booking_request`,
  `customer_my_requests`, `customer_more`

**Sheets / dialogs**
- `edit_request_sheet`, `language_picker_sheet`, `customer_seat_layout_sheet`

---

## 9. Token Contract — YOUR DELIVERABLE

The entire app's color comes from **one file, `lib/design/tokens.dart`**. The flow is:

```
Brand seed colors  →  UgamColorSet (dark + light)  →  Material theme + every ugam_* component
```

Re-theming the whole app = editing this one file. **No component code references raw
colors** — they all read `UgamColors.of(context)`. So your job is to define the values
below. **Fill each slot for BOTH `dark` (primary) and `light` (mirror).**

### `UgamColorSet` slots (semantic roles — give a color to each)

| Token | Role |
|---|---|
| `bg` | App scaffold background |
| `card` | Default surface / tile |
| `cardElev` | Elevated surface (chips, inputs, stepper) |
| `border` | Hairline / divider |
| `ink` | Primary text |
| `ink2` | Secondary text |
| `ink3` | Tertiary / meta text |
| `accent` | **Brand + primary CTA** color |
| `accentFill` | Faint accent wash (behind accent icons/chips) |
| `good` / `goodFill` | Success / confirmed / paid |
| `warm` / `warmFill` | **Attention** — ladies / waitlist flags (must be distinct from `accent`) |
| `danger` | Destructive / error |
| `onAccent` | Text & icons that sit **on** `accent` (must stay legible) |

> If your design needs gradient CTAs, glows, or extra elevation tones, you may **propose
> adding slots** (e.g. `accentGradTop/Bottom`) — just say so; adding a field touches the
> struct + both color sets + the CTA component, which is a known, contained change.

### Already defined — stable, change only with reason
- **Type scale** (`text_styles.dart`): Inter; `display 32 / titleXl 26 / titleL 22 /
  titleM 18 / titleS 15 / body 14 / caption 12 / micro 10`, plus tabular-figure numeric
  styles for prices, seat counts, IDs.
- **Radius** (`UgamRadius`): card 22, photo 16, input 14, chip/pill 999, sheet 28,
  stat 18, row 16, seat 8.
- **Spacing** (`UgamSpacing`): xs 4 / sm 8 / md 12 / gutter 14 / lg 16 / xl 20 /
  xxl 24 / huge 32…56.
- **Motion** (`UgamMotion`): tapIn 120 / tapOut 180 / tab 200 / sheet 280; easeOutCubic.

### Components that will inherit your theme (`design/components/ugam_*`)
`ugam_cta` (sticky pill button), `ugam_card`, `ugam_stat_tile`, `ugam_tab_pills`,
`ugam_dock_nav` (5-tab bottom bar), `ugam_request_row`, `ugam_seat_grid` (seat tiles),
`ugam_route_header`, `ugam_date_pill`, `ugam_input`, `ugam_sheet`, `ugam_snackbar`,
`ugam_empty`, `ugam_skeleton` (loading), `ugam_status_dot`, `ugam_glass_container`,
`ugam_bus_backdrop` (decorative tour-tile gradient). Plus `tour_status_badge`,
`tour_card`, `phase_indicator`.

---

## 10. Constraints & things the theme must respect

1. **Gujarati-first.** Default locale is Gujarati; English & Hindi also ship. Script
   needs good legibility at all sizes; layouts must tolerate longer translated strings.
2. **Dark-first, light-mirror.** Dark is where the agent lives. Light must be equally
   finished.
3. **High information density on the work screens** (requests triage, seat assignment).
   The agent does fast repetitive actions — scannability, clear tap targets, and crisp
   surface separation matter more than decoration.
4. **Seat-grid states** need to be visually unambiguous: free / occupied / paired-double /
   selected / blocked, on both decks.
5. **Offline-first** → loading (skeleton), empty, and error states are real screens, not
   afterthoughts. Theme them.
6. **Numbers line up** — prices, seat counts and IDs use tabular figures; don't fight it.
7. **Logo + app icon** already exist (rising-sun + ઉગમ + yatra bus). The launcher uses an
   adaptive icon with a background color — your palette should pick a background that
   flatters the mark.
8. **Status semantics**: `accent` (brand/primary), `good` (success), `warm` (attention/
   ladies — keep clearly distinct from accent), `danger` (destructive). Don't collapse
   these into one hue.

---

## 11. Out of scope for this brief
- All color/hex/palette decisions — **that's your output.**
- Typography family and the spacing/radius/motion scales are set (propose changes only
  with rationale).

## 12. Please return
- A filled `UgamColorSet` for **dark** and **light**, plus any `Brand` seed constants.
- Short rationale per key decision (especially `accent`, `bg`, `card`, `onAccent`, and the
  `accent` vs `warm` distinction).
- Any proposed new token slots, elevation/shadow guidance, or CTA treatment.
- (Optional) 1–2 concrete reference apps your direction draws from.
```
