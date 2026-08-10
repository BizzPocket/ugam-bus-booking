# What is published to the OTA buckets

These files are the **source of truth for what is live**. Edit here, commit,
then upload — so the repo always says what every installed client is being
told. A flag flipped only in the dashboard is a change nobody can review, and
in six months nobody will know why the app is in maintenance mode.

Buckets are created by `supabase/migrations/078_ota_config_buckets.sql`.
Endpoints are compiled into the app from `config/ota.json`.

| Local file | Bucket | Object |
| --- | --- | --- |
| `flags.json` | `app-config` | `flags.json` |
| `content.json` | `app-config` | `content.json` |
| `i18n/<lang>.json` | `i18n` | `<lang>.json` |

Upload via the Supabase dashboard (Storage → bucket → Upload, overwrite) or
the CLI with the **service** key. Only the service role may write; the app
cannot, deliberately.

---

## flags.json

Every field is optional and every default is the "nothing is wrong" value, so
`{}` is valid and harmless. A malformed document is ignored by the client and
the last good copy is kept.

| Field | Effect |
| --- | --- |
| `min_supported_build` | Builds strictly below this are **blocked**. `0` blocks nobody. |
| `recommended_build` | Builds below this get a dismissible nudge. `0` nudges nobody. |
| `maintenance_mode` | `true` covers the app for everyone. Outranks the version gate. |
| `kill.<feature>` | `true` disables that feature. Absent means on. |
| `tunables.<name>` | Numeric knobs. See below. |

Recognised tunables:

| Name | Effect | Bounds |
| --- | --- | --- |
| `http_timeout_seconds` | Deadline on every Supabase request | clamped 5–120; anything else ignored |

### Before you set `min_supported_build`

It is compared against `build_number`, not the version name. Check what is
actually live first — a floor above every shipped build locks out **everyone**,
and the only way back is editing this file, which a blocked user never reads.

Raise `recommended_build` first, watch, then raise the floor.

### Reach

Changes land on the **next foreground**, bounded by a 15-minute client-side
throttle and served with an ETag so an unchanged document transfers no body. A
cold start always checks. Nothing on the boot path waits for it — an
unreachable bucket means the app runs on its cached or compiled-in defaults.

---

## content.json — server-driven content, deliberately narrow

Drives the content slot at the top of the customer tour list. Notices, promos,
a link to something. **It is not a UI language.** The seat chart, every money
surface and the whole handler flow are native code and stay that way, because
they encode correctness a JSON document cannot express and no test can cover.

The server picks which of three compiled-in block types to show and what text
goes in it. It cannot introduce a widget, a layout or an interaction.

```json
{
  "blocks": [
    {
      "type": "notice",
      "tone": "info",
      "title": "Monsoon timings",
      "body": "Departures move 30 minutes later from 1 July."
    },
    {
      "type": "banner",
      "image_url": "https://example.com/promo.png",
      "title": "Diwali specials",
      "body": "Six routes, booking open now."
    },
    {
      "type": "link",
      "title": "My bookings",
      "action": "route",
      "action_target": "my_bookings"
    }
  ]
}
```

### Block types

| Type | Renders | Requires |
| --- | --- | --- |
| `notice` | Text with a coloured left rule | title or body |
| `banner` | 16:9 image with optional title and body | image, title or body |
| `link` | A row with a chevron | title or body |
| `cta` | A full-width primary button | `title` |
| `faq` | Collapsed expander; `body` is the answer | `title` |
| `stat` | Large figure with label and optional secondary | `value` |
| `divider` | A rule. The only type allowed to carry no content | — |

`tone` (`neutral`, `info`, `warn`, `danger`) colours the `notice` rule and the
`stat` figure. `order` sorts ascending within a slot; ties keep document order.

**`stat.value` is a string and is rendered verbatim.** It is deliberately not
computed on device — a server-supplied figure the app also calculated would be
a second source of truth for a number, which is the exact class of bug that
cost this app a week. Use it for editorial figures, never for money the app
already knows.

