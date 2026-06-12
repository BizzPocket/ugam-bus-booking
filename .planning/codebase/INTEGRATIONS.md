# External Integrations

**Analysis Date:** 2026-06-06

---

## 1. Supabase

**Role:** Primary backend — PostgreSQL database, Auth, Realtime, Storage, Edge Functions.

**Project URL:** `https://rhyqjzulpvaeslbaymex.supabase.co`

### Configuration

| Location | Content |
|----------|---------|
| `lib/config/supabase_config.dart` | URL + anon key (hardcoded constants) |
| `lib/main.dart` lines 58-64 | `Supabase.initialize()` called during bootstrap (parallel with `EasyLocalization.ensureInitialized()`) |
| `lib/services/supabase_service.dart` | Singleton wrapper exposing `Supabase.instance.client` |

**Credentials in code:**
- `SupabaseConfig.url` = `https://rhyqjzulpvaeslbaymex.supabase.co` (hardcoded)
- `SupabaseConfig.anonKey` = `sb_publishable_...` (hardcoded in source)
- The anon key is a publishable Supabase key — it is safe to ship in a mobile app binary; Row Level Security enforces data access, not key secrecy. Row-level policies enforce `owner_id = auth.uid()` for writes.

### 1a. PostgreSQL Database

**Client:** `supabase_flutter` 2.12.4 — PostgREST HTTP client

**Data access layer:** `lib/services/sync_service.dart`
- All reads are live (`smartFetch`) with 8-second timeout
- All writes (`smartInsert` / `smartUpdate` / `smartDelete`) are online-only with 12-second timeout; no offline queue
- `owner_id` is backfilled from `auth.uid()` before writes on `tours`, `buses`, `admin_contacts`, `customer_memory`

**Tables used (from `database.sql` and migrations):**

| Table | Purpose |
|-------|---------|
| `admins` | Authenticated agents; one row = one agent account |
| `tours` | Tour entities with route, dates, broadcast fields |
| `buses` | Buses assigned to a tour (one-to-many on `tour_id`) |
| `passengers` | Booked passengers per tour |
| `passenger_groups` | Cross-booking seat-priority groups |
| `booking_requests` | Customer in-app booking requests (unauthenticated write via anon RLS) |
| `admin_contacts` | Agent's saved contacts for broadcast targeting |
| `customer_memory` | Per-device customer identity memory |
| `collections` | Money collection records |
| `expenses` | Handler expense entries |
| `bus_handovers` | Handler bus handover logs |

**RPCs:**

| Function | Caller | Purpose |
|----------|--------|---------|
| `admin_lookup_by_phone(p_phone)` | `lib/services/admin_auth_service.dart` | SECURITY DEFINER — exposes id/phone/name to anon before sign-in |
| `delete_my_account()` | `lib/services/admin_auth_service.dart` | SECURITY DEFINER — deletes auth.users row + cascades |
| Various `customer_*` RPCs | `lib/services/customer_requests_store.dart` | Customer booking request CRUD |

**Schema files:**
- Full reset/rebuild: `database.sql` (run in Supabase SQL editor)
- Incremental migrations: `supabase/migrations/001_initial_schema.sql` through `010_handler_expenses.sql`

### 1b. Supabase Auth

**Strategy:** Email/password sign-in using **synthetic email addresses** — phone numbers are mapped to `<last10digits>@occubus.local`. No real email infrastructure.

**Session persistence:** `flutter_secure_storage` 9.2.4 stores the refresh token in iOS Keychain / Android Keystore. Sessions survive app restart.

**Admin sign-in flow:**
1. Anon RPC `admin_lookup_by_phone` checks if the phone matches an `admins` row
2. On match: `_client.auth.signInWithPassword(email: syntheticEmail, password: password)` in `lib/services/admin_auth_service.dart`
3. On success: fetch full `admins` row via `admins_select_self` RLS policy

**Customer flow:** Unauthenticated — `booking_requests` table has an anon INSERT policy. Customer identity is held in `customer_memory` (device-local).

**Risk:** Admin accounts must be created via the Supabase dashboard; there is no self-registration in the app. The synthetic email scheme means password reset emails go to `<phone>@occubus.local` — an unreachable address. Password recovery is a manual admin operation.

### 1c. Supabase Realtime

**Client:** `lib/services/realtime_service.dart`

**Channel:** One authenticated channel per logged-in admin, named `admin-data-<uid>`.

**Subscribed tables:** `tours`, `passengers`, `buses`, `booking_requests` — all events (`PostgresChangeEvent.all`)

**Pattern:** Single broadcast `Stream<DataChangedEvent>` fanned out to all subscribers. Controllers debounce and refetch their slice on receiving an event.

**Lifecycle:** Channel is torn down on auth state change (logout / session expiry) and re-created on login. Errors are logged via `dart:developer` but not surfaced to the user.

