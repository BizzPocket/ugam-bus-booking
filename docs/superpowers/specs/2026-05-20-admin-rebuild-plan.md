# Admin Rebuild Plan — honest audit

**Date:** 2026-05-20
**Status:** Draft for user review — no code until validated

---

## Why this exists

I've shipped 14 commits but the user's feedback is "still patch work, not proper UI". They're right. I've been swapping colours, wrapping things in `UgamCard`, replacing buttons with `UgamCTA` — but the **layouts** of most admin screens are still essentially the original Flutter scaffold-and-list with new paint. That's why it doesn't feel like a designed product.

This document does an honest audit of each admin screen, names what's wrong, and proposes a real rebuild. **No code until the direction is approved.**

---

## Workflow context (what an admin actually does)

A booking agent's day, in order:

1. **Wake up** → open app → see today's trips, urgent passengers, money status
2. **Create a tour** → set route + date + price → broadcast on WhatsApp
3. **Collect requests** → passengers DM via WhatsApp or fill the customer form
4. **Tally requests** → see total seats needed → call bus owner → book a bus
5. **Add bus details** → number, driver, AC, layout
6. **Assign seats** → drag passengers onto seats, handle paired-double rules
7. **Lock tour** → freeze assignments
8. **Notify passengers** → send WhatsApp with bus number + seat number + handler info

The app's screens have to flow with this. Every screen should answer: *what does the agent want to do RIGHT NOW?*

---

## Navigation (main_shell)

**Today:** 5-tab dock — Home / Tours / Requests / Assign / Notify

**Keep as 5.** Each tab maps to a distinct agent action. Don't restructure. Just make each tab's content feel purposeful.

---

## Screen 1 — Dashboard (Home tab)

**Today:** Greeting + 2×2 stat tiles (Active / Pending / Passengers / Revenue) + "Upcoming tours" list with see-all.

**Pain:**
- Reads as "a phone app dashboard" not a control center
- Stat tiles are 4 equal-weight squares — no hierarchy, no story
- Tour cards have hero photos but they're the same as Customer side — not designed for an admin scanning their workload
- No sense of *urgency* or *what to do next*
- Quick actions live on the tour cards as faint pill buttons — easy to miss

**Should be — an actual control center:**

```
[Status bar]
[Top row: Hello, [name] · today's date pill]
[Hero "TODAY" card if a tour departs today/tomorrow, else "All quiet" tile]
  - Big title: "Saputara Weekend departs in 14h"
  - Departure time + bus number + assigned/total
  - 2 CTAs: View tour · Open WhatsApp broadcast
[Quick action row: 4 chunky circle buttons
  Create tour | Add bus | Lock tour | Profile]
[Stats: ONE big metric on top (this week's revenue, BIG number)
  + 3 small below (active tours, today's seats, waitlist count)]
[Section "Needs attention" — tours with action items
  - Each row: tour title + what's blocking + one-tap fix
    "Saputara Weekend → 5 unassigned seats → Assign"
    "Diu Beach Run → no bus yet → Add bus"
    "Statue of Unity → ready to lock → Lock & notify"]
[Recent requests preview — last 3-5 new passengers]
```

The dashboard's job: tell the agent what to do this hour. Not just show numbers.

---

## Screen 2 — Tours (Tours tab)

**Today:** Title + 4 filter pills (Active / Collecting / Locked / Completed) + flat list of tour rows with 84px photo + meta.

**Pain:**
- All tours rendered equally — no sense of timeline (which trips are this week vs in 2 months?)
- Filter pills are the only structure — agents typically think in time, not status
- Each row is identical regardless of how urgent the tour is

**Should be:**

```
[Top row: title "Tours" + circle "+" + search icon]
[Optional search bar appears on tap]
[Time-grouped sections:
  - "This week" (chronological, departing soonest first)
  - "Next 30 days"
  - "Later"
  - "Past" (collapsed by default, expand on tap)]
[Each section header: name + count chip]
[Each tour row:
  - 96px square photo on left with date badge overlay
  - title + route on top
  - status dot + booked/capacity on right
  - if action needed: full-width accent chip below ("Add bus" / "Assign 5 seats" / "Lock & notify")
  - if locked or completed: greyed slightly, no action chip]
[Sticky bottom: dock nav (main_shell handles it)]
[Search and create live in header, not as floating buttons]
```

Filter chips become a sheet (tap a filter icon) for power users; default view is time-grouped.

---

## Screen 3 — Tour Detail

**Today:** Hero photo + overlay summary + 3 stat tiles + info card + bus list + sticky edit/assign action.

