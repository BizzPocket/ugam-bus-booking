# Contacts Sync — Design

**Date:** 2026-05-06
**Status:** Approved, in implementation

## Goal

When a customer submits a booking, the agent should instantly see the
customer's name as **the agent has it saved in their phonebook**, not as
a raw number or whatever the customer typed in the form.

Two consequences:

1. The agent imports their phone's address book into Appwrite. That
   address book becomes the canonical "who is this number?" lookup.
2. When a booking arrives from a phone the agent doesn't have saved,
   it auto-grows into their saved contacts (using the name the customer
   typed). They can revise it later from the device contacts app and
   re-sync.

## Non-goals (this phase)

- No in-app Contacts screen / CRM. Sync is invisible — the agent
  manages their list in the OS contacts app, not here.
- No two-way sync. Edits in the app don't write back to the phone.
- No multi-phone-per-contact. One row per (admin, phone). Two phones
  for one person → two rows, same name. Acceptable.
- No customer-side name enrichment. The customer types their name on
  the booking form themselves; we don't pre-fill from `users`.
- No tour-history-per-contact view. Maybe later.

## Architecture

### Collections

`admins` — **unchanged**. Phone + passwordHash + salt + name + optional
WhatsApp number. Powers existing login.

`users` — **new**. Each row is "Admin X has Phone Y saved as Name Z".

| Field | Type | Notes |
|---|---|---|
| `phone` | string(10) | last-10 normalised |
| `name` | string(100) | as the owning admin saved them |
| `source` | string(16) | `device` / `booking` / `manual` |
| `addedByAdminId` | string(64) | admin `$id` |
| `note` | string(500), optional | |

Indexes:

- **Compound unique** on `(addedByAdminId, phone)` — same phone can
  exist once per admin. Admin A's "Mehul Patel" and Admin B's
  "Mehulbhai" coexist.
- Plain key on `phone` — for the booking auto-grow path that needs
  "does any admin already know this phone?" (we still insert under
  the tour creator's id, but cheap lookup helps).

### Flutter components

```
ContactSyncService    reads device contacts via flutter_contacts
       ↓ (on admin login + on app open)
UserService           Appwrite CRUD for the `users` collection
       ↓
UserController        in-memory map: phone → name (scoped to current admin)
       ↓
[Requests, TourDetail, SeatAssignment screens]
       call userCtrl.nameForPhone(phone) ?? passenger.name
```

### Sync trigger

- **On admin login**, after successful password verification:
  - Request CONTACTS permission (system dialog).
  - On grant: pull device contacts, normalise phones, batch-upsert into
    `users` scoped to the current admin's `$id`. Skip rows that already
    exist (no overwrite of admin-edited names).
  - On deny: skip silently. Sync can be retried on next login.
- **On every app launch** (when an admin session is restored): run a
  cheap incremental sync — pull device contacts, upsert only phones
  not yet present in this admin's `users` rows.

### Auto-grow on booking

`customer_booking_request_screen.dart` `_submit()` — after the Passenger
write succeeds:

- Look up `(tour.createdBy → admin id, phone)` in `users`.
- If not found: insert a `users` row with `source = booking`,
  `name = customer-entered name`, `addedByAdminId = tour creator's
  admin id`.
- If found: do nothing (don't overwrite the admin's saved name).

(`tour.createdBy` is currently the admin's phone, not their `$id`. The
implementation will resolve phone → admin `$id` once at boot time and
cache it.)

### Enrichment

A new `UserController.nameForPhone(String phone) → String?` method:

- Returns the saved name from the in-memory cache if found, else null.
- Cache is the current admin's full `users` rows, indexed by phone.

Display sites:

- `requests_screen.dart` — passenger.name → `userCtrl.nameForPhone(passenger.phone) ?? passenger.name`
- `tour_detail_screen.dart` — same
- `tour_seat_assignment_screen.dart` — same
- Any other passenger list cell

A small extension on `Passenger` (e.g. `passenger.displayName`) would
keep this DRY but isn't required.

## Permissions / consent

- **Android:** `READ_CONTACTS` permission via `flutter_contacts`.
- **iOS:** `NSContactsUsageDescription` in `Info.plist`, request via
  `flutter_contacts`.
- The bulk pull only runs after the admin grants. If denied, the rest
  of the app works — auto-grow on bookings still populates `users`,
  just from one phone at a time.

## Failure modes

- **Permission denied:** show a one-time toast ("Tap to grant contacts
  access for booking name auto-fill"), then never bother the admin
  again unless they re-trigger from a settings option (out of scope
  this phase — currently no UI to retry except logout/login).
- **Network down during sync:** `SyncService.smartInsert` already
  handles offline queueing; rows pile up locally and flush when online.
- **Duplicate phone collision** (compound key violation): the upsert
  swallows the error since "row exists for this admin+phone" is the
  expected case, not a bug.

## Out of scope

- Editing a contact from inside the app
- Search / browse UI
- Opt-out per contact
- WhatsApp Business API integration
- Customer-side name pre-fill on the booking form

These can be future phases; the data model supports them.
