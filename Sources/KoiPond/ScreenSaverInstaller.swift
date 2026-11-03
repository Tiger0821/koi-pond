import AppKit
import Combine
import KoiPondCore
import KoiPondRender

/// Installs the live pond screen saver (KoiPond.saver, shipped inside the app) into
/// ~/Library/Screen Savers, keeps its settings in step with the app, and makes it the screen saver
/// on every Space. Turning it off puts the previous screen saver back.
final class ScreenSaverInstaller: ObservableObject {
    @Published private(set) var status = "Off"

    private let store: SettingsStore
    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "com.koifishwallpaper.koipond.screensaver", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private let appliedKey = "ScreenSaverApplied"
    private var lastWrittenSettings: PondSettings?

    private var installedURL: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/KoiPond.saver")
    }
    private var previousURL: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KoiPond/previous-screen-saver.plist")
    }
    /// The screen saver choice records the bundle by URL; this is the part used to recognise ours.
    private var marker: String { "Screen%20Savers/KoiPond.saver" }

    init(store: SettingsStore) {
        self.store = store
    }

    func start() {
        if store.settings.pondScreenSaver { install() }
        store.$settings.dropFirst().receive(on: RunLoop.main).sink { [weak self] settings in
            self?.settingsChanged(settings)
        }.store(in: &cancellables)
        settingsChanged(store.settings)
    }

    private func settingsChanged(_ settings: PondSettings) {
        if settings.pondScreenSaver {
            if !fm.fileExists(atPath: installedURL.path) { install() }
            writeSettings(settings)
            applyIfNeeded()
        } else if defaults.bool(forKey: appliedKey) || fm.fileExists(atPath: installedURL.path) {
            uninstall()
        }
    }

    /// Copies the bundle shipped in the app, replacing any older copy.
    private func install() {
        guard let source = Bundle.main.url(forResource: "KoiPond", withExtension: "saver") else {
            status = "The screen saver bundle is missing from the app. Rebuild with scripts/build-app.sh."
            return
        }
        do {
            try fm.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedURL.path) { try fm.removeItem(at: installedURL) }
            try fm.copyItem(at: source, to: installedURL)
            lastWrittenSettings = nil
            // A running screen saver host keeps the old code loaded.
            Self.killall("legacyScreenSaver")
            Log.info("installed the pond screen saver")
        } catch {
            status = "Couldn't install the screen saver: \(error.localizedDescription)"
            Log.info("screen saver install failed: \(error)")
        }
    }

    /// The sandboxed screen saver host can't read the app's preferences, so the settings travel inside the
    /// bundle, which is then re-signed so its seal covers them.
    private func writeSettings(_ settings: PondSettings) {
        guard settings != lastWrittenSettings, fm.fileExists(atPath: installedURL.path),
              let data = try? JSONEncoder().encode(settings) else { return }
        let url = installedURL.appendingPathComponent("Contents/Resources/settings.json")
        do {
            try data.write(to: url, options: .atomic)
            lastWrittenSettings = settings
        } catch {
            Log.info("couldn't write screen saver settings: \(error)")
            return
        }
        let bundle = installedURL.path
        queue.async {
            // Copying adds Finder metadata that codesign refuses to seal.
            Self.run("/usr/bin/xattr", ["-cr", bundle])
            Self.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle])
        }
    }

    private func applyIfNeeded() {
        guard !defaults.bool(forKey: appliedKey) else {
            status = WallpaperStore.everywhere(.idle, contains: marker)
                ? "The pond is your screen saver"
                : "Another screen saver was chosen in System Settings"
            return
        }
        status = "Setting the screen saver…"
        let choice = WallpaperChoices.screenSaver(module: installedURL)
        let previousURL = previousURL
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let previous = try WallpaperStore.apply(choice, to: .idle, marker: marker)
                try fm.createDirectory(at: previousURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: previous, format: .binary, options: 0)
                try data.write(to: previousURL, options: .atomic)
                DispatchQueue.main.async {
                    self.defaults.set(true, forKey: self.appliedKey)
                    self.status = "The pond is your screen saver"
                }
            } catch {
                Log.info("couldn't set the pond screen saver: \(error)")
                DispatchQueue.main.async {
                    self.status = "Couldn't set the screen saver: \(error.localizedDescription)"
                }
            }
        }
    }

    private func uninstall() {
        if defaults.bool(forKey: appliedKey), let data = try? Data(contentsOf: previousURL),
           let previous = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            do {
                try WallpaperStore.restore(previous, kind: .idle, marker: marker)
            } catch {
                Log.info("couldn't restore the previous screen saver: \(error)")
            }
        }
        defaults.removeObject(forKey: appliedKey)
        try? fm.removeItem(at: installedURL)
        Self.killall("legacyScreenSaver")
        status = "Off"
    }

    static func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func killall(_ name: String) {
        run("/usr/bin/killall", [name])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