**Pain:**
- Single long scroll — passengers, buses, info all mixed
- The agent often wants to JUST see passengers, or JUST see buses
- No timeline / activity feed
- No clear "what's the next thing to do" surface

**Should be — a tour workspace with tabs:**

```
[Hero photo 320px - full bleed]
[Top: floating back + status pill + edit circle]
[Overlay card at hero bottom:
  - Title (big)
  - Route + duration
  - Status: dot + label
  - Price chip]
[Tab pills: Overview · Passengers · Buses · Activity]

# Overview tab
[Next-action card — big colored CTA telling agent what to do
  "Add a bus to start assigning seats" → button]
[Stats: 2x2 — Requests / Assigned / Available / Revenue]
[Mini WhatsApp box — "Broadcast this tour" button]

# Passengers tab
[Filter pills: All / New / Waitlist / Assigned]
[List of passenger rows, same dense pattern as Requests screen]

# Buses tab
[Bus cards — same photo-anchored pattern as manage_buses]
[Add bus CTA at bottom]

# Activity tab
[Timeline:
  - Created · 3 days ago
  - First request · 2 days ago (Ramesh)
  - Bus added · 1 day ago
  - 14 seats assigned · 4h ago
  - Status changes, lock events, etc.]

[Sticky bottom action: contextual to the tab
  Overview → primary action
  Passengers → "Open seat assignment"
  Buses → "Add bus"
  Activity → "Export"]
```

This makes a tour a real workspace, not a long scroll.

---

## Screen 4 — Requests (tab)

**Today:** Tour selector pills + filter pills (New/Waitlist/Assigned) + passenger cards with chips + sticky "+" to add.

**Pain:**
- Decent but every card is the same density
- No way to bulk-select for bulk actions (move 3 to waitlist, etc.)
- "Add request" is a sheet — good — but the flow could be guided better
- Search is missing

**Should be:**

```
[Title + circle "+" + search icon]
[Optional search bar]
[Tour selector: horizontal pill row (active = solid accent)]
[Stats strip below: New | Waitlist | Assigned (each shows count in big)]
[Filter pills: same 3 segments]
[Passenger list — keep current dense card pattern]
[Long-press a row → enters selection mode (checkmarks appear) → bulk action bar slides up from bottom]
[Sticky bottom: "Open seat assignment for this tour →" with remaining unassigned count]
```

Add bulk actions and a search bar. Keep the rest.

---

## Screen 5 — Seat Assignment (tab, in-shell)

**Today:** Tour picker + bus picker + deck toggle + the seat chart with drag-drop occupant names.

**Pain:**
- This is the heaviest, most important admin screen — and I just polished the header
- The seat chart fills the screen but there's NO bottom dock showing who's still waiting for a seat
- Drag-drop UX exists but discovery is poor — agents have to know to long-press
- No "Auto-pick next" or "Suggest assignment" — every seat is manual

**Should be:**

```
[Top: tour title + bus selector pill row]
[Deck toggle if upper deck exists]
[BIG seat grid — the focal point, fills most of screen]
[Bottom dock pinned above the main_shell dock:
  - Horizontal scroll of "Pending passengers" cards
    Each card: avatar + name + "needs 2 × DS" + tap to highlight matching seats
  - Right side: Auto-assign button + Done button]
[On tap of pending card: matching seats pulse with accent glow]
[On long-press of an assigned seat: drag handle appears + can drop on target]
```

The bottom pending dock is the key missing piece — turns this from a static chart into a real "match passengers to seats" workspace.

---

## Screen 6 — Notify (tab)

**Today:** Tour selector + summary card + lock gate (if not locked) OR person-wise carousel + lock CTA at bottom.

**Pain:**
- Lock gate is fine
- Carousel is unique but feels old
- No progress sense (X of Y notified)
- Hard to see at a glance who's been notified

**Should be:**

```
[Top: tour title]
[If status != locked → big lock gate as today:
  Checklist (passengers / all assigned / handler picked) +
  big sticky "Lock tour" CTA]
[If status == locked:
  Header card: tour summary (bus number, departure time, handler)
  Big progress: X / Y passengers notified
  Filter pills: All · Pending · Notified
  List of passengers:
    - avatar + name + seat number
    - status: green dot if notified, accent dot if pending
    - WhatsApp circle button on right
  Bulk "Send to all unnotified" sticky CTA at bottom]
```

---

## Screen 7 — Settings (Profile tab)

**Today:** Profile hero + tri-state theme picker + settings list + danger logout.

**Pain:** Honestly fine. Just lacks personality.

