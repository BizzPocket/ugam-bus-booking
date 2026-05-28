# App Privacy Questionnaire + Review Answers (Ugam Booking)

Use this to fill App Store Connect → App Privacy, Age Rating, and App Review Information.

---

## App Privacy ("Data Types") — what to select

When asked **"Do you collect data from this app?"** → **Yes**.

| Data type | Collected? | Linked to user? | Used for tracking? | Purpose |
|---|---|---|---|---|
| **Contact Info → Name** | Yes | Yes | No | App Functionality |
| **Contact Info → Phone Number** | Yes | Yes | No | App Functionality |
| **Contacts** (device address book) | Yes | Yes | No | App Functionality |
| **User Content → Other** (seat/booking requests) | Yes | Yes | No | App Functionality |

For everything else (Location, Financial Info, Health, Browsing History, Identifiers, Purchases, Usage Data, Diagnostics, Advertising) → **not collected**.

**Tracking question:** "Do you use data to track users?" → **No.**

> Note: only declare **Contacts** if the app actually reads device contacts in the build you upload. It has the permission string (`NSContactsUsageDescription`). If the v1.0 build never calls the contacts API, you may leave Contacts out — but declaring it is the safe, honest choice.

---

## Age Rating
Answer **None** to every content question → results in **4+**.

---

## Export Compliance
Already pre-answered in the build (`ITSAppUsesNonExemptEncryption = false`). If App Store Connect still asks:
- "Does your app use encryption?" → **Standard encryption only (HTTPS/TLS)** → **Exempt**.

---

## App Review Information (the notes box at submit time)

**Sign-in required?** → **No** (the app is usable without an account).

**Notes for the reviewer** (paste this):
```
Ugam Booking lets users browse group bus tours run by Ugam Foj, view trip
details, and submit seat requests. No login is required to browse tours and
submit a request — you can use the app immediately on launch.

The app can open WhatsApp to let a user continue a booking conversation with
the organiser; this is optional and not required to use the core features.

Contacts permission (if prompted) is only used to match saved contact names to
bookings on-device; the app works fully if the permission is denied.

We are launching for a scheduled group departure and would be grateful for
expedited review. Thank you.
```

**Contact info:** your name, phone, and email (contact@devam.org or your own).

---

## Expedited Review request
After submitting, go to:
https://developer.apple.com/contact/app-store/?topic=expedite
Fill the form, reference the bundle ID `com.occubitsolution.ugambooking`, and state
your departure/launch date (29 May 2026 afternoon) as the reason. Apple often
grants these within hours for genuine deadlines. Request it **once** — repeated
requests can hurt you.
