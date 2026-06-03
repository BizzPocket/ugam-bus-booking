# Admin login — how credentials are matched

The app does **not** use real email or phone-OTP auth. It maps a phone number to a
**synthetic email** and signs in with phone + password against Supabase Auth.

## The exact flow (where creds are picked & matched)

1. **Phone lookup** — `login_screen` → `AuthController.submitPhone()` →
   `AdminAuthService.findByPhone()` calls the RPC **`admin_lookup_by_phone`**, which
   looks in the **`public.admins` table** (matched on the last 10 digits of the phone).
   - Match found → the app asks for a password (admin path).
   - **No match → the number is treated as a customer and logs in with no password.**
     This is why `9727710359` "logs in without a password": it isn't being found in
     `admins`.
2. **Password sign-in** — `AuthController.verifyAdminPassword()` →
   `AdminAuthService.signIn()` calls
   `supabase.auth.signInWithPassword(email: <synthetic>, password: <typed>)`, where the
   email is built by `SupabaseConfig.phoneToSyntheticEmail()`:

   ```
   <last 10 digits of phone>@occubus.local
   e.g.  9727710359  ->  9727710359@occubus.local
   ```

So **two things must exist and agree** for an admin to log in:

| Requirement | Where | Value for 9727710359 |
|---|---|---|
| Auth user | Supabase **Authentication → Users** | email `9727710359@occubus.local`, your password, **confirmed** |
| Admin row | `public.admins` table | `id` = that auth user's UID, `phone` = `9727710359` |

If you created an auth user with your **real email** (or via phone provider), the app's
`signInWithPassword('9727710359@occubus.local', …)` won't match it — that's the
"cred not working" symptom.

> The same missing/mismatched admin session is also why you **can't create a bus**
> (`buses.owner_id` is `NOT NULL` and RLS requires `owner_id = auth.uid()`) and why
> **realtime requests don't sync** (the realtime channel only subscribes for an
> authenticated admin UID).

## Fix it

### 1. Create the auth user (Dashboard — recommended)
Authentication → Users → **Add user**:
- Email: `9727710359@occubus.local`
- Password: *(your choice)*
- **Auto Confirm User: ON**

(Use the synthetic email exactly — no real mailbox is needed.)

### 2. Link it in the `admins` table (SQL editor)
```sql
insert into public.admins (id, phone, name)
select id, '9727710359', 'Ugam Admin'
from auth.users
where email = '9727710359@occubus.local'
on conflict (id) do update
  set phone = excluded.phone,
      name  = excluded.name;
```

### 3. Apply the lookup-hardening migration
Run `supabase/migrations/002_admin_lookup_normalize.sql` once. It makes
`admin_lookup_by_phone` match on the **last 10 digits of both** the typed and the stored
phone, so an admin whose phone was saved as `+91 97277 10359` is still recognised.

## After this
- `9727710359` is recognised as an admin → login **requires the password**.
- The admin sees **only their own tours**; customers still see **all** public tours.
- The admin can **create buses** (authenticated session supplies `owner_id`).
- Booking requests **sync live across that admin's devices** (no manual refresh) —
  the realtime channel subscribes automatically once signed in.
