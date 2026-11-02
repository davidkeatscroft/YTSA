#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) YTSA.app and a shareable dist/YTSA.zip.
#
# Signing:
#   ./build.sh                                   ad-hoc signed (no Apple Developer account needed)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh
#                                                signed with your Developer ID certificate
#   SIGN_ID=... NOTARY_PROFILE=ytsa ./build.sh   also notarized and stapled, so it opens on any Mac
#                                                without warnings. Create the profile once with:
#                                                xcrun notarytool store-credentials ytsa
set -euo pipefail
cd "${0:A:h}"

SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP=YTSA.app

for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0"
done

rm -rf "$APP" dist
mkdir -p "$APP/Contents/MacOS" dist
lipo -create \
  .build/arm64-apple-macosx/release/YTSA \
  .build/x86_64-apple-macosx/release/YTSA \
  -output "$APP/Contents/MacOS/YTSA"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>YTSA</string>
  <key>CFBundleDisplayName</key><string>YTSA</string>
  <key>CFBundleIdentifier</key><string>com.ytsa.app</string>
  <key>CFBundleExecutable</key><string>YTSA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" dist/YTSA.zip

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit dist/YTSA.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/YTSA.zip
  ditto -c -k --keepParent "$APP" dist/YTSA.zip
fi

echo "Built $(pwd)/$APP"
echo "Share  $(pwd)/dist/YTSA.zip"
