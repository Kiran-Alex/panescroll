#!/bin/bash
# Builds build/Panescroll.app.
#
# Options (environment variables):
#   BUNDLE_ID     reverse-DNS id (default io.github.kiran-alex.panescroll)
#   VERSION       version string (default 0.1.0)
#   UNIVERSAL=1   build for both Apple silicon and Intel (needs Xcode)
#   SIGN_IDENTITY codesign identity. Default: your "Apple Development" or
#                 "Developer ID" certificate if you have one, else ad-hoc.
#                 Use "-" to force ad-hoc (what public releases use, so no
#                 personal certificate name ends up in the download).
#   KEEP_RUNNING=1  don't quit a running Panescroll first
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-io.github.kiran-alex.panescroll}"
VERSION="${VERSION:-0.1.0}"

[ "${KEEP_RUNNING:-0}" = 1 ] || pkill -x Panescroll 2>/dev/null || true

if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Panescroll
else
  swift build -c release
  BIN=.build/release/Panescroll
fi

APP=build/Panescroll.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Panescroll"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift .
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Panescroll</string>
  <key>CFBundleExecutable</key><string>Panescroll</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Copyright © 2026 Panescroll contributors.</string>
</dict>
</plist>
PLIST

# A stable identity lets macOS keep the Accessibility permission across
# rebuilds; ad-hoc signatures change every build and lose it.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"(Apple Development|Developer ID Application)[^"]*"' | tr -d '"' || true)
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed. Accessibility must be granted again after each new build."
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Panescroll"))"
