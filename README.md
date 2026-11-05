# Koi Pond

<p align="center"><img src="docs/icon.png" width="160" alt="Koi Pond's icon: a pixel-art koi charging at you"></p>

## Download

**[Download Koi Pond for Mac (KoiPond.dmg)](https://github.com/Tiger0821/koi-pond/releases/latest/download/KoiPond.dmg)**:
version 1.0.1, about 2 MB, for macOS 14 or later on Apple silicon.

1. Open `KoiPond.dmg` and drag **Koi Pond** onto **Applications**.
2. Open Koi Pond from Applications. It isn't from the App Store, so the first time macOS may say it can't
   check it: open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to Koi Pond
   and open it again (or run `xattr -dr com.apple.quarantine "/Applications/Koi Pond.app"` in Terminal).
3. Your desktop is now a pond. Click the water to feed the fish.

Koi Pond may ask to control Music (for the Now Playing player) and to hear Music's sound (so the fish can
dance to the beat). Both are optional: Settings › General › Privacy › "Listen to Music so the fish can dance"
turns listening off, and then Koi Pond never hears any sound. Every version is on the
[releases page](https://github.com/Tiger0821/koi-pond/releases).

## About

A living koi pond behind your Mac desktop icons, inspired by Solas. Koi, small fish, turtles,
lily pads, lotus flowers, plants and weather are simulated live with Metal, not looped video.

## Build and run

```bash
./scripts/build-app.sh
open "/Applications/Koi Pond.app"
```

The script builds **Koi Pond.app** and installs it in `/Applications`, quitting and reopening a copy that's
running; `--no-install` leaves it in `$TMPDIR/koipond-build` instead. `./scripts/make-dmg.sh` packs it into
`build/KoiPond.dmg` for a release: a window with Koi Pond on the left, the Applications shortcut on the right
and a big pixel arrow between them under "Drag Koi Pond onto Applications", on a pond background the app draws
itself (`--dmg-background`), with the first-open tip underneath and the koi as the disk's icon. Finder lays
the window out, so the first run asks once to let Terminal control Finder. It puts the app together in the temporary folder, outside
the project: on an iCloud-synced Desktop, iCloud Drive touches new bundles (leaving "KoiPond 2.app" conflict
copies and Finder data that breaks code signing), and Spotlight would list a second copy. Its icon is the charging pixel koi,
drawn by the app itself (`.build/release/KoiPond --app-icon out.png [--style charge|splash|splat|night|lily]`)
and turned into `AppIcon.icns` for the app and its screen saver.

Koi Pond sits in the Dock and the menu bar (fish icon); Settings › General › Show Koi Pond in can make it
Dock only or menu bar only. Opening it, or clicking its Dock icon, shows the **Home** window: a live pond of its
own at the desktop's proportions (click it to touch the water and feed the fish, press on a koi to pick it
up), a glass bar along its bottom for the weather and the water's color, a pause button, and a card for each
place the pond lives (desktop, lock screen, screen saver, Music) with a switch, its status and a link to its
settings. The preview draws only while the window can be seen. At login it starts without the window.

Everything else is in **Settings** (Command-Comma), a standard Mac settings window with a toolbar of panes:
General, Pond, Fish, Plants, Music, Lock Screen and Performance. Following Apple's settings guidelines, the
window is titled after the pane, sized to it and reopens on the last one; each group of settings has a
one-line note under it, rarely needed options sit under Advanced, and the Pond, Fish, Plants and Performance
panes each have Restore Defaults (Reset All Settings is at the bottom of General). Requires macOS 14 or later.

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

