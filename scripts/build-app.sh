#!/bin/bash
# Builds build/KoiPond.app (with the KoiPond.saver screen saver inside it) and signs both ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/KoiPond.app"
SAVER="build/KoiPond.saver"

rm -rf "$APP" "$SAVER"

# Screen saver bundle: the dynamic library becomes the bundle executable.
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp "$BIN_DIR/libKoiPondSaver.dylib" "$SAVER/Contents/MacOS/KoiPondSaver"
cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KoiPondSaver</string>
    <key>CFBundleIdentifier</key>
    <string>com.koifishwallpaper.koipond.saver</string>
    <key>CFBundleName</key>
    <string>Koi Pond</string>
    <key>CFBundleDisplayName</key>
    <string>Koi Pond</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>100</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>KoiPondSaverView</string>
</dict>
</plist>
PLIST
# Thumbnails for the screen saver picker, rendered from the pond itself.
"$BIN_DIR/KoiPond" --snapshot "$SAVER/Contents/Resources/thumbnail-full.png" --weather sunny --scale 0.4 --seconds 6 >/dev/null
sips -z 116 180 "$SAVER/Contents/Resources/thumbnail-full.png" --out "$SAVER/Contents/Resources/thumbnail@2x.png" >/dev/null
sips -z 58 90 "$SAVER/Contents/Resources/thumbnail-full.png" --out "$SAVER/Contents/Resources/thumbnail.png" >/dev/null
rm "$SAVER/Contents/Resources/thumbnail-full.png"
# sips leaves Finder metadata on its output, which codesign refuses to seal.
xattr -cr "$SAVER"
codesign --force --sign - "$SAVER"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KoiPond" "$APP/Contents/MacOS/KoiPond"
cp -R "$SAVER" "$APP/Contents/Resources/KoiPond.saver"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KoiPond</string>
    <key>CFBundleIdentifier</key>
    <string>com.koifishwallpaper.koipond</string>
    <key>CFBundleName</key>
    <string>Koi Pond</string>
    <key>CFBundleDisplayName</key>
    <string>Koi Pond</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>100</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Koi Pond listens to the music playing in Music so the fish can dance to its beat. Nothing is recorded or saved.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Koi Pond shows the song playing in Music on your desktop, with its cover, and lets you play, pause and skip from there.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
