# WhatsApp Inbox — deploy & Meta setup

Turns the Cloud API business number into a **two-way** channel: inbound customer
messages land in the in-app Inbox (per-owner), and agents reply from the app.

Pieces: migration `033_whatsapp_inbox.sql`, Edge Functions `wa-webhook` (inbound)
and `wa-reply` (outbound), plus the extended `send-push` (new `wa_message` push).

Do these **in order**. Steps 1–4 are one-time; step 5 is how you verify.

---

## 1. Database

Run `supabase/migrations/033_whatsapp_inbox.sql` **in the Supabase SQL editor**
(paste the whole file and Run). Do **not** `supabase db push` — the live schema
diverges from the numbered migration history, so a push would replay the old
pre-owner-model schema. The file is idempotent, so re-running is safe.

It creates `wa_conversations` + `wa_messages`, the `wa_resolve_owner` /
`wa_mark_read` RPCs, RLS (owner-scoped + unassigned), and adds both tables to the
`supabase_realtime` publication (the app subscribes for live updates).

## 2. Secrets

Two are **new**; the rest you already set for the existing WhatsApp/push functions.

```bash
# NEW — pick any strong random string; you'll type the same value into Meta (step 4).
supabase secrets set WHATSAPP_WEBHOOK_VERIFY_TOKEN="<random-string>"

# NEW — Meta App Secret (Meta App → Settings → Basic → App Secret). Enables the
# x-hub-signature-256 check so only Meta can post to the webhook. Strongly
# recommended; if unset the webhook still works but skips signature verification.
supabase secrets set WHATSAPP_APP_SECRET="<meta-app-secret>"

# Already set (shared with bus-message / quick-action / send-push) — confirm:
#   WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, PUSH_TRIGGER_SECRET
```

## 3. Deploy the functions

```bash
supabase functions deploy wa-webhook --no-verify-jwt   # Meta has no JWT — MUST be --no-verify-jwt
supabase functions deploy wa-reply                     # admin app sends its JWT (verify_jwt ON)
supabase functions deploy send-push --no-verify-jwt    # REDEPLOY — now also handles wa_message pushes
```

The webhook URL is:
`https://<your-project-ref>.supabase.co/functions/v1/wa-webhook`

## 4. Point Meta at the webhook

In **Meta App dashboard → WhatsApp → Configuration → Webhook**:

1. **Callback URL** = the `wa-webhook` URL above.
2. **Verify token** = the exact `WHATSAPP_WEBHOOK_VERIFY_TOKEN` from step 2.
3. Click **Verify and save** — Meta does a GET handshake; the function echoes the
   challenge. If it fails, the token doesn't match or the function wasn't deployed
   with `--no-verify-jwt`.
4. Under **Webhook fields**, **Subscribe** to **`messages`**. (This one field
   covers inbound messages *and* delivery-status receipts.)

> The `bus_msg` template must stay **approved** in Meta — replies sent after the
> 24-hour window fall back to it automatically.

## 5. Verify end-to-end

1. From a phone that is **not** the business number, send a WhatsApp message to the
   business number.
2. Within a second or two it should appear in the app's **Inbox** (chat icon on the
   Home header, and a card on the Dashboard when unread), and you should get a push.
   - Not showing? Check `supabase functions logs wa-webhook`. A row should be
     written to `wa_conversations` / `wa_messages`.
   - Landed as **unassigned** (no push)? That number matches no booking yet —
     `wa_resolve_owner` couldn't map it to an owner. It's still visible to admins
     in the Inbox; replying claims it.
3. Open the thread and reply. Within 24h of the customer's message it sends as a
   free-text **session** message; after 24h it auto-sends via the `bus_msg`
   template. The reply appears right-aligned in the thread.

---

## Notes / deferred

- **Media**: images/documents a customer sends are recorded as a `📷 Photo` /
  `📎 Document` placeholder — the file itself isn't downloaded yet (fast-follow).
- **Ownership**: a thread is routed to the owner of the customer's most-recent
  tour and stays with them. Unassigned threads (unknown numbers) are visible to
  all admins until someone replies (which claims the thread).
- **Push preference**: message pushes respect the admin's master `push_enabled`
  switch (not the separate booking-requests toggle).