**Should be:** Add 2-3 stat lines under the avatar showing what this agent has done:
- "12 tours · 240 passengers · ₹3.2L this month"

Plus an "Account" section card with phone + WhatsApp number visible (currently buried).

Otherwise leave as-is. Don't break what works.

---

## Screen 8 — Login

**Today:** Wordmark + hero + phone input + (password if admin matched) + CTA + admin setup link.

**Pain:** Fine but generic. Doesn't feel like the brand entry point.

**Should be:** Add a hero illustration or photo at the top (bus on a road, etc.). Make the wordmark BIG and the page feel more confident. Otherwise OK.

---

## Screen 9 — Admin Setup

**Today:** Form fields + submit (currently inert per code comment — admin accounts are provisioned via Supabase dashboard now).

**Pain:** Functionally dead but kept for legacy routes.

**Should be:** Reduce to a single "explainer" card: "Admin accounts are provisioned by the Ugam team. Contact support@..." with a contact CTA. Strip the form entirely.

---

## Screen 10 — Create Tour

**Today:** Form (title / route / dates / price / description) + sticky CTA.

**Pain:** Decent but no preview, no validation feedback inline.

**Should be:** Add a live preview card at the top that updates as the agent types (shows what the tour will look like on customer side). Otherwise keep current.

---

## Screen 11 — Edit Tour

**Today:** Same as create + danger delete circle in header.

**Pain:** Same as create. Delete button placement is good though.

**Should be:** Same live preview as Create. Plus a "Cancel changes" CTA next to the save button when fields are dirty.

---

## Screen 12 — Manage Buses

**Today:** Topbar with stat tiles + photo-anchored bus list + sticky "Add bus" CTA.

**Pain:** Honestly pretty good after the last rewrite. Lacks per-bus quick actions.

**Should be:** Add a small "..." menu on each bus row → Delete bus / View seat status / Re-broadcast to driver. Otherwise keep.

---

## Screen 13 — Add Bus

**Today:** Long single-page form with bus type chips, total seats stepper, single/seater splits, AC toggle, price.

**Pain:**
- Dense single page — overwhelming on first launch
- Bus type chips are buried mid-form
- The structural fields (total seats, split) ONLY matter in add mode (edit mode hides them) — but the form layout doesn't reflect that

**Should be — a guided wizard:**

```
3 steps:
  Step 1: Bus identity
    - Slot label
    - Bus number
    - Driver name + phone
    - AC toggle
  Step 2: Capacity & layout (skipped in edit mode)
    - Bus type chips (Sleeper / Mixed / Seater) — big colored cards
    - Total seats stepper
    - Sleeper split (single sofa count) if Sleeper/Mixed
    - Seater split if Mixed
  Step 3: Price
    - Price per seat (defaults from tour)
    - Preview: "X seats × ₹Y = ₹Z revenue if full"

[Top: step indicator dots + back chevron]
[Sticky bottom: Next / Save]
```

Wizard feels less overwhelming. In edit mode, skip step 2 and show steps 1 + 3 only.

---

## Screen 14 — Bus Status

**Today:** Header with bus name + tour + tally + seat grid (read-only).

**Pain:** Read-only chart — useful but no actions. Agent can't reassign from here.

**Should be:**
- Keep read-only seat grid (this is the "view" screen, not the editor)
- Add hero card at top with bus photo + driver name + phone (tap to call) + WhatsApp button
- Add "Edit bus details" link + "Open seat assignment" link below the grid

---

## Priority order for rebuild

If we agree on the plan above, I'd rebuild in this order:

1. **Dashboard** (the home, most-seen — sets the tone)
2. **Tours** (time-grouped sections, search bar)
3. **Tour Detail** (4 tabs: Overview / Passengers / Buses / Activity)
4. **Seat Assignment** (the workbench — pending-passenger dock at the bottom)
5. **Requests** (search + bulk actions)
6. **Notify** (post-lock notification tracker with progress)
7. **Add Bus** (wizard)
8. **Settings** (stat lines)
9. **Bus Status** (call + WhatsApp actions)
10. **Manage Buses** (row menu)
11. **Create / Edit Tour** (live preview)
12. **Login** (hero illustration)
13. **Admin Setup** (collapse to explainer)

---

## What I need from you

Tell me one of:

- **(A) The plan above is right — start with Dashboard**
- **(B) Mostly right, change X / Y / Z** — name the changes
- **(C) Wrong direction — what should I be thinking about instead?**

If (A): I'll rebuild the Dashboard end-to-end with the level of attention this plan describes, ship it, and you tell me if the depth is right before I do the other 12.
