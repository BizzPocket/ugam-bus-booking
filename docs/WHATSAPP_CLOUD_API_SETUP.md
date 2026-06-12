# WhatsApp Cloud API — Setup & Deploy

This integration sends two kinds of business-initiated WhatsApp messages:

1. **Tour broadcast** (phase 2) — announce a tour to your saved contacts, with an optional image.
2. **Seat allocation** (phase 8) — on lock, message each seated passenger their seat number + the bus seat-chart **PDF** as a document.

The permanent access **token never ships in the app**. The Flutter app calls a Supabase **Edge Function** (`whatsapp-send`) that holds the token as a secret and calls Meta's Graph API.

```
App  ──(authenticated invoke)──>  Edge Function `whatsapp-send`  ──(Bearer token)──>  Meta Graph API
        builds template payload          injects WHATSAPP_TOKEN
```

---

## 1. Meta side (you do this once)

In [Meta Business Manager](https://business.facebook.com/) → WhatsApp:

1. Create/confirm a **WhatsApp Business Account (WABA)** and add a **phone number**.
2. Get your **Phone Number ID** (WhatsApp → API Setup).
3. Generate a **permanent access token** (System User → assign the WABA → generate token with `whatsapp_business_messaging` + `whatsapp_business_management`).
4. Make sure your two **message templates** are approved and match the contract below.

### Required template contract

> ⚠️ The app sends variables **positionally** (`{{1}}, {{2}}, …`). Your approved templates must use this **exact order**, or the message will be malformed. If your existing templates differ, either re-create them to match, or tell me your variable order and I'll adapt `lib/config/whatsapp_cloud_config.dart`.

**Template 1 — `tour_broadcast`** (category: MARKETING)
- **Header:** Image (optional — only sent when a broadcast image is attached)
- **Body variables:**
  | # | Meaning | Example |
  |---|---------|---------|
  | {{1}} | Tour title | Rajkot → Goa Express |
  | {{2}} | Route | Rajkot → Goa |
  | {{3}} | Departure date | 12 Jun 2026 |
  | {{4}} | Price per seat | ₹450 |
  | {{5}} | Broadcast description | Bus leaves 6 AM sharp from… |

**Template 2 — `seat_allocation`** (category: UTILITY)
- **Header:** Document (the seat-chart PDF)
- **Body variables:**
  | # | Meaning | Example |
  |---|---------|---------|
  | {{1}} | Passenger name | Ramesh Patel |
  | {{2}} | Tour title | Rajkot → Goa Express |
  | {{3}} | Seat numbers | A3, A4 |
  | {{4}} | Bus | GJ05HU7162 |
  | {{5}} | Departure date | 12 Jun 2026 |

Template names + default language live in `lib/config/whatsapp_cloud_config.dart`
(`broadcastTemplate`, `seatAllocationTemplate`, `defaultLanguage`). Change them there if your
approved names/language differ.

---

## 2. Supabase side (deploy)

From the project root, with the [Supabase CLI](https://supabase.com/docs/guides/cli) linked to your project:

```bash
# a) Apply the DB migration: tour broadcast columns + public Storage buckets
supabase db push          # applies supabase/migrations/009_whatsapp_broadcast.sql
#   (or paste 009_whatsapp_broadcast.sql into the SQL editor)

# b) Set the secrets (NEVER commit these)
supabase secrets set WHATSAPP_TOKEN=EAAG...your-permanent-token
supabase secrets set WHATSAPP_PHONE_NUMBER_ID=1234567890
# optional, defaults to v21.0:
supabase secrets set WHATSAPP_GRAPH_VERSION=v21.0

# c) Deploy the Edge Function
supabase functions deploy whatsapp-send
```

The function requires an authenticated Supabase user (the signed-in admin app),
so it can't be called anonymously.

---

## 3. How it's used in the app

- **Create tour:** the broadcast composer (description + optional image) saves
  `broadcast_message` / `broadcast_image_url` on the tour. The image is uploaded
  to the public `tour-broadcasts` Storage bucket.
- **Send broadcast:** Tour detail → Overview → **“Send broadcast on WhatsApp”**
  sends `tour_broadcast` to all saved contacts (`admin_contacts`).
- **Seat allocation:** locking a tour (Notify tab) offers to send `seat_allocation`
  to every seated passenger. One seat-chart PDF is generated per bus, uploaded to
  the public `seat-charts` bucket, and attached as the template's document header.

---

## 4. Notes & gotchas

- **Phone format:** numbers are stored as 10 digits; the app prepends country code
  `91` (see `WhatsAppCloudConfig.defaultCountryCode`) before sending. Change that
  constant for other countries.
- **24-hour rule:** business-initiated messages **must** use approved templates
  (that's why both flows are template-based). Free text only works within 24h of
  the customer messaging you.
- **Costs / rate limits:** each template message is billed by Meta. The function
  sends sequentially and reports per-recipient success/failure, so a few failures
  don't abort the batch.
- **Storage is public-read:** the Cloud API fetches header media (image/PDF) by
  URL, so the buckets are public. Don't put anything sensitive in them beyond the
  broadcast image and seat charts.
