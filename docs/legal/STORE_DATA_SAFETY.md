# Store data-disclosure answers — Ugam Booking

Fill the Play **Data safety** form and the App Store Connect **App Privacy**
section using the answers below. These are derived from what the app actually
collects (see [PRIVACY_POLICY.md](PRIVACY_POLICY.md)). If you add analytics,
crash reporting, ads, or payments later, update both stores.

Baseline facts:
- No third-party analytics, ads, or tracking SDKs.
- All collected data is **encrypted in transit** (HTTPS / WSS to Supabase).
- Data is **linked to the user's identity** (stored under their account).
- Users can **request deletion** (in-app for agents; by email for customers).
- The app does **not** track users across other apps/websites.

---

## Google Play — Data safety

**Does your app collect or share any of the required user data types?** → **Yes**

| Data type | Collected | Shared | Purpose | Linked to user | Optional? |
|---|---|---|---|---|---|
| **Name** | Yes | No | App functionality | Yes | Required |
| **Phone number** | Yes | No | App functionality | Yes | Required |
| **Contacts** (device address book — name + phone) | Yes | No | App functionality (match bookings to known contacts) | Yes | **Optional** (user can decline the permission) |
| **Other user content** (tours, passengers, booking notes) | Yes | No | App functionality | Yes | Required |

- **Is all data encrypted in transit?** → Yes
- **Do you provide a way to request data deletion?** → Yes (in-app account
  deletion for agents + email request for customers). Provide the deletion URL:
  your hosted privacy policy page (it documents both paths).
- **Data shared with third parties?** → No. (WhatsApp sharing is user-initiated
  and not background data sharing; Supabase is a processor/host, not a "share".)

**Permissions to justify in the listing / review notes:**
- `READ_CONTACTS` — used only to match incoming bookings to the agent's saved
  contacts; optional; core to the matching feature. Include a prominent
  in-app disclosure before requesting it (the OS permission prompt + the
  contacts usage string cover this).

---

## Apple — App Privacy (App Store Connect)

**Data Used to Track You:** None.

**Data Linked to You** (purpose: *App Functionality* for all):
- **Contact Info → Name**
- **Contact Info → Phone Number**
- **Contacts** (the user's address book entries that get matched/stored)
- **User Content** (tours, passengers, booking details, notes)

**Data Not Linked to You:** None.

Notes for the form:
- For each item choose purpose **App Functionality** only (no Analytics, no
  Advertising, no Product Personalization, no Tracking).
- "Do you or your third-party partners use data for tracking?" → **No**.

---

## iOS permission usage strings (already in Info.plist)

- `NSContactsUsageDescription`: *"Ugam Booking matches your saved contacts to
  incoming bookings so you instantly see who booked."* ✅

If you later add any other sensitive API (camera, photos, location), add the
matching `NS…UsageDescription` or the App Store will reject the build.
