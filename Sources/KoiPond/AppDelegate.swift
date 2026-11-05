import AppKit
import Combine
import KoiPondCore
import KoiPondRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--try-settings <file.json>` runs the desktop pond with those settings without saving them or touching
    /// the lock screen and screen saver, for measuring what a setup costs (scripts/measure-usage.py).
    private let trial = AppDelegate.trialSettings()
    private lazy var store = SettingsStore(trial: trial)
    private var settingsWindow: SettingsWindowController?
    private var homeWindow: HomeWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var power: PowerMonitor?
    private var wallpaper: WallpaperController?
    private var interaction: DesktopInteraction?
    private var lockScreen: LockScreenInstaller?
    private var screenSaver: ScreenSaverInstaller?
    private let music = MusicPlayer()
    private let beat = MusicBeat()
    private var nowPlaying: NowPlayingWidget?
    private var songCard: SongCard?
    private let launchCharge = LaunchCharge()
    private var statusMenu: StatusMenuController?

    /// Settles Dock or menu bar before the app finishes launching, so a menu-bar-only Koi Pond never flashes
    /// into the Dock.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(store.settings.presence.inDock ? .regular : .accessory)
        NSApp.mainMenu = MainMenu.make(openHome: { [weak self] in self?.homeWindow?.show() },
                                       openSettings: { [weak self] in self?.settingsWindow?.show() })
    }

    /// Clicking the Dock icon brings up the Home window unless one of Koi Pond's windows is already open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !(homeWindow?.isVisible ?? false), !(settingsWindow?.isVisible ?? false) { homeWindow?.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened by the user, rather than as a login item when the Mac starts up.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let openedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
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
        let settingsWindow = SettingsWindowController(store: store, lockScreen: lockScreen, screenSaver: screenSaver,
                                                      music: music, beat: beat)
        let homeWindow = HomeWindowController(ctx: ctx, store: store, lockScreen: lockScreen, screenSaver: screenSaver,
                                              music: music, beat: beat, openSettings: { pane in settingsWindow.show(pane: pane) })
        self.settingsWindow = settingsWindow
        self.homeWindow = homeWindow
        let statusMenu = StatusMenuController(openHome: { homeWindow.show() }, openSettings: { settingsWindow.show() })
        self.statusMenu = statusMenu
        // Dock, menu bar or both, as chosen in Settings › General.
        store.$settings.map(\.presence).removeDuplicates().receive(on: RunLoop.main).sink { presence in
            statusMenu.isVisible = presence.inMenuBar
            let policy: NSApplication.ActivationPolicy = presence.inDock ? .regular : .accessory
            guard NSApp.activationPolicy() != policy else { return }
            NSApp.setActivationPolicy(policy)
            // Leaving the Dock deactivates the app; keep the window the user was changing this in, in front.
            DispatchQueue.main.async {
                NSApp.activate()
                if settingsWindow.isVisible { settingsWindow.show() }
            }
        }.store(in: &cancellables)
        wallpaper.start()
        interaction.start()
        nowPlaying.start()
        beat.start(store: store, player: music)
        if trial == nil {
            lockScreen.start()
            screenSaver.start()
        }
        // Opened by hand, it shows its Home window; at login it starts quietly.
        if trial == nil, !openedAtLogin { homeWindow.show() }
        // Each time it's opened, ten koi charge the screen; a moment after launch, once the pond is up.
        if trial == nil, !openedAtLogin, store.settings.launchCharge || CommandLine.arguments.contains("--demo-launch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [launchCharge] in launchCharge.play() }
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
