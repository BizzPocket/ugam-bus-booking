#!/usr/bin/env bash
#
# Build a release iOS IPA with a hard guarantee that no iOS-Simulator
# framework slice leaks into the device binary.
#
# WHY THIS EXISTS
# ---------------
# `objective_c.framework` is a Flutter "native asset", pulled in transitively
# by `path_provider_foundation` (a dependency of sqflite / supabase_flutter /
# shared_preferences — i.e. unavoidable). Native assets are cached under
# build/native_assets/. If a Simulator build runs first, it leaves a
# simulator-built objective_c.framework there, and a later DEVICE archive
# silently reuses it. The resulting IPA is rejected by App Store validation:
#
#     Invalid executable. The "objective_c" executable references an
#     unsupported platform in the arm64 slice. Simulator platforms aren't
#     permitted.
#
# `flutter clean` wipes that stale cache so native assets rebuild for the
# correct target. The verify step at the end is the safety net: it refuses to
# hand you an IPA if any slice is still simulator.
#
# This is NOT a package problem — it happens regardless of which contacts
# package is used. Always ship via this script (or at minimum always run
# `flutter clean` before `flutter build ipa`, and never archive right after a
# simulator run).

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> flutter clean (wipes stale build/native_assets simulator artifacts)"
flutter clean >/dev/null

echo "==> flutter build ipa"
flutter build ipa

APP="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
if [[ ! -d "$APP" ]]; then
  echo "ERROR: archived app not found at $APP" >&2
  exit 1
fi

echo "==> verifying every framework targets iOS device (not simulator)"
bad=0
bins=("$APP/Runner")
while IFS= read -r fw; do
  bins+=("$fw/$(basename "$fw" .framework)")
done < <(find "$APP/Frameworks" -maxdepth 1 -name "*.framework" 2>/dev/null)

for bin in "${bins[@]}"; do
  [[ -f "$bin" ]] || continue
  if vtool -show-build "$bin" 2>/dev/null | grep -qi "IOSSIMULATOR"; then
    echo "   ✗ SIMULATOR SLICE: $bin"
    bad=1
  else
    echo "   ✓ $(basename "$bin")"
  fi
done

if [[ "$bad" -ne 0 ]]; then
  echo "" >&2
  echo "FAILED: a simulator slice leaked in. Do NOT upload. Re-run this script." >&2
  exit 1
fi

IPA="$(find build/ios/ipa -name "*.ipa" | head -1)"
echo ""
echo "==> OK — verified device-only IPA ready:"
echo "    $IPA"
echo "    Upload via Transporter, or:"
echo "    xcrun altool --upload-app --type ios -f \"$IPA\" --apiKey <KEY> --apiIssuer <ISSUER>"
