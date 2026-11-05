#!/bin/bash
# Builds Koi Pond and packs it into build/KoiPond.dmg: a window with Koi Pond on the left, the Applications
# shortcut on the right and a big arrow between them on a pixel-art pond (drawn by the app: --dmg-background),
# with the koi as the disk's icon. The name carries no version, so the README's link
# (releases/latest/download/KoiPond.dmg) always downloads the newest release.
#
# Finder lays the window out (it alone writes the .DS_Store that holds icon places and the background), so
# the first run asks once to let this Terminal control Finder, and a window opens for a moment.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh --no-install
BIN_DIR="$(swift build -c release --show-bin-path)"
STAGE="${TMPDIR:-/tmp}"
STAGE="${STAGE%/}/koipond-build"
ROOT="$STAGE/dmg"
RW="$STAGE/KoiPond-rw.dmg"
rm -rf "$ROOT" "$RW"
mkdir -p "$ROOT/.background" build
ditto "$STAGE/Koi Pond.app" "$ROOT/Koi Pond.app"
ln -s /Applications "$ROOT/Applications"
cp "$STAGE/AppIcon.icns" "$ROOT/.VolumeIcon.icns"
# The background at 1x and 2x in one TIFF, so Retina screens get the sharp one.
"$BIN_DIR/KoiPond" --dmg-background "$STAGE/background.png" --scale 1
"$BIN_DIR/KoiPond" --dmg-background "$STAGE/background@2x.png" --scale 2
tiffutil -cathidpicheck "$STAGE/background.png" "$STAGE/background@2x.png" -out "$ROOT/.background/background.tiff" 2>/dev/null

# Finder finds disks by name, so another "Koi Pond" disk would get this one's layout.
if [[ -d "/Volumes/Koi Pond" ]]; then
    echo "A disk called Koi Pond is open (an earlier KoiPond.dmg?). Eject it and run this again." >&2
    exit 1
fi
hdiutil create -quiet -volname "Koi Pond" -srcfolder "$ROOT" -fs HFS+ -format UDRW -size 40m -ov "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/.*$' | head -1)"
trap 'hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true' EXIT
xcrun SetFile -a C "$MOUNT"

# Icon places match DMGArt.appIcon and DMGArt.applications; the window is DMGArt.size plus its title bar.
osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set disk_ to (POSIX file (item 1 of argv)) as alias
    tell application "Finder"
        open disk_
        set window_ to container window of disk_
        set current view of window_ to icon view
        -- Newer macOS may refuse these; the layout still holds without them.
        try
            set toolbar visible of window_ to false
        end try
        try
            set statusbar visible of window_ to false
        end try
        try
            set pathbar visible of window_ to false
        end try
        set bounds of window_ to {200, 120, 840, 548}
        set options_ to icon view options of window_
        set arrangement of options_ to not arranged
        set icon size of options_ to 128
        set text size of options_ to 13
        set shows item info of options_ to false
        set background picture of options_ to file ".background:background.tiff" of disk_
        set position of item "Koi Pond.app" of disk_ to {160, 180}
        set position of item "Applications" of disk_ to {480, 180}
        close window_
        open disk_
        delay 1
        close container window of disk_
    end tell
end run
APPLESCRIPT
# Give Finder a moment to write the layout before the disk goes away.
sleep 2
sync
hdiutil detach -quiet "$MOUNT"
trap - EXIT
rm -f build/KoiPond.dmg
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o build/KoiPond.dmg
rm -f "$RW"
echo "Made build/KoiPond.dmg ($(du -h build/KoiPond.dmg | cut -f1))"
