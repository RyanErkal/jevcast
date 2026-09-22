#!/bin/bash
# Builds "dist/Jevcast.app".
#   SIGNING_IDENTITY  codesign identity. "-" (the default) signs ad hoc for a local build.
#   ARCHS             "arm64 x86_64" (the default, universal), or one architecture for a faster local build.
set -euo pipefail
cd "$(dirname "$0")/.."
# Must match Sources/JevLauncher/AppIdentity.swift. AppIdentityTests checks this.
APP_NAME="Jevcast"
BUNDLE_ID="com.ryanerkal.jevlauncher"
EXECUTABLE="JevLauncher"
source scripts/version.env
IDENTITY="${SIGNING_IDENTITY:--}"
BUILD_FLAGS=(-c release)
for arch in ${ARCHS:-arm64 x86_64}; do BUILD_FLAGS+=(--arch "$arch"); done
# SwiftPM stamps the binary with the deployment target as its SDK version, and macOS 26
# then draws standard windows in the older style. Stamp the real SDK; macOS 14 stays the minimum.
BUILD_FLAGS+=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$(xcrun --show-sdk-version)")

swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

# Assemble beside dist, then swap the finished bundle in. A running copy keeps
# its old files, so a rebuild never changes a binary under a live process.
mkdir -p dist
STAGE="$(mktemp -d dist/.stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# macOS 26 draws the Icon Composer bundle as a Liquid Glass icon. actool also writes an
# AppIcon.icns fallback for older systems. Without actool (no Xcode), ship the static .icns.
if [ -d Resources/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
  ICON_OUT="$STAGE/icon"
  mkdir -p "$ICON_OUT"
  xcrun actool "$(pwd)/Resources/AppIcon.icon" --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --target-device mac --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
  cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
else
  echo "actool not found; using Resources/AppIcon.icns" >&2
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleExecutable</key><string>$EXECUTABLE</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSApplicationSupportsSecureRestorableState</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Ryan Erkal. MIT License.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Transcribe your voice while the launcher is open. Audio is not saved.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn spoken launcher commands into text using on-device speech recognition.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -f "$APP/Contents/Resources/Assets.car" ]; then
  plutil -insert CFBundleIconName -string AppIcon "$APP/Contents/Info.plist"
fi
plutil -lint -s "$APP/Contents/Info.plist"
SIGN_FLAGS=(--force --sign "$IDENTITY" --options runtime --entitlements scripts/entitlements.plist)
# Notarization needs a secure timestamp. An ad-hoc signature cannot carry one.
if [ "$IDENTITY" != "-" ]; then SIGN_FLAGS+=(--timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"
rm -rf "dist/$APP_NAME.app"
mv "$APP" "dist/$APP_NAME.app"
printf '%s\n' "$(pwd)/dist/$APP_NAME.app"
