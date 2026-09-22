#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$(pwd)/dist/Jev Launcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/JevLauncher" "$APP/Contents/MacOS/JevLauncher"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ryanerkal.jevlauncher</string>
<key>CFBundleName</key><string>Jev Launcher</string>
<key>CFBundleDisplayName</key><string>Jev Launcher</string>
<key>CFBundleExecutable</key><string>JevLauncher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Transcribe your voice while the launcher is open. Audio is not saved.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn spoken launcher commands into text using on-device speech recognition.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --entitlements scripts/entitlements.plist "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