### 1d. Supabase Storage

**Buckets (created in migration `009_whatsapp_broadcast.sql`):**

| Bucket | Visibility | Purpose |
|--------|-----------|---------|
| `tour-broadcasts` | Public read | Tour announcement hero images uploaded before broadcasting |
| `seat-charts` | Public read | Seat-chart PDFs uploaded for WhatsApp document template headers |

**Upload location:** `lib/services/whatsapp_cloud_service.dart` → `uploadPublic()` — upserts to a deterministic path `<tour_id>/<bus_id>.pdf` so re-sends reuse the same URL.

**Risk:** Both buckets are intentionally public-read (required by WhatsApp Cloud API to fetch template media by URL). Do not store anything sensitive in these buckets.

### 1e. Supabase Edge Functions

**Function:** `whatsapp-send` — deployed at `supabase/functions/whatsapp-send/index.ts`

See WhatsApp Cloud API section below for full details.

---

## 2. WhatsApp Cloud API (Meta Graph API)

**Purpose:** Business-initiated WhatsApp messages using approved templates — two flows:
1. **Phase 2 — Tour broadcast:** announce a new tour to all saved contacts
2. **Phase 8 — Seat allocation:** send each passenger their seat number + seat-chart PDF

### Architecture

```
Flutter app (admin)
  ↓  authenticated supabase.functions.invoke('whatsapp-send')
Supabase Edge Function (supabase/functions/whatsapp-send/index.ts)
  ↓  Bearer WHATSAPP_TOKEN
Meta Graph API https://graph.facebook.com/v21.0/<PHONE_NUMBER_ID>/messages
```

### Configuration

