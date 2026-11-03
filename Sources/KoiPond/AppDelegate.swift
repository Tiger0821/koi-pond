import AppKit
import KoiPondRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--try-settings <file.json>` runs the desktop pond with those settings without saving them or touching
    /// the lock screen and screen saver, for measuring what a setup costs (scripts/measure-usage.py).
    private let trial = AppDelegate.trialSettings()
    private lazy var store = SettingsStore(trial: trial)
    private let settingsWindow = SettingsWindowController()
    private var power: PowerMonitor?
    private var wallpaper: WallpaperController?
    private var interaction: DesktopInteraction?
    private var lockScreen: LockScreenInstaller?
    private var screenSaver: ScreenSaverInstaller?
    private let music = MusicPlayer()
    private let beat = MusicBeat()
    private var nowPlaying: NowPlayingWidget?
    private var songCard: SongCard?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let ctx = MetalContext.make() else {
            let alert = NSAlert()
            alert.messageText = "Koi Pond couldn't start"
            alert.informativeText = "This Mac's graphics (Metal) could not be set up. Details are in ~/Library/Logs/KoiPond.log."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let power = PowerMonitor()
        let wallpaper = WallpaperController(ctx: ctx, store: store, power: power)
        wallpaper.music = { [beat] in beat.music }
        let interaction = DesktopInteraction(wallpaper: wallpaper, store: store)
        let lockScreen = LockScreenInstaller(ctx: ctx, store: store)
        let screenSaver = ScreenSaverInstaller(store: store)
        let nowPlaying = NowPlayingWidget(store: store, player: music)
        let songCard = SongCard(store: store, player: music, wallpaper: wallpaper)
        nowPlaying.onSongChange = { from, to, style in songCard.present(from: from, to: to, style: style) }
        // `--demo-song-card` plays the song-change show a few seconds after launch, without a real song change.
        if CommandLine.arguments.contains("--demo-song-card") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [music] in
                songCard.present(from: nil, to: SongFace(title: music.info?.title ?? "Paper Lanterns",
                                                         artist: music.info?.artist ?? "The Koi Collective", cover: music.cover),
                                 style: SongTransition.allCases.randomElement() ?? .mosaic)
            }
        }
        statusMenu = StatusMenuController { [weak self] in
            guard let self else { return }
            settingsWindow.show(store: store, lockScreen: lockScreen, screenSaver: screenSaver, music: music, beat: beat)
        }
        wallpaper.start()
        interaction.start()
        nowPlaying.start()
        beat.start(store: store, player: music)
        if trial == nil {
            lockScreen.start()
            screenSaver.start()
        }
        self.power = power
        self.wallpaper = wallpaper
        self.interaction = interaction
        self.lockScreen = lockScreen
        self.screenSaver = screenSaver
        self.nowPlaying = nowPlaying
        self.songCard = songCard
        Log.info("started\(trial == nil ? "" : " with trial settings"): screenRecordingGranted=\(CGPreflightScreenCaptureAccess()) windowsVisible=\(WindowList.snapshot().count)")
    }

    private static func trialSettings() -> Data? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--try-settings"), index + 1 < arguments.count else { return nil }
        return FileManager.default.contents(atPath: arguments[index + 1])
    }
}
