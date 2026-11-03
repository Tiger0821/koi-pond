# Koi Pond

A living koi pond behind your Mac desktop icons, inspired by Solas. Koi, small fish, turtles,
lily pads, lotus flowers, plants and weather are simulated live with Metal, not looped video.

## Install

Download `KoiPond-1.0.0.zip` from the [latest release](https://github.com/Tiger0821/KoiFishWallpaper/releases/latest),
unzip it and move `KoiPond.app` to `/Applications`. It needs macOS 14 or later on Apple silicon.

The app is signed ad hoc, not notarized, so the first time macOS refuses to open it: Control-click it and
choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/KoiPond.app`. It then asks once to
control Music (for the Now Playing player) and once to hear Music's audio (for the fish dancing); both
are optional.

## Build and run

```bash
./scripts/build-app.sh
open build/KoiPond.app
```

The app lives in the menu bar (fish icon) with no Dock icon; its menu has About, Settings and Quit, and
every option is in the Settings window. Move `build/KoiPond.app` to
`/Applications` before turning on **Launch at login**. Requires macOS 14 or later.

Run the tests with `swift test`. `defaults write com.koifishwallpaper.koipond DebugLogging -bool true` logs
clicks, what blocked them, frames drawn and skipped, and any stall. To render a frame without opening any windows:

```bash
.build/debug/KoiPond --snapshot pond.png --weather sunset --quality pixel
```

To measure CPU, memory, GPU and battery use with few and many animals (about 20 minutes, on battery,
leaving the Mac alone), run `python3 -I scripts/measure-usage.py`. It uses `KoiPond --try-settings
file.json`, which runs the pond with those settings without saving them.

## What it does

- **Living pond:** ten koi varieties, schools of small fish, turtles that surface and dive,
  lily pads, lotus or water lily flowers, and underwater plants.
- **Touch the water:** click bare desktop for ripples. With **Feed the Fish** on, a click drops
  food (at most one click every 0.05 s counts, so an auto clicker can't swamp the pond). Clicks on windows, widgets, the Dock or menus are
  ignored, and icons keep working because the pond never takes the click.
- **Weather:** Sunny, Crystal, Dawn, Sunset, Twilight, Moonlight, Rain (ripples and streaks) and
  Storm (lightning), or Follow Device Time to drift from dawn to moonlight with the clock.
- **Make it yours:** water color, clarity, ripples, currents (strength, speed, core glow), animal
  counts, koi behavior (Calm, Curious, Shy, Schooling), motion speed, blooms and plants.
- **Quiet:** Pixel, Balanced and Smooth quality; 15–120 fps. It slows or pauses on battery and
  in Low Power Mode, and rests while the Mac sleeps, the screen is locked, or windows cover a display.

## Lock screen

Turn on **Animated Lock Screen** in the menu. Koi Pond records a 3-minute pond video (about 80 s of
work, ~120 MB) and swaps it into one of your downloaded Apple aerials in
`~/Library/Application Support/com.apple.wallpaper/aerials/videos` (macOS 26+). Apple's movie is
moved to `~/Library/Application Support/KoiPond/LockScreen/` and put back when you turn the
feature off. It also makes that aerial the wallpaper on every Space and display (by editing
`com.apple.wallpaper/Store/Index.plist`, the file System Settings › Wallpaper writes; a copy from
before the first change is kept in `~/Library/Application Support/KoiPond/`), so the pond plays on the
lock screen, in Mission Control and while switching Spaces. Turning it off restores the previous
wallpaper wherever you haven't picked a new one since. It re-records when you
change how the pond looks, or when Follow Device Time moves into a new part of the day. The cold-boot
FileVault screen stays static, and a macOS update may restore Apple's movie. Technique from the
MIT-licensed [Animated](https://github.com/vlzuiev/animated).

## Screen saver

Turn on **Pond Screen Saver** in the menu. The app installs `KoiPond.saver` (built into the app) to
`~/Library/Screen Savers`, keeps its `settings.json` in step with your pond settings, and makes it the
screen saver on every Space. Unlike the lock screen video, the screen saver runs the live simulation.
Turning it off removes it and restores your previous screen saver.

## Now Playing

A pixel-art Apple Music player sits on the main display while Music has a song playing or paused. Drag it by
its cover or title: it snaps to the screen's edges and center lines when near them and to a 24-point grid
elsewhere (Settings › Now Playing also has corner buttons and a size): the cover, the title and artist, previous,
play/pause and next buttons, and a progress bar. It is drawn as a 165×49 bitmap scaled up with
nearest-neighbour filtering, in a non-activating panel one level above the desktop icons, so its
buttons take clicks without stealing focus. Song changes come from Music's `com.apple.Music.playerInfo`
broadcast; the position, the cover and the buttons use Apple Events, which macOS asks you to allow once
(Privacy & Security › Automation; ad hoc signed rebuilds may ask again). Songs streamed without being
added to the library have no cover in Music, so the player looks them up with Apple's iTunes Search
API. Preview the drawing with `.build/release/KoiPond --now-playing-preview out.png --title … --artist …`.

## Song changes

When Music moves to a new song, the desktop player changes over with one of four pixel transitions, picked
at random: Mosaic Slide (typewriter title, the cover glides in as blocks and sharpens like a Super Nintendo
mosaic), Koi Surface (the cover sinks and the new one surfaces through rippling water), Split-Flap (letters
rattle and lock like a departure board, the cover drops in and bounces) and Dither Scan (a 4×4 ordered
dither fade, the cover scanned in line by line). Each runs 1.65 s, title first, then cover, then artist.

At the same time a koi bursts out of the middle of the pond head-first and smacks into the glass, slapping
a big card of the new song onto it (`SongCard`, in a click-through window just above the pond, with the
head-on pixel koi drawn by `KoiFace`). It is timed like a cartoon hit: a wind-up, true perspective on the way
in (size as one over distance), a hit-stop with one white impact frame and a short shake (both skipped with
Reduce Motion), squash and stretch on the glass with X eyes, water drops left behind, then it slides down,
uncovering the card, and drops back into the pond. The card plays the same transition, rests a few seconds
and sinks with a splash (Settings › Now Playing › Song change). Previews:
`.build/release/KoiPond --now-playing-preview out.png [--card] --style koi --at 900`,
`.build/release/KoiPond --koi-face out.png --pose splat --variety sanke`, and launching the app binary with
`--demo-song-card` plays the whole show four seconds in.

## Dancing and dragging

While Music plays, the koi and small fish rock from side to side on the beat, wriggle harder and swim
livelier in the loud parts (Settings › Now Playing › Dance). Koi Pond hears only Music's audio, through a
Core Audio process tap (macOS 14.2+; on macOS 26+ it follows Music by bundle ID), and only while a song
plays: each buffer goes through a small bass-energy beat detector (`BeatDetector`) and is dropped. macOS
asks once for audio capture (Privacy & Security › Screen & System Audio Recording).

Press on a koi to pick it up: it rises to the surface, follows the cursor and wriggles, then swims off the
way you flung it when you let go. Pressing anywhere else feeds the fish as before.

## How it works

Each display gets a borderless, click-through window one level above the desktop picture and below
the icons. A global mouse monitor observes copies of clicks sent to other apps; the window list
(frames, layers and owners only) decides whether a click landed on bare desktop. None of this needs
Screen Recording, Accessibility or Input Monitoring permission. Settings are stored in
UserDefaults; the log is at `~/Library/Logs/KoiPond.log`.
