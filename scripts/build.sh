#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$(pwd)/dist/Jev Launcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/JevLauncher" "$APP/Contents/MacOS/JevLauncher"
# macOS 26 draws the Icon Composer bundle as a Liquid Glass icon. actool also writes an
# AppIcon.icns fallback for older systems. Without actool (no Xcode), ship the static .icns.
rm -f "$APP/Contents/Resources/Assets.car"
if [ -d Resources/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
  ICON_OUT="$(mktemp -d)"
  xcrun actool "$(pwd)/Resources/AppIcon.icon" --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --target-device mac --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
  cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
  rm -rf "$ICON_OUT"
else
  echo "actool not found; using Resources/AppIcon.icns" >&2
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ryanerkal.jevlauncher</string>
<key>CFBundleName</key><string>Jev Launcher</string>
<key>CFBundleDisplayName</key><string>Jev Launcher</string>
<key>CFBundleExecutable</key><string>JevLauncher</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSApplicationSupportsSecureRestorableState</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Ryan Erkal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Transcribe your voice while the launcher is open. Audio is not saved.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn spoken launcher commands into text using on-device speech recognition.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -f "$APP/Contents/Resources/Assets.car" ]; then
  plutil -insert CFBundleIconName -string AppIcon "$APP/Contents/Info.plist"
fi
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --entitlements scripts/entitlements.plist "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
