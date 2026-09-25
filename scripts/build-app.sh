#!/bin/bash
# Builds "PDF to EPUB.app" into ./dist.
#
#   scripts/build-app.sh            # for this Mac's processor
#   scripts/build-app.sh universal  # Apple silicon + Intel (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PDF to EPUB"
BUNDLE_ID="com.writingpoli.pdf-to-epub"
VERSION="${VERSION:-1.0.0}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

if [[ "${1:-}" == "universal" ]]; then
  swift build -c release --product PDFToEPUB --arch arm64 --arch x86_64
  swift build -c release --product pdf2epub --arch arm64 --arch x86_64
  BIN_DIR=".build/apple/Products/Release"
else
  swift build -c release --product PDFToEPUB
  swift build -c release --product pdf2epub
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PDFToEPUB" "$APP/Contents/MacOS/PDFToEPUB"
# The command-line tool rides along inside the app for anyone who wants it.
cp "$BIN_DIR/pdf2epub" "$APP/Contents/Resources/pdf2epub"

ICON_KEY=""
if swift scripts/make-icon.swift "$DIST/AppIcon.iconset" >/dev/null 2>&1 \
   && iconutil -c icns "$DIST/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "note: couldn't make the app icon; using the default one" >&2
fi
rm -rf "$DIST/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>PDFToEPUB</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
  $ICON_KEY
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so it runs on Apple silicon. Not notarized: see README.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
