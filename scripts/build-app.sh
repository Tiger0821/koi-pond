#!/bin/bash
# Builds "Koi Pond.app" (with the KoiPond.saver screen saver inside it), signs both ad hoc and installs the app
# in /Applications, quitting and reopening a running copy. `--no-install` stops after building, leaving it in
# $TMPDIR/koipond-build.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
# Put together in the temporary folder, outside the project: on a Desktop kept in iCloud, iCloud Drive tags
# and touches new bundles (leaving "KoiPond 2.app" conflict copies, and Finder data that breaks code signing),
# and Spotlight would list a second copy of the app.
STAGE="${TMPDIR:-/tmp}"
STAGE="${STAGE%/}/koipond-build"
APP="$STAGE/Koi Pond.app"
SAVER="$STAGE/KoiPond.saver"

rm -rf "$STAGE"
mkdir -p "$STAGE"

# The icon: the charging pixel koi, drawn by the app itself at 1024 pixels and scaled down for the smaller sizes.
"$BIN_DIR/KoiPond" --app-icon "$STAGE/icon-1024.png" --style charge
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$STAGE/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$STAGE/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/AppIcon.icns"

# Screen saver bundle: the dynamic library becomes the bundle executable.
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp "$BIN_DIR/libKoiPondSaver.dylib" "$SAVER/Contents/MacOS/KoiPondSaver"
cp "$STAGE/AppIcon.icns" "$SAVER/Contents/Resources/AppIcon.icns"
cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KoiPondSaver</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.koifishwallpaper.koipond.saver</string>
    <key>CFBundleName</key>
    <string>Koi Pond</string>
    <key>CFBundleDisplayName</key>
    <string>Koi Pond</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>102</string>
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
cp "$STAGE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SAVER" "$APP/Contents/Resources/KoiPond.saver"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KoiPond</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.koifishwallpaper.koipond</string>
    <key>CFBundleName</key>
    <string>Koi Pond</string>
    <key>CFBundleDisplayName</key>
    <string>Koi Pond</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>102</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
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

if [[ $INSTALL == 0 ]]; then
    echo "Built $APP"
    exit 0
fi
DEST="/Applications/Koi Pond.app"
RUNNING=0
if pgrep -x KoiPond >/dev/null; then
    RUNNING=1
    pkill -x KoiPond || true
    while pgrep -x KoiPond >/dev/null; do sleep 0.1; done
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
if [[ $RUNNING == 1 ]]; then open "$DEST"; fi