| Location | Content |
|----------|---------|
| `lib/config/whatsapp_cloud_config.dart` | Template names, language code, country code, bucket names — no secrets |
| Edge Function secrets (never in source) | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_GRAPH_VERSION` |

**Template names (must match Meta Business Manager approvals):**
- `tour_broadcast` — body variable `{{1}}` = entire broadcast message text
- `seat_allocation` — header = PDF document; body variables `{{1}}` name, `{{2}}` tour title, `{{3}}` seats, `{{4}}` bus, `{{5}}` date

**Default language:** Gujarati (`gu`)

**Country code:** `91` (India) — prepended to bare 10-digit numbers in `WhatsAppCloudService.graphPhone()`

### Key Source Files

| File | Role |
|------|------|
| `lib/config/whatsapp_cloud_config.dart` | Template / bucket constants |
| `lib/services/whatsapp_cloud_service.dart` | HTTP client wrapper — `send(List<WaMessage>)` + `uploadPublic()` |
| `lib/services/whatsapp_outbound.dart` | High-level actions: `sendBroadcast()`, `sendSeatAllocations()` |
| `supabase/functions/whatsapp-send/index.ts` | Server-side sender — injects token, calls Graph API sequentially |
| `supabase/migrations/009_whatsapp_broadcast.sql` | Creates Storage buckets + policies |

### Send Behaviour

- Messages are sent **sequentially** (not in parallel) inside the Edge Function. This avoids Meta burst-limit violations and produces per-recipient `{to, ok, id?, error?}` results.
- `WaSendResult` tracks `sent` + `failed` counts. A partial failure does not abort the batch — `WaSendResult.failed > 0` must be checked by callers.
- Storage uploads use `upsert: true` so re-sending a tour reuses the same PDF URL without creating duplicate files.

### Edge Function Auth

`verify_jwt` is enabled (Supabase default). The Edge Function can only be called with a valid Supabase session — it cannot be invoked anonymously or by the customer side of the app.

### Risks

- **Template mismatch:** if the approved Meta template variable order differs from `WhatsAppCloudConfig`, messages will be malformed. Variable contract is documented in `docs/WHATSAPP_CLOUD_API_SETUP.md`.
- **24-hour window rule:** both flows use templates (MARKETING / UTILITY categories), satisfying Meta's business-initiated message requirement. Free-text messaging is not used.
- **Public Storage URLs:** PDF seat charts and broadcast images are publicly accessible by URL. Anyone with the URL can view the file. Consider whether seat-chart PDFs should contain PII (they contain passenger names + phones).
- **No token rotation:** the permanent access token has no expiry management in code. If the token is revoked or expired, all sends fail silently until the Edge Function secret is updated via `supabase secrets set`.

---

## 3. WhatsApp Deep-Link (Free, Parallel Approach)

**Purpose:** Fallback / supplemental direct messaging for agents — opens WhatsApp on-device with a pre-filled text message. Zero cost, no approval needed.

**Source:** `lib/services/whatsapp_service.dart`

**Mechanism:**
- Builds a `wa.me/<phone>?text=<encoded>` URL via `url_launcher`
- Used for: individual ticket send, acknowledgement messages, customer booking-request flow (customer sends their booking to the admin's number)
- The `WhatsAppService.adminSignature()` method reads the logged-in admin's `waHandoffTemplate` field from the `admins` table to append a custom signature

**Android declaration:** `android/app/src/main/AndroidManifest.xml` declares `<queries>` for `com.whatsapp`, `com.whatsapp.w4b`, and `wa.me` scheme — required on Android 11+ for `canLaunchUrl()` to return true.

**iOS declaration:** `ios/Runner/Info.plist` lists `whatsapp` in `LSApplicationQueriesSchemes`.

---

## 4. PDF Generation (Local, No External Service)

**Purpose:** A4 seat-chart PDFs and per-passenger PNG images for WhatsApp share / upload.

**Packages:** `pdf` 3.12.0 + `printing` 5.14.3

**Source:** `lib/services/seat_chart_pdf.dart`

**Font strategy:** Loads Noto Sans (Regular + Bold + Gujarati + Devanagari) from `PdfGoogleFonts` on first call — downloads from `fonts.gstatic.com` once then disk-caches. Gracefully falls back to the built-in Latin font if the network is unavailable. Font state is cached in a process-level static so subsequent PDF builds are instant.

**Output paths:**
- A4 PDF bytes → `Printing.sharePdf()` (native share sheet) or uploaded to Supabase Storage
- Rasterised PNG pages (150 dpi) → passed to `share_plus` or WhatsApp Cloud API image send

---

## 5. Device Contacts

**Purpose:** Enriches customer booking requests with real names from the agent's address book.

**Package:** `flutter_contacts` 2.1.0

**Source:** `lib/services/contact_sync_service.dart`

**Permission:**
- Android: `READ_CONTACTS` declared in `android/app/src/main/AndroidManifest.xml`
- iOS: `NSContactsUsageDescription` in `ios/Runner/Info.plist` — "Ugam Booking matches your saved contacts to incoming bookings so you instantly see who booked."

**Data flow:** Reads all contacts → normalises each phone to last 10 digits → deduplicates by phone (last name wins) → returned as `List<DeviceContactEntry>` to the caller. No contacts are uploaded to the server.

---

## 6. CI/CD & Distribution

**CI Platform:** GitHub Actions — `.github/workflows/release.yml`

**Trigger:** Push to a `v*` tag or `workflow_dispatch` with a tag name input.

**Build target:** Android release APK only (no iOS in CI — iOS uses `scripts/build_ios_release.sh` run locally on macOS).

**Output:** APK uploaded as a GitHub Release asset alongside `dist/latest.json` (update manifest with version + APK URL).

**Signing:** Release signing keys are expected at `android/key.properties` + `upload-keystore.jks` (git-ignored). CI builds without them fall back to debug signing — store uploads must be performed from a machine with the keystore.

**Secrets used in CI:** None beyond the default `GITHUB_TOKEN` (used by `softprops/action-gh-release@v2` to create releases).

---

## 7. Connectivity Detection

**Package:** `connectivity_plus` 6.1.5

**Source:** `lib/services/sync_service.dart`

**Mechanism:** Subscribes to `Connectivity().onConnectivityChanged` stream. Sets `isOnline` reactive bool. Used as a fast-fail guard in `_ensureOnline()` before every write to prevent hanging requests when the interface is clearly down. Note: this detects interface availability, not internet reachability.

---

## 8. Appwrite (Legacy / Abandoned)

**Location:** `appwrite/` directory contains CSV data exports (`tours.csv`, `passengers.csv`, `bus_details.csv`) and a `README.md` / `SCHEMA_CHANGES.md`.

This is residual migration data from the original Appwrite backend. **Appwrite is not used at all** — the app is fully migrated to Supabase. The directory can be deleted safely; it is not referenced by any code.

---

## Environment Configuration Summary

**Required to run the app (no setup needed — all hardcoded):**
- Supabase URL: `lib/config/supabase_config.dart`
- Supabase anon key: `lib/config/supabase_config.dart`

**Required for WhatsApp Cloud API (must be set as Edge Function secrets):**
- `WHATSAPP_TOKEN` — permanent Meta Graph API access token
- `WHATSAPP_PHONE_NUMBER_ID` — WhatsApp Business phone number ID from Meta
- `WHATSAPP_GRAPH_VERSION` — Graph API version (defaults to `v21.0`)

**Required for Android Play Store release builds (local machine only, never in CI):**
- `android/key.properties` (git-ignored) — keystore path + passwords
- `android/upload-keystore.jks` (git-ignored) — upload keystore

**Required for iOS App Store release builds:**
- Run via `scripts/build_ios_release.sh` on macOS — handles `objective_c.framework` simulator-slice contamination bug

---

*Integration audit: 2026-06-06*
