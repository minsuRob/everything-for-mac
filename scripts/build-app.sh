#!/usr/bin/env bash
# Builds build/EFM.app from the EFMApp SwiftPM product (release), ad-hoc signed with the
# hardened runtime. Idempotent: the bundle is rebuilt from scratch on every run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="EFM"
BUNDLE_ID="com.efm.app"
VERSION="0.1.0"
BUILD_NUMBER="${EFM_BUILD_NUMBER:-1}"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> swift build -c release --product EFMApp"
swift build -c release --product EFMApp
BIN_DIR="$(swift build -c release --product EFMApp --show-bin-path)"
BIN="$BIN_DIR/EFMApp"
[[ -x "$BIN" ]] || { echo "error: $BIN not found" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>EFM — instant file-name search</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "==> done: $APP"
