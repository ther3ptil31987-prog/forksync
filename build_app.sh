#!/bin/bash
# Baut ForkSync.app (Release) und legt sie in ./build ab. Optional: ./build_app.sh --install
set -euo pipefail
cd "$(dirname "$0")"
APP="build/ForkSync.app"

swift build -c release
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ForkSync" "$APP/Contents/MacOS/ForkSync"

swift scripts/make_icon.swift build/icon.iconset
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/icon.iconset

# Öffentliche OAuth-Client-ID: aus Umgebung oder Datei client_id.txt (kein Geheimnis)
CLIENT_ID="${FORKSYNC_CLIENT_ID:-$(cat client_id.txt 2>/dev/null || true)}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ForkSync</string>
  <key>CFBundleDisplayName</key><string>ForkSync</string>
  <key>CFBundleIdentifier</key><string>de.steffen.forksync</string>
  <key>GitHubClientID</key><string>$CLIENT_ID</string>
  <key>CFBundleExecutable</key><string>ForkSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Gebaut: $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/ForkSync.app && cp -R "$APP" /Applications/ && echo "Installiert: /Applications/ForkSync.app"
fi
