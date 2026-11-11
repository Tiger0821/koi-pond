import AppKit
import Combine
import CoreServices
import ImageIO
import KoiPondRender

/// Follows what Apple Music is playing. Song changes, play and pause arrive as Music's own broadcast,
/// which needs no permission. The cover, the position in the song and the buttons use Apple Events,
/// which macOS asks the user to allow once (Privacy & Security › Automation). Those are all sent from a
/// background queue (see `MusicEvents`), so a busy Music never holds up the pond or the buttons.
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
    /// Every change, for anything else following along (the player's own `onChange` belongs to the widget).
    let changes = PassthroughSubject<Void, Never>()

    static let bundleID = "com.apple.Music"
    private var enabled = false
    private var asking = false
    /// When a button was last pressed: Music can still report the old state for a moment afterwards.
    private var lastCommand = Date.distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Covers by song, including songs found to have none, so each is fetched once.
    private var covers: [String: CGImage?] = [:]
    private var lookups: Set<String> = []
    /// Counts state requests, so an answer overtaken by a newer request is dropped.
    private var syncs = 0

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
        lastCommand = Date()
        // Show the change straight away; Music's broadcast confirms it.
        if button == .playPause, var info {
            info.position = info.elapsed(at: Date())
            info.positionDate = Date()
            info.isPlaying.toggle()
            show(info)
        }
        MusicEvents.queue.async { [weak self] in
            do {
                try MusicEvents.press(button)
            } catch {
                DispatchQueue.main.async { self?.failed(error) }
            }
        }
    }

    /// Brings Music to the front, opening its window.
    static func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
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
                            duration: duration, position: nil, trackKey: Self.key(title, artist, album), album: album))
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
        guard isMusicRunning else { return }
        syncs += 1
        let request = syncs
        MusicEvents.queue.async { [weak self] in
            let asked = Date()
            let result = Result { try MusicEvents.state() }
            // Music read its position somewhere between the question and the answer; the middle is the best
            // guess, rather than whenever the main thread gets to it.
            let sampled = asked.addingTimeInterval(Date().timeIntervalSince(asked) / 2)
            DispatchQueue.main.async { self?.synced(result, request: request, sampled: sampled) }
        }
    }

    private func synced(_ result: Result<MusicEvents.State?, Error>, request: Int, sampled: Date) {
        guard request == syncs else { return }
        switch result {
        case .success(nil):
            show(nil)
        case .success(let state?):
            show(NowPlayingInfo(title: state.title, artist: state.artist, isPlaying: state.playing,
                                duration: state.duration > 0 ? state.duration : nil, position: state.position,
                                positionDate: sampled, trackKey: Self.key(state.title, state.artist, state.album),
                                album: state.album))
        case .failure(let error):
            failed(error)
        }
    }

    private func failed(_ error: Error) {
        if case MusicEvents.Failure.notPermitted = error {
            access = .denied
            changed()
        }
        Log.info("Music didn't answer: \(error)")
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
        guard access == .granted else {
            lookUpOnline(song)
            return
        }
        // Covers can be large; fetch and shrink them off the main thread.
        MusicEvents.queue.async { [weak self] in
            let image = (try? MusicEvents.cover()).flatMap(Self.decodeCover)
            DispatchQueue.main.async { self?.coverFetched(image, for: song) }
        }
    }

    private func coverFetched(_ image: CGImage?, for song: NowPlayingInfo) {
        if let image { coverFound(image, for: song.trackKey) } else { lookUpOnline(song) }
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
        changes.send()
    }
}

/// The few Apple Events the player sends Music, built by hand: unlike NSAppleScript, which may only be
/// used on the main thread, these can be sent from `queue`, one at a time and in order, so a command is
/// always followed by a state that includes it. Codes are Music's own (`sdef /System/Applications/Music.app`).
enum MusicEvents {
    static let queue = DispatchQueue(label: "com.koifishwallpaper.koipond.music", qos: .userInitiated)

    struct State {
        var playing: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
    }

    enum Failure: Error {
        case notPermitted
        case failed(Int)
    }

    static func press(_ button: NowPlayingButton) throws {
        let id = switch button {
        case .previous: "Back"
        case .playPause: "PlPs"
        case .next: "Next"
        }
        _ = try send(event("hook", id))
    }

    /// What's playing, or nil when Music is stopped.
    static func state() throws -> State? {
        let playerState = try get(property("pPlS")).enumCodeValue
        guard playerState != code("kPSS") else { return nil }
        let track = property("pTrk")
        return State(playing: playerState == code("kPSP"),
                     title: (try? get(property("pnam", of: track)).stringValue) ?? "",
                     artist: (try? get(property("pArt", of: track)).stringValue) ?? "",
                     album: (try? get(property("pAlb", of: track)).stringValue) ?? "",
                     duration: (try? get(property("pDur", of: track)).doubleValue) ?? 0,
                     position: (try? get(property("pPos")).doubleValue) ?? 0)
    }

    /// The current track's first artwork as image data, if it has one.
    static func cover() throws -> Data? {
        let artwork = element("cArt", index: 1, of: property("pTrk"))
        let data = try get(property("pRaw", of: artwork)).data
        return data.isEmpty ? nil : data
    }

    // MARK: Building and sending

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private static func event(_ eventClass: String, _ id: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(id),
                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: MusicPlayer.bundleID),
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private static func specifier(want: String, of container: NSAppleEventDescriptor, form: String,
                                  key: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(want: "prop", of: container, form: "prop", key: NSAppleEventDescriptor(typeCode: code(name)))
    }

    private static func element(_ kind: String, index: Int32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: kind, of: container, form: "indx", key: NSAppleEventDescriptor(int32: index))
    }

    private static func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let get = event("core", "getd")
        get.setParam(specifier, forKeyword: keyDirectObject)
        return try send(get)
    }

    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 4)
        } catch let error as NSError {
            throw error.code == errAEEventNotPermitted ? Failure.notPermitted : Failure.failed(error.code)
        }
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            throw Int(number) == errAEEventNotPermitted ? Failure.notPermitted : Failure.failed(Int(number))
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }
}
