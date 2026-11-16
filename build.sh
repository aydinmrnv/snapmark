#!/bin/zsh
# Builds Snapmark.app from Sources/ using the Swift command-line toolchain.
set -euo pipefail
cd "$(dirname "$0")"

APP=Snapmark.app
ARCH=$(uname -m)
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Snapmark" \
  -framework Cocoa -framework Carbon -framework SwiftUI -framework ScreenCaptureKit -framework Vision

# App icon (drawn by the app itself)
"$APP/Contents/MacOS/Snapmark" --make-icon build/icon.png
ICONSET=build/Snapmark.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Snapmark.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Snapmark</string>
  <key>CFBundleDisplayName</key><string>Snapmark</string>
  <key>CFBundleIdentifier</key><string>io.github.aydinmrnv.snapmark</string>
  <key>CFBundleExecutable</key><string>Snapmark</string>
  <key>CFBundleIconFile</key><string>Snapmark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key><string>Snapmark needs to record the screen to take screenshots.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign with a designated requirement of just the bundle id, so macOS privacy
# permissions (Screen Recording / Accessibility) keep working across rebuilds.
codesign --force --deep --sign - -r='designated => identifier "io.github.aydinmrnv.snapmark"' "$APP"
echo "Built $(pwd)/$APP"

# Install to ~/Applications so the app has a stable home System Settings can find.
if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/Snapmark.app"
  mkdir -p "$HOME/Applications"
  pkill -f "Snapmark.app/Contents/MacOS/Snapmark" 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
fi
