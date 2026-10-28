#!/bin/bash
# Archives Waldenlog for iOS, uploads it to App Store Connect, and adds the build
# to the internal TestFlight group "Captain" after processing.
# Signs and uploads with the App Store Connect API key only, never the Xcode account.
#
# Usage:  scripts/testflight.sh
#         BUILD=432700 scripts/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_9J2RG4JQ3K.p8}
export ASC_KEY_ID=${ASC_KEY_ID:-9J2RG4JQ3K}
export ASC_ISSUER_ID=${ASC_ISSUER_ID:-a094cf6f-56a0-4812-9864-1ccc1f355432}
TEAM=3DVDQLT8CC
# The key has no access to cloud-managed certificates, so the export signs with the
# local Apple Distribution certificate and the "Waldenlog App Store" and
# "Pond Widget App Store" profiles. Both App IDs have the App Group group.org.teoyujie.pond.
# Each upload needs a new, higher build number: the minutes since 1 January 2026 (UTC).
BUILD=${BUILD:-$(( ($(date +%s) - 1767225600) / 60 ))}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/pond-testflight.XXXXXX")
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>org.teoyujie.pond</key><string>Waldenlog App Store</string>
		<key>org.teoyujie.pond.widget</key><string>Pond Widget App Store</string>
	</dict>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "== archive (build $BUILD)"
xcodebuild archive \
  -project app/Pond.xcodeproj -scheme Pond -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Pond.xcarchive" \
  "${AUTH[@]}" CURRENT_PROJECT_VERSION="$BUILD" \
  > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; echo "Archive failed. See $OUT/archive.log"; exit 1; }

echo "== upload"
xcodebuild -exportArchive \
  -archivePath "$OUT/Pond.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" "${AUTH[@]}" \
  > "$OUT/upload.log" 2>&1 || { tail -30 "$OUT/upload.log"; echo "Upload failed. See $OUT/upload.log"; exit 1; }

echo "== wait for processing, then put the build in the group Captain"
python3 -I scripts/testflight_group.py "$BUILD" Captain
echo "Logs: $OUT"
