#!/bin/bash
# Builds a release Reel.app into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Override with your own reverse-DNS id, e.g. BUNDLE_ID=io.github.you.reel
BUNDLE_ID="${BUNDLE_ID:-io.github.kiran-alex.reel}"
VERSION="${VERSION:-0.1.0}"

pkill -x Reel 2>/dev/null || true
swift build -c release
APP=build/Reel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Reel "$APP/Contents/MacOS/Reel"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift .
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Reel</string>
  <key>CFBundleExecutable</key><string>Reel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Copyright © 2026 Reel contributors.</string>
</dict>
</plist>
PLIST
# Sign with a stable identity so macOS keeps the Accessibility permission
# across rebuilds. Ad-hoc signatures change every build and silently lose it.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -oE '"(Apple Development|Developer ID Application)[^"]*"' | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "WARNING: ad-hoc signed. Re-grant Accessibility after every rebuild."
fi
echo "Built $APP"