Turn on **Show the pond on the lock screen** in Settings › Lock Screen (or the Lock Screen card on the Home window). Koi Pond records a 3-minute pond video (about 80 s of
work, ~120 MB) and swaps it into one of your downloaded Apple aerials in
`~/Library/Application Support/com.apple.wallpaper/aerials/videos` (macOS 26+). Apple's movie is
moved to `~/Library/Application Support/KoiPond/LockScreen/` and put back when you turn the
feature off. It also makes that aerial the wallpaper on every Space and display (by editing
`com.apple.wallpaper/Store/Index.plist`, the file System Settings › Wallpaper writes; a copy from
before the first change is kept in `~/Library/Application Support/KoiPond/`), so the pond plays on the
lock screen, in Mission Control and while switching Spaces. Turning it off restores the previous
wallpaper wherever you haven't picked a new one since. It re-records when you
change how the pond looks, or when Follow Device Time moves into a new part of the day. The cold-boot
FileVault screen stays static, and a macOS update may restore Apple's movie. macOS plays the movie with
its aerial renderer (`WallpaperAerialsExtension`), which slows it to a stop on unlock by dropping HEVC
temporal layers, so the recording is encoded in two (a 15 fps base layer and the frames between), like
Apple's aerials; a movie without them makes that slow-down fail, and the renderer's player then empties its
layers (every Space's wallpaper, and so its Mission Control thumbnail, turns black) and ignores every later
lock. On macOS 27 the wallpaper agent never restarts the renderer if it stops on its own; Koi Pond checks on it
at launch, every 15 minutes and after each unlock or screen saver, and restarts the agent (which brings the
renderer back) if it's gone, or restarts both if the log shows its player stuck. Technique from the
MIT-licensed [Animated](https://github.com/vlzuiev/animated).

## Screen saver

Turn on **Use the pond as the screen saver** in Settings › Lock Screen. The app installs `KoiPond.saver` (built into the app) to
`~/Library/Screen Savers`, keeps its `settings.json` in step with your pond settings, and makes it the
screen saver on every Space. Unlike the lock screen video, the screen saver runs the live simulation.
Turning it off removes it and restores your previous screen saver.

## Now Playing

A pixel-art Apple Music player sits on the main display while Music has a song playing or paused. Drag it by
its cover or title: it snaps to the screen's edges and center lines when near them and to a 24-point grid
elsewhere (Settings › Music also has corner buttons and a size): the cover, the title and artist, previous,
play/pause and next buttons, and a progress bar. It is drawn as a 165×49 bitmap scaled up with
nearest-neighbour filtering (titles and artists in Chinese, Japanese, Korean and other intricate scripts are
drawn on the bitmap's finer grid with edge pixels lit in quarter steps, so their strokes stay apart), in a non-activating panel one level above the desktop icons, so its
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
and sinks with a splash (Settings › Music › Song changes). Previews:
`.build/release/KoiPond --now-playing-preview out.png [--card] --style koi --at 900`,
`.build/release/KoiPond --koi-face out.png --pose splat --variety sanke`, and launching the app binary with
`--demo-song-card` plays the whole show four seconds in.

## Opening

Each time Koi Pond is opened (not when it starts at login), ten koi burst out of the pond together and
charge the screen (`LaunchCharge`): a ragged volley, each starting a few hundredths of a second off the
others, so the hits land within a tenth of a second all over the screen with the biggest dead center last.
They use the song card's head-on koi and timing (a wind-up, size as one over distance, a white impact
frame and a screen jolt per hit that add up, squash on the glass), hang there X-eyed, then peel off at their
own moments and slide down, leaving wet trails and drops, in under three seconds. It plays in a
click-through window above everything, on the display with the pointer. Turn it off in Settings › General › App. Preview frames with `.build/release/KoiPond --launch-preview out.png [--seed 1] [--times 0.3,0.6]`,
or play it with `--demo-launch` even when it's off.

## Dancing and dragging

While Music plays, the koi and small fish headbang: on each beat their bodies (not their tails, which keep
their own swimming beat) squash short and fat (easing in
over 80 ms, so nothing jumps), spring back long and thin, and jolt their heads one way and then the other,
swimming a little livelier in the loud parts. About once every 30 seconds of dancing the whole pond does a
disco spin, each fish a beat-long turn with a flash on its scales. Settings › Music › Dance sets how hard they
bounce (Gentle, Normal or Wild: half, full or 1.7 times the squash, stretch and jolt) and can turn the spins off. The
moves are drawn, never swum, so feeding, dragging and the song card are unaffected. Koi Pond hears only Music's audio, through a
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

## License

MIT, see [LICENSE](LICENSE). The lock screen technique comes from the MIT-licensed
[Animated](https://github.com/vlzuiev/animated).
