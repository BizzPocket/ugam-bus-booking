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
