#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="VoiceKey.app"
# Stamp the build so the running app can say which commit it came from.
VERSION="${VOICEKEY_VERSION:-1.0}"
COMMIT="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
BUILT="$(date +%Y-%m-%d)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VoiceKey</string>
  <key>CFBundleExecutable</key><string>VoiceKey</string>
  <key>CFBundleIdentifier</key><string>local.voicekey</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>VKCommit</key><string>$COMMIT</string>
  <key>VKBuildDate</key><string>$BUILT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  
  <key>NSMicrophoneUsageDescription</key><string>VoiceKey records your voice to transcribe it into text.</string>
</dict></plist>
PLIST

[ -f AppIcon.icns ] || { swift MakeIcon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns; }
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O main.swift Core.swift Log.swift L.swift AI.swift History.swift HUD.swift Settings.swift Stats.swift Account.swift MainWindow.swift Setup.swift SelfTest.swift -o "$APP/Contents/MacOS/VoiceKey" \
  -framework Cocoa -framework AVFoundation -framework SwiftUI

# Ad-hoc sign so macOS keeps the granted permissions across rebuilds.
# Sign with a real certificate, not ad-hoc. An ad-hoc signature has no cert, so TCC
# identifies the app by its cdhash — which changes every build, silently voiding the
# Accessibility grant. A cert makes the identity stable across rebuilds.
IDENTITY="${VOICEKEY_IDENTITY:-$(security find-identity -v -p codesigning \
    | grep -m1 -o '"[^"]*"' | tr -d '"')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "warning: no signing certificate found; falling back to ad-hoc." >&2
  echo "         You will have to re-approve Accessibility after every build." >&2
  codesign --force --deep --sign - "$APP"
fi

echo "Built $APP — open it with: open $APP"
