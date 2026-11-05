#!/bin/bash
# Builds Koi Pond and packs it into build/KoiPond.dmg: the app beside a shortcut to Applications to drag it onto,
# a note on opening it the first time, and the app's icon as the disk's icon. The name carries no version, so
# the README's link (releases/latest/download/KoiPond.dmg) always downloads the newest release.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh --no-install
STAGE=".build/app"
ROOT="$STAGE/dmg"
rm -rf "$ROOT" "$STAGE/KoiPond-rw.dmg"
mkdir -p "$ROOT" build
ditto "$STAGE/Koi Pond.app" "$ROOT/Koi Pond.app"
ln -s /Applications "$ROOT/Applications"
cp "$STAGE/AppIcon.icns" "$ROOT/.VolumeIcon.icns"
cat > "$ROOT/If Koi Pond won't open.txt" <<'TEXT'
Koi Pond isn't from the App Store, so the first time you open it macOS may say it can't check it.

1. Drag Koi Pond onto Applications.
2. Open Koi Pond from Applications. If macOS refuses, open System Settings › Privacy & Security,
   scroll down and click Open Anyway next to Koi Pond, then open it again.
   (Or, in Terminal: xattr -dr com.apple.quarantine "/Applications/Koi Pond.app")

After that it opens like any other app. It needs macOS 14 or later on Apple silicon.
TEXT

# Made writable first so the disk can be marked as having its own icon, then compressed.
hdiutil create -quiet -volname "Koi Pond" -srcfolder "$ROOT" -fs HFS+ -format UDRW -ov "$STAGE/KoiPond-rw.dmg"
MOUNT="$(hdiutil attach -nobrowse -noautoopen "$STAGE/KoiPond-rw.dmg" | grep -o '/Volumes/.*$' | head -1)"
xcrun SetFile -a C "$MOUNT" || true
hdiutil detach -quiet "$MOUNT"
rm -f build/KoiPond.dmg
hdiutil convert -quiet "$STAGE/KoiPond-rw.dmg" -format UDZO -imagekey zlib-level=9 -o build/KoiPond.dmg
rm -f "$STAGE/KoiPond-rw.dmg"
echo "Made build/KoiPond.dmg ($(du -h build/KoiPond.dmg | cut -f1))"
