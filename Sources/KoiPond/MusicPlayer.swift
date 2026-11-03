import AppKit
import Combine
import CoreServices
import ImageIO
import KoiPondRender

/// Follows what Apple Music is playing. Song changes, play and pause arrive as Music's own broadcast,
/// which needs no permission. The cover, the position in the song and the buttons use Apple Events,
/// which macOS asks the user to allow once (Privacy & Security › Automation).
final class MusicPlayer: ObservableObject {
    enum Access {
        case unknown, granted, denied
    }

    @Published private(set) var status = "Off"
    @Published private(set) var isPlaying = false
    private(set) var access = Access.unknown
    private(set) var info: NowPlayingInfo?
    private(set) var cover: CGImage?
    var onChange: (() -> Void)?

    static let bundleID = "com.apple.Music"
    private var enabled = false
    private var asking = false
    /// When a button was last pressed: Music can still report the old state for a moment afterwards.
    private var lastCommand = Date.distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Covers by song, including songs found to have none, so each is fetched once.
    private var covers: [String: CGImage?] = [:]
    private var lookups: Set<String> = []

    private lazy var stateScript = NSAppleScript(source: """
        tell application "Music"
            set s to player state as text
            if s is "stopped" then return {s}
            set t to current track
            return {s, name of t, artist of t, album of t, duration of t, player position}
        end tell
        """)
    private lazy var coverScript = NSAppleScript(source: """
        tell application "Music"
            if (count of artworks of current track) is 0 then return ""
            return raw data of artwork 1 of current track
        end tell
        """)
    private var commandScripts: [NowPlayingButton: NSAppleScript] = [:]

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            // Koi Pond is almost never the active app, and AppKit holds back other apps' broadcasts
            // from inactive apps unless asked to deliver them at once.
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(playerInfoChanged(_:)), name: Notification.Name("com.apple.Music.playerInfo"),
                object: nil, suspensionBehavior: .deliverImmediately)
            let workspace = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(workspace.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard Self.isMusic(note) else { return }
                self?.checkAccess(ask: true)
            })
            workspaceObservers.append(workspace.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard Self.isMusic(note) else { return }
                self?.show(nil)
            })
            if isMusicRunning { checkAccess(ask: true) }
        } else {
            DistributedNotificationCenter.default().removeObserver(self)
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers.removeAll()
            show(nil)
        }
        changed()
    }

    /// Re-reads the position in the song, which Music doesn't broadcast, so the progress bar stays true
    /// after seeking.
    func resync() {
        if access == .granted, Date().timeIntervalSince(lastCommand) > 2 { sync() }
    }

    func perform(_ button: NowPlayingButton) {
        guard access == .granted else {
            access == .denied ? Self.openAutomationSettings() : checkAccess(ask: true)
            return
        }
        guard isMusicRunning else { return }
        let command = switch button {
        case .previous: "back track"
        case .playPause: "playpause"
        case .next: "next track"
        }
        let script = commandScripts[button] ?? NSAppleScript(source: "tell application \"Music\" to \(command)")
        commandScripts[button] = script
        guard run(script) != nil else { return }
        lastCommand = Date()
        // Music's broadcast follows; meanwhile show the change straight away.
        if button == .playPause, var info {
            info.position = info.elapsed(at: Date())
            info.positionDate = Date()
            info.isPlaying.toggle()
            show(info)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Music's broadcast

    @objc private func playerInfoChanged(_ note: Notification) {
        let fields = note.userInfo ?? [:]
        let state = fields["Player State"] as? String ?? ""
        guard state == "Playing" || state == "Paused" else {
            show(nil)
            return
        }
        if access == .granted {
            sync()
            // The broadcast is the latest word on playing or paused; the query just made can lag behind it.
            let playing = state == "Playing"
            if var info, info.isPlaying != playing {
                info.position = info.elapsed(at: Date())
                info.positionDate = Date()
                info.isPlaying = playing
                show(info)
            }
            return
        }
        let title = fields["Name"] as? String ?? ""
        let artist = fields["Artist"] as? String ?? ""
        let album = fields["Album"] as? String ?? ""
        let duration = (fields["Total Time"] as? NSNumber).map { $0.doubleValue / 1000 }
        show(NowPlayingInfo(title: title, artist: artist, isPlaying: state == "Playing",
                            duration: duration, position: nil, trackKey: Self.key(title, artist, album)))
        // Permission may have been given in System Settings since it was refused.
        if access == .denied { checkAccess(ask: false) }
    }

    // MARK: Apple Events

    /// Asks macOS whether Koi Pond may control Music, off the main thread: with `ask`, the question
    /// can wait on the user's answer.
    private func checkAccess(ask: Bool) {
        guard enabled, !asking else { return }
        asking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleID)
            let status = target.aeDesc.map {
                AEDeterminePermissionToAutomateTarget($0, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
            } ?? OSStatus(procNotFound)
            DispatchQueue.main.async { self?.accessChecked(status) }
        }
    }

    private func accessChecked(_ status: OSStatus) {
        asking = false
        switch Int(status) {
        case Int(noErr):
            access = .granted
            sync()
        case errAEEventNotPermitted:
            access = .denied
        default:
            // Music isn't running, or the answer would need the user; try again later.
            break
        }
        Log.info("Music access \(access) (\(status))")
        changed()
    }

    private func sync() {
        guard isMusicRunning, let result = run(stateScript) else { return }
        let state = result.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", result.numberOfItems >= 6 else {
            show(nil)
            return
        }
        let title = result.atIndex(2)?.stringValue ?? ""
        let artist = result.atIndex(3)?.stringValue ?? ""
        let album = result.atIndex(4)?.stringValue ?? ""
        let duration = result.atIndex(5)?.doubleValue ?? 0
        let position = result.atIndex(6)?.doubleValue ?? 0
        show(NowPlayingInfo(title: title, artist: artist, isPlaying: state == "playing",
                            duration: duration > 0 ? duration : nil, position: position, positionDate: Date(),
                            trackKey: Self.key(title, artist, album)))
    }

    private func run(_ script: NSAppleScript?) -> NSAppleEventDescriptor? {
        guard let script else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard let error else { return result }
        let number = error[NSAppleScript.errorNumber] as? Int
        if number == errAEEventNotPermitted {
            access = .denied
            changed()
        }
        Log.info("Music script failed (\(number ?? 0)): \(error[NSAppleScript.errorMessage] ?? "")")
        return nil
    }

    // MARK: Covers

    private func show(_ next: NowPlayingInfo?) {
        let songChanged = next?.trackKey != info?.trackKey
        info = next
        if songChanged {
            cover = nil
            if let next { loadCover(next) }
        }
        changed()
    }

    private func loadCover(_ song: NowPlayingInfo) {
        if let cached = covers[song.trackKey] {
            cover = cached
            return
        }
        if access == .granted, let data = run(coverScript)?.data, let image = Self.decodeCover(data) {
            remember(image, for: song.trackKey)
            cover = image
            return
        }
        lookUpOnline(song)
    }

    /// Music has no cover for songs streamed without being added to the library, so ask Apple's
    /// iTunes Search for the album art, sending the song and artist name.
    private func lookUpOnline(_ song: NowPlayingInfo) {
        let key = song.trackKey
        guard !song.title.isEmpty, !lookups.contains(key),
              var components = URLComponents(string: "https://itunes.apple.com/search") else { return }
        lookups.insert(key)
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(song.artist) \(song.title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        if let region = Locale.current.region?.identifier {
            components.queryItems?.append(URLQueryItem(name: "country", value: region))
        }
        let finish: (CGImage?) -> Void = { [weak self] image in
            DispatchQueue.main.async { self?.coverFound(image, for: key) }
        }
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let small = first["artworkUrl100"] as? String,
                  let art = URL(string: small.replacingOccurrences(of: "100x100bb", with: "200x200bb"))
            else {
                finish(nil)
                return
            }
            URLSession.shared.dataTask(with: art) { data, _, _ in finish(data.flatMap(Self.decodeCover)) }.resume()
        }.resume()
    }

    private func coverFound(_ image: CGImage?, for key: String) {
        lookups.remove(key)
        remember(image, for: key)
        if info?.trackKey == key {
            cover = image
            changed()
        }
    }

    private func remember(_ image: CGImage?, for key: String) {
        if covers.count > 50 { covers.removeAll() }
        covers[key] = .some(image)
    }

    /// Decodes straight to a small image: the player only shows 40×40 pixels.
    static func decodeCover(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ] as CFDictionary)
    }

    // MARK: Helpers

    private static func key(_ title: String, _ artist: String, _ album: String) -> String {
        "\(artist)\u{1F}\(album)\u{1F}\(title)"
    }

    private static func isMusic(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleID
    }

    private func changed() {
        let next: String
        if !enabled {
            next = "Off"
        } else if access == .denied {
            next = "Allow Koi Pond to control Music in Privacy & Security › Automation"
        } else if !isMusicRunning {
            next = "Waiting for Music to open"
        } else if let info {
            next = "\(info.isPlaying ? "Playing" : "Paused"): \(info.title) — \(info.artist)"
        } else {
            next = "Nothing playing in Music"
        }
        if status != next { status = next }
        let playing = enabled && info?.isPlaying == true
        if isPlaying != playing { isPlaying = playing }
        onChange?()
    }
}
