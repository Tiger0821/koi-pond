import AppKit
import KoiPondRender
import Combine
import KoiPondCore

/// Puts a recorded pond on the real lock screen. macOS 26 keeps Apple's moving "aerial"
/// wallpapers as movies in the user's home folder; we move one downloaded aerial's movie aside,
/// put a pond recording in its place, and move the original back when the feature is turned off.
/// The user picks that aerial once in System Settings › Wallpaper. Technique from the MIT-licensed
/// Animated app (github.com/vlzuiev/animated).
final class LockScreenInstaller: ObservableObject {
    enum State: Equatable {
        case off
        case noAerial
        case rendering(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// The aerial whose file we borrow, with the name System Settings shows for it.
    @Published private(set) var slotName: String?
    @Published private(set) var isSelected = false

    private let ctx: MetalContext
    private let store: SettingsStore
    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "com.koifishwallpaper.koipond.lockscreen", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var phaseTimer: Timer?
    private var pendingRender: DispatchWorkItem?
    private var rendering = false
    private var renderAgain = false
    private var isLocked = false

    private let slotKey = "LockScreenSlot"
    private let renderedKey = "LockScreenRenderedLook"
    private let wallpaperSetKey = "LockScreenWallpaperSet"
    static let videoSeconds = 180

    private var home: URL { fm.homeDirectoryForCurrentUser }
    private var wallpaperDir: URL { home.appendingPathComponent("Library/Application Support/com.apple.wallpaper") }
    private var videosDir: URL { wallpaperDir.appendingPathComponent("aerials/videos") }
    private var supportDir: URL { home.appendingPathComponent("Library/Application Support/KoiPond/LockScreen") }
    private var previousDesktopURL: URL { supportDir.appendingPathComponent("previous-wallpaper.plist") }

    init(ctx: MetalContext, store: SettingsStore) {
        self.ctx = ctx
        self.store = store
    }

    func start() {
        store.$settings.receive(on: RunLoop.main).sink { [weak self] settings in
            self?.settingsChanged(settings)
        }.store(in: &cancellables)
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.isLocked = true })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.unlocked() })
        // Follow Device Time changes the light through the day; re-record when the phase moves on.
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            settingsChanged(store.settings)
        }
    }

    /// Re-reads whether the user has picked our aerial in System Settings.
    func refreshSelection() {
        guard let id = installedSlotID,
              let data = try? Data(contentsOf: wallpaperDir.appendingPathComponent("Store/Index.plist")) else {
            isSelected = false
            return
        }
        isSelected = data.range(of: Data(id.utf8)) != nil
    }

    var statusText: String {
        switch state {
        case .off: "Off"
        case .noAerial: "Download any aerial in Wallpaper settings first"
        case .rendering(let progress): "Recording the pond… \(Int(progress * 100))%"
        case .ready where isSelected: "Lock screen shows the pond"
        case .ready: "Now choose “\(slotName ?? "the aerial")” in Wallpaper settings"
        case .failed(let message): message
        }
    }

    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    private var installedSlotID: String? {
        guard let id = defaults.string(forKey: slotKey), fm.fileExists(atPath: backupURL(id).path) else { return nil }
        return id
    }

    private func settingsChanged(_ settings: PondSettings) {
        guard settings.animatedLockScreen else {
            pendingRender?.cancel()
            if installedSlotID != nil { restore() }
            state = .off
            return
        }
        if let id = installedSlotID, defaults.string(forKey: renderedKey) == lookKey(settings) {
            slotName = aerialNames()[id] ?? slotName
            state = .ready
            useAsWallpaper(id)
            return
        }
        // Wait for sliders to settle; start promptly when the feature was just turned on.
        let delay: TimeInterval = state == .off ? 1 : 20
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.record() }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func record() {
        guard !rendering else {
            renderAgain = true
            return
        }
        let settings = store.settings
        guard settings.animatedLockScreen else { return }
        guard let slot = resolveSlot() else {
            state = .noAerial
            return
        }
        slotName = slot.name
        rendering = true
        state = .rendering(0)
        let key = lookKey(settings)
        let screen = NSScreen.screens.first
        let points = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        let scale = min(screen?.backingScaleFactor ?? 2, 3840 / points.width)
        let output = supportDir.appendingPathComponent("recording.mov")
        Log.info("recording lock screen pond for aerial \(slot.id)")

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
                let poster = try PondVideoWriter.write(
                    to: output, ctx: ctx, settings: settings, worldSize: SIMD2(Float(points.width), Float(points.height)),
                    pixelWidth: Int(points.width * scale), pixelHeight: Int(points.height * scale),
                    seconds: Self.videoSeconds) { progress in
                        DispatchQueue.main.async { self.state = .rendering(progress) }
                    }
                DispatchQueue.main.async { self.install(output, poster: poster, slotID: slot.id, key: key) }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription)
                    self.rendering = false
                    Log.info("lock screen recording failed: \(error)")
                }
            }
        }
    }

    private func install(_ recording: URL, poster: CGImage?, slotID: String, key: String) {
        defer {
            rendering = false
            if renderAgain {
                renderAgain = false
                settingsChanged(store.settings)
            }
        }
        guard store.settings.animatedLockScreen else {
            try? fm.removeItem(at: recording)
            return
        }
        let slot = videosDir.appendingPathComponent("\(slotID).mov")
        let backup = backupURL(slotID)
        do {
            if fm.fileExists(atPath: backup.path) {
                _ = try fm.replaceItemAt(slot, withItemAt: recording)
            } else {
                // First install: keep Apple's movie safe before anything else touches the slot.
                try fm.moveItem(at: slot, to: backup)
                try fm.moveItem(at: recording, to: slot)
            }
        } catch {
            state = .failed("Couldn't swap the aerial: \(error.localizedDescription)")
            Log.info("lock screen install failed: \(error)")
            return
        }
        defaults.set(slotID, forKey: slotKey)
        defaults.set(key, forKey: renderedKey)
        refreshSelection()
        if isSelected, let poster { writePoster(poster) }
        // Restarting the wallpaper agents mid-lock blanks the running animation; unlock handles it then.
        if !isLocked { reloadWallpaper() }
        state = .ready
        Log.info("lock screen pond installed in aerial \(slotID) (selected: \(isSelected))")
        useAsWallpaper(slotID, poster: poster)
    }

    /// The lock screen shows the wallpaper, so make the pond aerial the wallpaper on every Space and
    /// display, once. Later wallpaper changes in System Settings are left alone.
    private func useAsWallpaper(_ slotID: String, poster: CGImage? = nil) {
        refreshSelection()
        guard !defaults.bool(forKey: wallpaperSetKey) else { return }
        let previousURL = previousDesktopURL
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let previous = try WallpaperStore.apply(WallpaperChoices.aerial(assetID: slotID), to: .desktop, marker: slotID)
                let data = try PropertyListSerialization.data(fromPropertyList: previous, format: .binary, options: 0)
                try data.write(to: previousURL, options: .atomic)
                DispatchQueue.main.async {
                    self.defaults.set(true, forKey: self.wallpaperSetKey)
                    self.refreshSelection()
                    if let poster { self.writePoster(poster) }
                }
            } catch {
                Log.info("couldn't set the pond aerial as wallpaper: \(error)")
                DispatchQueue.main.async {
                    self.state = .failed("Couldn't set the pond as wallpaper: \(error.localizedDescription)")
                }
            }
        }
    }

    private func restore() {
        guard let id = installedSlotID else { return }
        if defaults.bool(forKey: wallpaperSetKey), let data = try? Data(contentsOf: previousDesktopURL),
           let previous = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            do {
                try WallpaperStore.restore(previous, kind: .desktop, marker: id)
            } catch {
                Log.info("couldn't restore the previous wallpaper: \(error)")
            }
        }
        defaults.removeObject(forKey: wallpaperSetKey)
        let slot = videosDir.appendingPathComponent("\(id).mov")
        let backup = backupURL(id)
        do {
            if fm.fileExists(atPath: slot.path) {
                _ = try fm.replaceItemAt(slot, withItemAt: backup)
            } else {
                try fm.moveItem(at: backup, to: slot)
            }
            defaults.removeObject(forKey: slotKey)
            defaults.removeObject(forKey: renderedKey)
            isSelected = false
            reloadWallpaper()
            Log.info("restored Apple's aerial \(id)")
        } catch {
            state = .failed("Couldn't restore Apple's aerial: \(error.localizedDescription)")
            Log.info("lock screen restore failed: \(error)")
        }
    }

    /// The aerial renderer can wedge into a black lock screen after the first lock; restarting just
    /// the renderer on unlock keeps the next lock animated.
    private func unlocked() {
        isLocked = false
        guard installedSlotID != nil else { return }
        killProcess("WallpaperAerialsExtension")
    }

    // MARK: Slot selection

    /// Picks an Apple-downloaded aerial no other tool has swapped, and sticks with it.
    private func resolveSlot() -> (id: String, name: String)? {
        let names = aerialNames()
        if let id = defaults.string(forKey: slotKey),
           fm.fileExists(atPath: videosDir.appendingPathComponent("\(id).mov").path) {
            return (id, names[id] ?? "Aerial")
        }
        let ids = ((try? fm.contentsOfDirectory(atPath: videosDir.path)) ?? [])
            .filter { $0.hasSuffix(".mov") }
            .map { String($0.dropLast(4)) }
        let swappedByOthers = Set(ids.filter { $0.hasSuffix("-ORIGINAL-BACKUP") }.map { String($0.dropLast(16)) })
        let candidates = ids.filter { id in
            guard !id.contains("BACKUP"), !swappedByOthers.contains(id), names[id] != nil else { return false }
            // Apple downloads aerials owner-only; anything else has been rewritten by another app.
            let attributes = try? fm.attributesOfItem(atPath: videosDir.appendingPathComponent("\(id).mov").path)
            return (attributes?[.posixPermissions] as? Int) == 0o600
        }
        // Prefer aerials with a readable name, so the user can find them in System Settings.
        let readable = candidates.filter { names[$0]?.contains(" ") == true }.sorted { names[$0]! < names[$1]! }
        guard let id = readable.first ?? candidates.sorted().first else { return nil }
        return (id, names[id] ?? "Aerial")
    }

    private func aerialNames() -> [String: String] {
        let manifest = wallpaperDir.appendingPathComponent("aerials/manifest/entries.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for asset in assets {
            if let id = asset["id"] as? String, let label = asset["accessibilityLabel"] as? String { names[id] = label }
        }
        return names
    }

    private func backupURL(_ id: String) -> URL {
        supportDir.appendingPathComponent("\(id).original.mov")
    }

    /// Settings that change how the recording looks, plus the time-of-day phase when following the clock.
    /// The settings the recorded video shows. Only these count, so changing anything else, or adding settings
    /// later, never sets off a new recording.
    private static let lookSettings: Set<String> = [
        "weather", "waterColor", "clarity", "currentsEnabled", "currentStrength", "currentSpeed", "coreGlow",
        "koiCount", "smallFishCount", "turtleCount", "motionSpeed", "lilyPadCount", "flowerStyle", "flowerCount",
        "plantCount", "quality",
    ]

    private func lookKey(_ s: PondSettings) -> String {
        let phase = s.weather == .followDeviceTime ? WeatherPreset.dayPhase(at: Date()) : -1
        guard let data = try? JSONEncoder().encode(s),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Sorted keys: the encoders' default key order changes from launch to launch.
              let look = try? JSONSerialization.data(withJSONObject: all.filter { Self.lookSettings.contains($0.key) },
                                                     options: .sortedKeys)
        else { return "\(phase)|" }
        return "\(phase)|\(String(decoding: look, as: UTF8.self))"
    }

    // MARK: System hooks

    /// The lock screen's still, shown before the movie starts (`/Library/Caches/Desktop Pictures/<user UUID>`).
    private func writePoster(_ image: CGImage) {
        guard let uuid = Self.userGeneratedUID() else { return }
        let directory = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures/\(uuid)")
        guard fm.isWritableFile(atPath: directory.path),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let temporary = directory.appendingPathComponent("lockscreen.koipond.png")
        do {
            try png.write(to: temporary)
            let poster = directory.appendingPathComponent("lockscreen.png")
            if fm.fileExists(atPath: poster.path) {
                _ = try fm.replaceItemAt(poster, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: poster)
            }
        } catch {
            Log.info("couldn't write the lock screen still: \(error)")
        }
    }

    private static func userGeneratedUID() -> String? {
        let output = run("/usr/bin/dscl", [".", "-read", "/Users/\(NSUserName())", "GeneratedUID"])
        return output.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Restarting both agents makes the lock screen, desktop and Settings thumbnail pick up the new movie.
    private func reloadWallpaper() {
        killProcess("WallpaperAerialsExtension")
        killProcess("WallpaperAgent")
    }

    private func killProcess(_ name: String) {
        _ = Self.run("/usr/bin/killall", [name])
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
