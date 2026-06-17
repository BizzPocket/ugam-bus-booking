#!/usr/bin/env bash
# ============================================================================
# WhatsApp Cloud API — send ONE test message per template, through the live
# `quick-action` Edge Function (the same path the app uses).
#
# It signs you in as an admin (admins use a synthetic email: <phone>@occubus.local),
# then fires one templated message per template to a recipient you choose, and
# prints Meta's exact per-recipient result for each — so you can see immediately
# whether each template name / language / variable-count / header matches what
# you approved in Meta. A rejection here IS the useful output.
#
# Usage:
#   RECIPIENT=919876543210 ADMIN_PHONE=9876500000 ./scripts/wa_test.sh
#   (you'll be prompted for the admin password; nothing is stored)
#
# Optional env:
#   IMG_URL   public PNG used as the seat_allotment image header
#             (default: a placeholder; replace with a real seat-chart URL to test fully)
#   LANG_CODE template language (default: gu)
# ============================================================================
set -euo pipefail

URL="https://rhyqjzulpvaeslbaymex.supabase.co"
ANON="sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP"
LANG_CODE="${LANG_CODE:-gu}"
IMG_URL="${IMG_URL:-https://placehold.co/800x1000.png}"

RECIPIENT="${RECIPIENT:-}"
ADMIN_PHONE="${ADMIN_PHONE:-}"

[ -z "$RECIPIENT" ]   && read -r -p "Recipient WhatsApp number (country code + number, digits only, e.g. 919876543210): " RECIPIENT
[ -z "$ADMIN_PHONE" ] && read -r -p "Your admin phone (the one you log into the app with): " ADMIN_PHONE
read -r -s -p "Admin password: " ADMIN_PASS; echo

# Admins authenticate with a synthetic email built from the last 10 digits.
ADMIN_DIGITS="$(printf '%s' "$ADMIN_PHONE" | tr -cd '0-9')"
ADMIN_EMAIL="${ADMIN_DIGITS: -10}@occubus.local"

echo "→ Signing in as $ADMIN_EMAIL ..."
TOKEN="$(curl -sS "$URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')"

if [ -z "$TOKEN" ]; then
  echo "✗ Sign-in failed — check the admin phone/password. Aborting." >&2
  exit 1
fi
echo "✓ Signed in."

send() {
  local label="$1" payload="$2"
  echo
  echo "──────── $label ────────"
  curl -sS "$URL/functions/v1/quick-action" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" | python3 -m json.tool || echo "(non-JSON response)"
}

# 1) seat_allocation — PRE-LOCK greeting (static header, 2 body vars)
send "seat_allocation (confirm greeting)" "$(cat <<JSON
{"messages":[{"to":"$RECIPIENT","template":"seat_allocation","language":"$LANG_CODE","bodyParams":["Test User","Test Tour"]}]}
JSON
)"

# 2) seat_allotment — AFTER-LOCK (IMAGE header + 7 body vars)
send "seat_allotment (allocation + image)" "$(cat <<JSON
{"messages":[{"to":"$RECIPIENT","template":"seat_allotment","language":"$LANG_CODE","headerImageUrl":"$IMG_URL","bodyParams":["Test User","Test Tour","GJ05HU7162","Rajkot, Limda Chowk","13 Jun 2026","6:00","Mahesh - 9876543210"]}]}
JSON
)"

# 3) bus_msg — per-bus free text (1 body var)
send "bus_msg (per-bus message)" "$(cat <<JSON
{"messages":[{"to":"$RECIPIENT","template":"bus_msg","language":"$LANG_CODE","bodyParams":["This is a test bus message."]}]}
JSON
)"

echo
echo "Done. For each block above: \"ok\": true = Meta accepted it; an \"error\" string = Meta's rejection reason (use it to fix the template name / language / variables / header)."
