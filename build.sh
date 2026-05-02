#!/usr/bin/env bash
set -euo pipefail

# Builds EGOMac in release mode and wraps the binary into a proper .app bundle
# with LSUIElement=true (so it lives in the menu bar, not the Dock).

cd "$(dirname "$0")"

APP_NAME="EGO Mac"
BUNDLE_ID="dev.local.egomac"
BUNDLE_VERSION="1.0"

echo "▸ Building EGOMac (release)…"
swift build -c release

BINARY=".build/release/EGOMac"
if [[ ! -f "$BINARY" ]]; then
  echo "✗ Build failed — binary not found at $BINARY" >&2
  exit 1
fi

# Build the .icns if it doesn't exist (or if its source PNG is newer).
if [[ ! -f "assets/AppIcon.icns" \
     || "assets/icon-1024.png" -nt "assets/AppIcon.icns" ]]; then
  echo "▸ Rebuilding app icon…"
  bash scripts/build-icon.sh
fi

APP_DIR="$APP_NAME.app"
echo "▸ Wrapping into ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/EGOMac"
chmod +x "$APP_DIR/Contents/MacOS/EGOMac"

# Drop the icon in.
if [[ -f "assets/AppIcon.icns" ]]; then
  cp "assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>EGOMac</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>EGO Mac — kişisel kullanım</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS doesn't quarantine-block on first launch from Finder.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo
echo "✓ Built: $PWD/$APP_DIR"
echo
echo "Sıradaki adımlar:"
echo "  1. Aç:           open \"${APP_DIR}\""
echo "  2. Yükle:        cp -R \"${APP_DIR}\" /Applications/"
echo "  3. Login Items:  Sistem Ayarları → Genel → Giriş Öğeleri → +"
echo "  4. Yapılandır:   ~/.ego-mac/config.json"
