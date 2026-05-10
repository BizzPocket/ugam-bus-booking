# Supabase Migration Design

**Date:** 2026-05-10
**Status:** Spec — pending implementation plan
**Replaces:** Self-hosted Appwrite as the backend for the OccuBus Booking Flutter app

## Summary

Replace the self-hosted Appwrite backend with **Supabase free tier (cloud)**. The Flutter app will talk to Supabase directly via `supabase_flutter`. No server code is written or operated by us. Per-admin data isolation is enforced by Postgres Row-Level Security (RLS) policies. The customer booking form (currently `customer_booking_request_screen.dart`) submits anonymously into a dedicated `booking_requests` table, then hands off to WhatsApp.

The motivation is to eliminate self-hosted backend infrastructure entirely while keeping the relational data model and a clean migration path off the vendor (it's still Postgres — `pg_dump` and leave at any time).

## Constraints and context

- 2 admins, 200–300 customer form submissions per month, peak usage 2–5 days/month, max 2 trips/month.
- Existing app already has an offline-first sqflite cache and a `sync_service.dart` that pulls from a remote backend; this stays.
- Customers do not log in — they fill the in-app form, the app writes a row, then deep-links to WhatsApp (per `project_request_capture_flow.md`).
- Appwrite has no real production data yet, so this is a clean cutover, not a data migration.
- Supabase free tier limits: 500 MB database, 50K monthly active users, unlimited API requests, project pauses after 7 days idle (~30s wakeup).

## Architecture

```
Flutter app  ──HTTPS──▶  Supabase
(supabase_flutter SDK)    (PostgREST + GoTrue + Postgres)
       │
       └── customer form (anon role) ──▶ booking_requests
       └── admin session (authenticated) ──▶ tours / passengers / etc.
```

- **No custom server.** All access to data is via the Supabase REST/Realtime API, which is auto-generated from the Postgres schema by PostgREST.
- **Auth** is handled by Supabase Auth (GoTrue). Each admin is a row in `auth.users`; we mirror profile fields into `public.admins`.
- **Authorization** is enforced by Postgres RLS policies on every table. Each policy compares row ownership against `auth.uid()`. There is no app-side authorization logic.
- **Customer flow** uses the anon API key, which has only the permission to `INSERT` into `booking_requests` (RLS policy explicitly allows it).

## Data model

All tables live in the `public` schema (Supabase default; PostgREST exposes it without extra config). All primary keys are `uuid` (`gen_random_uuid()`). Every table carries `created_at` and `updated_at`, with `updated_at` maintained by a `before update` trigger.

| Table | Purpose | Owner field |
|---|---|---|
| `admins` | Profile fields for each admin (`phone`, `name`, `whatsapp_number`). PK `= auth.users.id`. | self |
| `buses` | Bus metadata + seat layout JSON. | `owner_id` |
| `tours` | One per group trip. Optional FK to `buses`. | `owner_id` |
| `passengers` | Belongs to a tour. Holds seat assignments. | inherited via tour |
| `admin_contacts` | Per-admin contact directory (booking-side enrichment). | `owner_id` |
| `booking_requests` | Customer-form intake queue. | inherited via tour |

Indexes:

- `buses(owner_id, registration_no)` unique
- `tours(owner_id, status)` and `tours(start_date)`
- `passengers(tour_id)`; partial unique on `(tour_id, seat_no) where seat_no is not null`
- `admin_contacts(owner_id, phone)` unique; non-unique on `phone` for cross-admin lookup later
- `booking_requests(tour_id, status)`

The full SQL — tables, indexes, triggers, RLS policies, the auth-signup bootstrap trigger — is in this document under [SQL Schema](#sql-schema).

## RLS model

- `admins`: a row is readable/updatable only by its owner (`id = auth.uid()`).
- `buses`, `tours`, `admin_contacts`: full CRUD allowed only when `owner_id = auth.uid()`.
- `passengers`: full CRUD allowed only when the parent tour's `owner_id = auth.uid()` (enforced via `EXISTS` subquery).
- `booking_requests`:
  - `INSERT` allowed for the `anon` role (the customer form has no login).
  - `SELECT`/`UPDATE` allowed for `authenticated` only when the parent tour belongs to the caller. No `DELETE` policy — cancel by setting `status = 'cancelled'`.

There is no service-role usage from the client. The service-role key is kept on the server side only (used for admin tooling, never shipped to the app).

## Auth strategy

Supabase Auth's primary identity is email + password. Our existing custom phone+password login does not map directly. We adopt a **phone-as-email mapping**:

- The Flutter login form takes phone + password.
- Before calling `signInWithPassword`, the client transforms the phone into a synthetic email: `<10-digit-phone>@occubus.local`.
- Auth users are created once via the Supabase dashboard with this synthetic email and `Auto Confirm User` on (no email is ever sent).
- User metadata stores the canonical phone, name, and whatsapp_number; the `on_auth_user_created` trigger seeds `public.admins` from that metadata.

This gives us Supabase's session/refresh/JWT machinery for free without a real email infrastructure. JWT lifetime stays at the Supabase default (1 hour access token, refreshed automatically by the SDK using the refresh token).

The existing `admin_auth_service.dart` salted-SHA-256 logic is discarded. Password hashing is handled internally by Supabase Auth (bcrypt).

## Flutter-side changes

**Removed**

- `lib/services/appwrite_service.dart`
- `lib/services/admin_auth_service.dart` (replaced by `supabase_flutter` auth)
- `lib/config/appwrite_config.dart`
- `appwrite: ^12.0.4` from `pubspec.yaml`

**Added**

- `lib/config/supabase_config.dart` — project URL + anon key (compile-time constants).
- `lib/services/supabase_service.dart` — initializer for `Supabase.initialize(...)` called from `main.dart`.
- `flutter_secure_storage` to `pubspec.yaml` (Supabase SDK's session persistence backend).

**Rewritten** (data-layer rewrites only; UI screens untouched because controllers shield them)

- `lib/controllers/auth_controller.dart` — phone+password → `signInWithPassword({ email: phoneToEmail(phone), password })`. Reads admin profile from `admins` row.
- `lib/services/sync_service.dart` (currently 416 lines) — replace Appwrite document fetches with `supabase.from('<table>').select()` queries. The sqflite upsert path stays the same.
- `lib/services/contact_sync_service.dart` — same pattern, hits `admin_contacts`.
- `lib/services/user_service.dart` — reads/writes `admin_contacts` instead of the Appwrite users collection.
- `lib/controllers/tour_controller.dart` — switches CRUD to `supabase.from('tours')`.
- `lib/controllers/user_controller.dart` — same.
- `lib/screens/customer_booking_request_screen.dart` — anonymous `INSERT` into `booking_requests`.

**Untouched**

- `lib/services/offline_database.dart` — sqflite layer is backend-agnostic.
- `lib/services/whatsapp_service.dart` — no change.
- All UI screens.

## Sync model

The pull-based sync stays. The app keeps a `last_sync_at` timestamp per resource. On launch (and pull-to-refresh):

- For each resource, `supabase.from('<table>').select().gt('updated_at', lastSyncAt)` returns rows changed since last sync.
- The app upserts into sqflite and bumps `last_sync_at`.
- Writes go straight to the local DB plus a "dirty" flag, then flush to Supabase in the background. On 200 OK, the flag clears.

Realtime subscriptions are **not** used in v1. Adding them later is purely additive (one-line `.stream(...)` per controller); we don't design for them now to keep the migration small.

## Cutover plan

This is a flip-the-switch migration, not a data migration:

1. Run [the SQL](#sql-schema) once in the Supabase SQL Editor.
2. Create the 2 admin auth users via the dashboard (email = `<phone>@occubus.local`, `Auto Confirm User` on, set `raw_user_meta_data` with `phone`/`name`/`whatsapp_number`). The trigger auto-creates the matching `admins` rows.
3. Implement the Flutter changes above (deps swap, services rewrite, controllers rewrite).
4. Smoke-test login + create-tour + add-passenger + customer-form-submit on both admin phones.
5. Set up a free uptime ping (cron-job.org or UptimeRobot) hitting `https://<project>.supabase.co/rest/v1/booking_requests?select=id&limit=1` with the anon key as `apikey` header, every 24 hours, to defeat the 7-day idle pause.
6. Tear down the self-hosted Appwrite container and remove the public Postgres exposure on port 5433 (Postgres now sits behind Supabase only).

## Risks and trade-offs

- **Project pause after 7 days idle.** First request after a pause takes ~30s. Mitigated by a daily uptime ping.
- **Free-tier database is 500 MB.** Current data shape (group bookings, ~2 trips/month, ~50 passengers per trip) will not approach this for years.
- **No instant token revocation.** If a phone is lost, manually `signOut` the affected user via the Supabase dashboard or rotate their password.
- **Synthetic email mapping is mildly ugly.** Acceptable for 2 admins. If the user base grows or Supabase ever requires verified emails, switch to Supabase Phone Auth (paid SMS) or run a custom JWT issuer.
- **No realtime push** out of the box. Existing pull-to-refresh stays. Add Realtime later if needed.

## SQL Schema

```sql
-- ============================================================
-- OccuBus Booking — Supabase schema
-- Run this once in the Supabase SQL Editor.
-- gen_random_uuid() is available out of the box on Supabase.
-- ============================================================

-- ─── 1. updated_at trigger function ─────────────────────────
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ─── 2. admins (mirrors auth.users for our extra fields) ────
create table public.admins (
  id              uuid primary key references auth.users(id) on delete cascade,
  phone           text unique,
  name            text,
  whatsapp_number text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger admins_set_updated_at before update on public.admins
  for each row execute function public.set_updated_at();
alter table public.admins enable row level security;
create policy "admins_select_self" on public.admins for select to authenticated
  using (id = auth.uid());
create policy "admins_update_self" on public.admins for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ─── 3. buses ───────────────────────────────────────────────
create table public.buses (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references auth.users(id) on delete cascade,
  registration_no  text not null,
  model            text,
  total_seats      int  not null check (total_seats > 0),
  layout           jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index buses_owner_idx on public.buses(owner_id);
create unique index buses_owner_reg_unique on public.buses(owner_id, registration_no);
create trigger buses_set_updated_at before update on public.buses
  for each row execute function public.set_updated_at();
alter table public.buses enable row level security;
create policy "buses_owner_all" on public.buses for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ─── 4. tours ───────────────────────────────────────────────
create table public.tours (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  source       text,
  destination  text,
  start_date   date,
  end_date     date,
  bus_id       uuid references public.buses(id) on delete set null,
  status       text not null default 'draft',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index tours_owner_status_idx on public.tours(owner_id, status);
create index tours_start_date_idx   on public.tours(start_date);
create trigger tours_set_updated_at before update on public.tours
  for each row execute function public.set_updated_at();
alter table public.tours enable row level security;
create policy "tours_owner_all" on public.tours for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ─── 5. passengers (access via parent tour) ─────────────────
create table public.passengers (
  id              uuid primary key default gen_random_uuid(),
  tour_id         uuid not null references public.tours(id) on delete cascade,
  name            text not null,
  phone           text,
  seat_no         text,
  gender          text,
  age             int,
  status          text not null default 'confirmed',
  request_source  text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index passengers_tour_idx on public.passengers(tour_id);
create unique index passengers_seat_unique
  on public.passengers(tour_id, seat_no) where seat_no is not null;
create trigger passengers_set_updated_at before update on public.passengers
  for each row execute function public.set_updated_at();
alter table public.passengers enable row level security;
create policy "passengers_owner_all" on public.passengers for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = passengers.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = passengers.tour_id and t.owner_id = auth.uid()));

-- ─── 6. admin_contacts (per-admin contact directory) ────────
create table public.admin_contacts (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  phone       text not null,
  name        text not null,
  source      text not null default 'manual',
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index admin_contacts_owner_phone_unique on public.admin_contacts(owner_id, phone);
create index admin_contacts_phone_idx on public.admin_contacts(phone);
create trigger admin_contacts_set_updated_at before update on public.admin_contacts
  for each row execute function public.set_updated_at();
alter table public.admin_contacts enable row level security;
create policy "admin_contacts_owner_all" on public.admin_contacts for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ─── 7. booking_requests (public form intake) ───────────────
create table public.booking_requests (
  id              uuid primary key default gen_random_uuid(),
  tour_id         uuid not null references public.tours(id) on delete cascade,
  customer_phone  text not null,
  customer_name   text not null,
  party_size      int  not null default 1 check (party_size > 0),
  raw_form        jsonb,
  status          text not null default 'pending',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index booking_requests_tour_status_idx on public.booking_requests(tour_id, status);
create trigger booking_requests_set_updated_at before update on public.booking_requests
  for each row execute function public.set_updated_at();
alter table public.booking_requests enable row level security;

create policy "booking_requests_insert_anon" on public.booking_requests
  for insert to anon with check (true);

create policy "booking_requests_owner_select" on public.booking_requests
  for select to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = booking_requests.tour_id and t.owner_id = auth.uid()));
create policy "booking_requests_owner_update" on public.booking_requests
  for update to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = booking_requests.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = booking_requests.tour_id and t.owner_id = auth.uid()));

-- ─── 8. Auto-seed admins row when an auth user is created ───
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.admins (id, phone, name, whatsapp_number)
  values (
    new.id,
    new.raw_user_meta_data->>'phone',
    new.raw_user_meta_data->>'name',
    new.raw_user_meta_data->>'whatsapp_number'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
```

## Out of scope (deferred)

- Realtime subscriptions for live dashboard updates.
- Push notifications (FCM) when a customer submits a booking.
- File/photo storage for tours (would use Supabase Storage when needed).
- Multi-org / multi-tenant scoping beyond the per-admin owner_id model.