### Slots

Every surface has one. `surface.screen.position`.

| Slot | Where |
| --- | --- |
| `customer.tour_list.top` | above the tour list — the default when no slot is named |
| `customer.tour_list.empty` | when there are no tours |
| `customer.tour_detail.top` | above a tour's detail |
| `customer.my_requests.top` | above the bookings list |
| `customer.my_requests.empty` | **when a customer has no bookings — the best audience in the app** |
| `customer.more.top` | above the More menu |
| `handler.chart.top` | above the handler's bus chart — depot notices, pickup changes |
| `admin.home.top` | above the operator's home |
| `admin.tour_detail.top` | above a tour's admin detail |
| `admin.money.top` | above the money board |

An unknown slot is **dropped**, not defaulted — otherwise a block written for a
future screen would land on the customer home page.

### Targeting — the `when` block

Every field is optional; omitted means no restriction. All of it is evaluated
on-device against values the app already has, so targeting costs no extra
round trip and works offline.

| Field | Effect |
| --- | --- |
| `platforms` | `["android"]`, `["ios"]` |
| `min_build` / `max_build` | inclusive build-number window |
| `locales` | `["gu"]`, `["en","hi"]` |
| `roles` | `["customer"]`, `["handler"]`, `["admin"]` |
| `from` / `to` | UTC ISO-8601. `to` is **exclusive** |

```json
"when": { "platforms": ["android"], "max_build": 25 }
```

That one shows a notice to exactly the builds carrying a bug, and it vanishes
by itself as people update — no follow-up edit.

`from`/`to` is what makes a promo schedulable: publish once, it appears and
retires on its own.

An **unreadable build number passes any build window**. `AppInfo` leaves an
empty string when `PackageInfo` fails, and a device that cannot report its
version must not silently lose content.

| Action | Meaning |
| --- | --- |
| *(omitted)* | Inert |
| `url` | Opens an external **https** URL. `http`, app schemes and `javascript:` are refused at parse time |
| `route` | One of a **whitelist** — currently `my_bookings`, `home`. The name is remote; the destination is compiled in |

Rules worth knowing, all enforced by the parser and covered by tests:

- **Unknown block types are skipped, not errors.** An older build ignores a
  block it was never taught, so you can publish for the newest build without
  breaking older ones.
- **One malformed block does not cost the others.** The rest of the document
  still renders.
- **A block with no title, body or image is dropped** — no empty rows.
- **`{"blocks": []}` is the off switch**, and it reaches every installed
  client.
- Nothing here blocks first paint. No content, no cache, or an unreachable
  bucket all render the screen exactly as it was before the feature existed.

### Why the whitelist matters

Without it, a content document could route a user into any screen in the app —
that is a remote navigation primitive, not content. To add a destination, add
it to `_allowedRoutes` in `lib/components/content_block_view.dart` and ship a
build. That friction is the point.

---

## i18n/<lang>.json

A **delta** of changed keys only, merged over the bundled catalogue. Not the
whole file. Capped at 64KB — anything larger is refused by the client.

```json
{
  "launch_block": {
    "maintenance_body": "Back by 6pm."
  }
}
```

Nested keys merge leaf by leaf: the example above replaces exactly that one
string and leaves the rest of `launch_block` alone.

The bundled `assets/translations/` catalogue stays in `pubspec.yaml`
permanently as the offline floor, so a first install with no network still
shows real copy. Deltas apply on the **next launch**, never mid-session.

---

## It does not work until a build ships with the endpoints

`config/ota.json` is compiled in via `--dart-define-from-file`. Installs made
before that build have no OTA code at all and will never read these files.

Verify an endpoint is live with no credentials — from a terminal, not the
dashboard, which is authenticated and would prove nothing:

```
curl -i https://rhyqjzulpvaeslbaymex.supabase.co/storage/v1/object/public/app-config/flags.json
```

`200` with the body means live. `NoSuchKey` means the bucket is fine and the
file is not uploaded. `NoSuchBucket` means `078` has not been applied.
