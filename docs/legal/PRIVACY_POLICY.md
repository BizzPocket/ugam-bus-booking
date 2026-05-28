# Privacy Policy — Ugam Booking

**Last updated: 25 May 2026**

> ⚠️ **Before publishing:** replace every `[BRACKETED]` placeholder, then host this
> document at a **public URL** (e.g. GitHub Pages, your website, or a Notion
> public page). Both Google Play and the App Store require a reachable privacy
> policy URL on the store listing.

Ugam Booking ("the app", "we", "us") is a tour-management tool for booking
agents, published by **[Occubit Solution / YOUR LEGAL NAME]** ("the developer").
This policy explains what data the app handles, why, and your choices.

Contact: **[support@yourdomain.com]**

---

## Who uses the app

- **Agents (admins)** — sign in with a phone number and password (accounts are
  provisioned by the developer) to manage tours, buses, passengers and booking
  requests.
- **Customers (passengers)** — browse published tours and submit a booking
  request. Customers do **not** create an account; they are identified only by
  the phone number and name they enter on the booking form.

## What data we collect

**From agents (admins):**
- Account identifiers: phone number, display name, and a password (stored only
  as a salted hash by our authentication provider — we never see the plaintext).
- Business content you create: tours, buses, seat layouts, passenger records
  (name, phone, seat assignments, notes), and booking requests.
- **Contacts (optional):** if you grant contacts permission, the app reads your
  device address book to match incoming bookings to people you know. Matched
  contacts (name and phone number) are saved to your account so the matching
  persists across devices. You can decline this permission and still use the
  app; matching is then unavailable.

**From customers (passengers):**
- The name, phone number, party size, and booking details you submit on a
  booking-request form.

**Automatically:**
- Basic network-connectivity status (online/offline) to drive offline-first
  sync. We do **not** use third-party analytics, advertising, or tracking SDKs.

## How we use it

- To provide the core service: managing tours and seating, and routing booking
  requests between customers and agents.
- To let agents contact customers about their bookings (for example, by opening
  WhatsApp with a pre-filled message — see "Sharing" below).
- We do **not** sell your data or use it for advertising.

## Where data is stored

- App data is stored in our backend, hosted on **Supabase** (which runs on
  cloud infrastructure). Data is protected by row-level security so each agent
  can access only their own records.
- On your device, the app caches data locally (for offline use) and stores your
  login session in the platform's secure storage.

## Sharing

- **WhatsApp:** when an agent chooses to message a customer, the app opens
  WhatsApp with a pre-filled message. We do not transmit your data to WhatsApp
  in the background — sharing happens only when you tap to send. WhatsApp's own
  privacy policy then applies.
- **Service providers:** our backend host (Supabase) processes data on our
  behalf under their terms.
- **Legal:** we may disclose data if required by law.

## Data retention & deletion

- Agents can **permanently delete their account** at any time from
  **Settings → Delete Account**. This erases the account and all data the agent
  owns — tours, buses, passengers, booking requests, and synced contacts — and
  cannot be undone.
- Customers (passengers) can request deletion of the booking data they
  submitted by emailing **[support@yourdomain.com]**; we will delete it within
  30 days.
- Backups, if any, are purged on our standard rotation.

## Children

The app is intended for business use by tour agents and is not directed to
children under 13 (or the minimum age in your country).

## Changes

We may update this policy; the "Last updated" date above will change. Material
changes will be reflected in the app or on this page.

## Contact

Questions or deletion requests: **[support@yourdomain.com]**,
**[Developer legal name and address]**.
