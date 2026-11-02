#!/bin/zsh
# Builds YTSA.app next to this script.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP=YTSA.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/YTSA "$APP/Contents/MacOS/YTSA"

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
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
