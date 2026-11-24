#!/usr/bin/env bash
# Builds a universal SideStats.app (and a .dmg with --dmg) into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
[ -z "$VERSION" ] && VERSION=0.1.0
APP=dist/SideStats.app

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SideStats"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SideStats"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SideStats</string>
  <key>CFBundleDisplayName</key><string>SideStats</string>
  <key>CFBundleIdentifier</key><string>app.sidestats.SideStats</string>
  <key>CFBundleExecutable</key><string>SideStats</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.business</string>
</dict></plist>
PLIST

# Ad-hoc sign by default; set SIGN_IDENTITY="Developer ID Application: ..." to sign for notarization.
codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"

if [[ "${1:-}" == "--dmg" ]]; then
  rm -f dist/SideStats.dmg
  STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname SideStats -srcfolder "$STAGE" -ov -format UDZO dist/SideStats.dmg >/dev/null
  rm -rf "$STAGE"
  echo "Built dist/SideStats.dmg"
fi
