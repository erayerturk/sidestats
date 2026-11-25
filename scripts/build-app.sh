#!/usr/bin/env bash
# Builds a universal SideStats.app (and a .dmg with --dmg) into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
[ -z "$VERSION" ] && VERSION=0.1.0
APP=dist/SideStats.app

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SideStats"

BINDIR="$(dirname "$BIN")"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/SideStats"
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
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
  <key>SUFeedURL</key><string>${FEED_URL:-https://github.com/erayerturk/sidestats/releases/latest/download/appcast.xml}</string>
  <key>SUPublicEDKey</key><string>Hq5evmzgE4QYlL3Ib4TSUtr98eusBGVgTACEhSDypp8=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSRemindersFullAccessUsageDescription</key><string>SideStats shows and completes your reminders in the sidebar Tasks module.</string>
  <key>NSRemindersUsageDescription</key><string>SideStats shows and completes your reminders in the sidebar Tasks module.</string>
</dict></plist>
PLIST

# Signing:
#   default            ad-hoc (local use only; Gatekeeper blocks it on other Macs)
#   SIGN_IDENTITY=...  e.g. "Developer ID Application: Your Name (TEAMID)" — required for --release
ENT=Resources/SideStats.entitlements
# Sparkle's nested helpers are signed inside-out first (no --deep).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc" "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  else
    codesign --force --timestamp=none --sign - "$item"
  fi
done
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$APP"
else
  # no hardened runtime for ad-hoc: library validation would reject the ad-hoc signed Sparkle.framework
  codesign --force --timestamp=none --entitlements "$ENT" --sign - "$APP"
fi
echo "Built $APP ($VERSION)"

MODE="${1:-}"
if [[ "$MODE" == "--dmg" || "$MODE" == "--release" ]]; then
  DMG="dist/SideStats-${VERSION}.dmg"
  rm -f "$DMG"
  STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname SideStats -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG"
fi

# --release: Developer ID sign + notarize + staple, so the DMG opens on any Mac without warnings.
# One-time setup:  xcrun notarytool store-credentials sidestats --apple-id you@example.com --team-id TEAMID
#                  (uses an app-specific password from appleid.apple.com)
if [[ "$MODE" == "--release" ]]; then
  [[ "${SIGN_IDENTITY:-}" == Developer\ ID\ Application* ]] || { echo "Set SIGN_IDENTITY to your 'Developer ID Application: …' identity" >&2; exit 1; }
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-sidestats}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  shasum -a 256 "$DMG"
  # Sparkle appcast (signed with the EdDSA key in your Keychain). Upload both files to the GitHub release.
  APPCAST_DIR=dist/appcast; mkdir -p "$APPCAST_DIR"; cp "$DMG" "$APPCAST_DIR/"
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --download-url-prefix "${DOWNLOAD_PREFIX:-https://github.com/erayerturk/sidestats/releases/download/v${VERSION}/}" \
    -o dist/appcast.xml "$APPCAST_DIR"
  echo "Release ready: $DMG + dist/appcast.xml (upload both to release v${VERSION})"
fi
