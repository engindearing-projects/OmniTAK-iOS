#!/usr/bin/env bash
# release-ios.sh — one-command iOS TestFlight release.
#
# Steps: auto-pick next OPEN train + build number → archive → export a
# distribution-signed .ipa → (if ASC issuer configured) validate + upload
# to TestFlight. Run from the repo root on the branch you want to ship.
#
#   ./scripts/release-ios.sh            # full flow
#   ./scripts/release-ios.sh --no-upload  # stop after producing the .ipa
#
# Auth for the version query + upload comes from ~/.appstoreconnect/config.json
# ({ keyId, issuerId, bundleId }) or ASC_* env vars; the .p8 lives in
# ~/.appstoreconnect/private_keys/AuthKey_<keyId>.p8.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="OmniTAKMobile"
PROJECT="OmniTAK.xcodeproj"
ARCHIVE="/tmp/OmniTAK.xcarchive"
EXPORT_DIR="/tmp/OmniTAK-export"
NO_UPLOAD="${1:-}"

CFG="$HOME/.appstoreconnect/config.json"
KEY_ID="${ASC_KEY_ID:-$( [ -f "$CFG" ] && /usr/bin/plutil -extract keyId raw "$CFG" 2>/dev/null || true )}"
ISSUER_ID="${ASC_ISSUER_ID:-$( [ -f "$CFG" ] && /usr/bin/plutil -extract issuerId raw "$CFG" 2>/dev/null || true )}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"

echo "==> 1/4 Auto-pick next open train"
node scripts/bump-ios-version.mjs

VER=$(grep -m1 -oE 'MARKETING_VERSION = [0-9.]+;' "$PROJECT/project.pbxproj" | grep -oE '[0-9.]+')
BUILD=$(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PROJECT/project.pbxproj" | grep -oE '[0-9]+')
echo "    -> $VER ($BUILD)"

echo "==> 2/4 Archive (Release, distribution signing)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -scheme "$SCHEME" -project "$PROJECT" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" archive \
  -allowProvisioningUpdates >/tmp/ios-archive.log 2>&1 || { echo "archive failed — see /tmp/ios-archive.log"; tail -20 /tmp/ios-archive.log; exit 1; }
echo "    -> archived"

echo "==> 3/4 Export App Store .ipa"
cat > /tmp/exportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>4HSANV485G</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist /tmp/exportOptions.plist -allowProvisioningUpdates >/tmp/ios-export.log 2>&1 || { echo "export failed — see /tmp/ios-export.log"; tail -20 /tmp/ios-export.log; exit 1; }
IPA="$EXPORT_DIR/$SCHEME.ipa"
OUT="$HOME/OmniTAK-${VER}-${BUILD}.ipa"
cp "$IPA" "$OUT"
echo "    -> $OUT"

if [ "$NO_UPLOAD" = "--no-upload" ]; then
  echo "==> done (--no-upload). Upload $OUT via Transporter or rerun without the flag."
  exit 0
fi

if [ -z "$ISSUER_ID" ] || [ ! -f "$KEY_PATH" ]; then
  echo "==> 4/4 Upload SKIPPED — no ASC issuerId/key configured."
  echo "    Add issuerId to ~/.appstoreconnect/config.json, then:"
  echo "    xcrun altool --upload-app -f \"$OUT\" -t ios --apiKey ${KEY_ID:-<keyId>} --apiIssuer <issuerId>"
  echo "    (or drag $OUT into Transporter.)"
  exit 0
fi

echo "==> 4/4 Validate + upload to TestFlight"
xcrun altool --validate-app -f "$OUT" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"
xcrun altool --upload-app   -f "$OUT" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"
echo "✓ uploaded $VER ($BUILD) — it'll appear in TestFlight after Apple processing."
