#!/bin/bash
# Baut ForkSync.app und legt sie in ./build ab.
#   ./build_app.sh --install   -> zusätzlich nach /Applications
#   ./build_app.sh --release   -> notarisiert + staplet und baut build/ForkSync.dmg
# Signatur: "Developer ID Application" (falls im Schlüsselbund), sonst ad-hoc.
# Notarisierung: Zugangsdaten aus ~/.config/forksync/notary.env (NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER).
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

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" >/dev/null
  echo "Signiert: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signiert: ad-hoc (kein Developer-ID-Zertifikat gefunden)"
fi
echo "Gebaut: $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/ForkSync.app && cp -R "$APP" /Applications/ && echo "Installiert: /Applications/ForkSync.app"
fi
if [[ "${1:-}" == "--release" ]]; then
  [[ -n "$IDENTITY" ]] || { echo "Kein Developer-ID-Zertifikat gefunden"; exit 1; }
  # shellcheck disable=SC1090
  source ~/.config/forksync/notary.env
  [[ -n "${NOTARY_ISSUER:-}" ]] || { echo "NOTARY_ISSUER fehlt in ~/.config/forksync/notary.env"; exit 1; }
  ditto -c -k --keepParent "$APP" build/ForkSync.zip
  xcrun notarytool submit build/ForkSync.zip --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"
  rm -f build/ForkSync.zip build/ForkSync.dmg
  hdiutil create -volname ForkSync -srcfolder "$APP" -ov -format UDZO build/ForkSync.dmg >/dev/null
  codesign --force --timestamp --sign "$IDENTITY" build/ForkSync.dmg >/dev/null
  xcrun notarytool submit build/ForkSync.dmg --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple build/ForkSync.dmg
  spctl -a -t exec -vv "$APP" || true
  echo "Release: build/ForkSync.dmg"
fi
