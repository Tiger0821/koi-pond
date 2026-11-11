import AppKit
import Combine
import KoiPondCore
import KoiPondRender
import QuartzCore

/// Rock and Roll lyrics: the song's synced lyrics play big in the middle of the pond, words slamming in as
/// they're sung and the line moving to the beat, while the pond dims a little behind them. The pond splashes
/// where the big words land.
///
/// Lyrics are looked up online by song, artist and length (`LyricsService`). The position in the song comes
/// from Music over Apple Events, eased so a late answer never makes a word jump; the beat comes from
/// `MusicBeat`, which only listens while the fish dance. It lives in a window just above the pond, below the
/// desktop icons and every window, and never takes a click.
final class PondLyrics: ObservableObject {
    @Published private(set) var status = "Off"
    /// While this is true the lyrics wait, off screen: the song card's koi has the middle of the pond.
    var holdWhile: () -> Bool = { false }

    private let store: SettingsStore
    private let player: MusicPlayer
    private let beat: MusicBeat
    private let wallpaper: WallpaperController
    private let service: LyricsService
    private let panel: NSPanel
    private let dim = CALayer()
    private let words = CALayer()
    private let flash = CALayer()
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var geometry: Geometry?

    // The song
    private var trackKey: String?
    private var lyrics: Lyrics?
    /// Which style each line is drawn in: one for the song, or styles mixed through it to suit the song.
    private var mix = RockMix(lyrics: nil, fixed: nil, energy: 0.5, roll: 0)
    private var style: RockStyle { mix.current }
    /// What the mix aims for, 0 (calm) to 1 (wild): the song's intensity, nudged by its loud and quiet parts.
    private var energy = 0.5
    /// How intense the song is by its lyrics (how fast the words come), then by its beat as it's heard.
    private var lyricsIntensity = 0.5
    private var songIntensity = 0.5
    /// The beat heard so far this song: the grid's confidence summed over time, its tempo, and for how long.
    private var beatStrength = 0.0
    private var beatTempo = 0.0
    private var beatHeard = 0.0
    /// How loud this part of the song is against its own loudest, eased over a few seconds.
    private var section = 0.5
    private var fetch: Task<Void, Never>?
    private var searching = false

    // The clock: the position in the song at a host time, eased toward what Music reports.
    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = 0
    private var anchoredAnswer: Date?
    private var playing = false
    /// How far each of Music's answers was from the clock, while playing, for the log at the end of a song.
    private var clockGaps: [Double] = []
    private var lastResync: CFTimeInterval = 0
    private var lastSongTime: Double?
    private var lastOpacity: Double = 0
    private var lastTick: CFTimeInterval?
    /// When the last hold ended, so the lyrics come in after it rather than popping on.
    private var holding = false
    private var releasedAt: CFTimeInterval?

    /// `--demo-lyrics`: made-up lyrics on a clock of its own, with a steady 150 BPM beat; no Music needed.
    private let demoStart: CFTimeInterval?

    /// The settings this follows.
    private struct Choice: Equatable {
        var on: Bool
        var style: RockStyle?
    }

    /// Where everything sits on the display with the menu bar.
    private struct Geometry: Equatable {
        var screen: CGRect
        /// Points per canvas pixel.
        var canvasPoint: CGFloat
        /// The lyrics' band across the middle, in the panel's points from the bottom left.
        var band: CGRect
        var canvas: CGSize

        init(screen: CGRect) {
            self.screen = screen
            // About 380 art pixels across: 4 points each on a 14-inch MacBook Pro.
            let unit = max(3, (screen.width / 380).rounded())
            canvasPoint = unit / CGFloat(RockLyricsArt.fine)
            let height = (screen.height * 0.62 / canvasPoint).rounded() * canvasPoint
            band = CGRect(x: 0, y: ((screen.height - height) / 2).rounded(), width: screen.width, height: height)
            canvas = CGSize(width: (screen.width / canvasPoint).rounded(.down), height: height / canvasPoint)
        }
    }

    init(store: SettingsStore, player: MusicPlayer, beat: MusicBeat, wallpaper: WallpaperController) {
        self.store = store
        self.player = player
        self.beat = beat
        self.wallpaper = wallpaper
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        service = LyricsService(cacheDirectory: caches.appendingPathComponent("com.koifishwallpaper.koipond/Lyrics",
                                                                              isDirectory: true))
        demoStart = CommandLine.arguments.contains("--demo-lyrics") ? CACurrentMediaTime() + 2 : nil

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // With the song card: above the pond, below the desktop icons.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.canHide = false

        let host = NSView()
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        words.magnificationFilter = .nearest
        words.contentsGravity = .resize
        flash.backgroundColor = CGColor(gray: 1, alpha: 1)
        for layer in [dim, words, flash] {
            layer.opacity = 0
            root.addSublayer(layer)
        }
        panel.contentView = host
    }

    func start() {
        store.$settings.map { Choice(on: $0.rockLyrics, style: $0.rockStyle) }
            .removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        player.changes.receive(on: RunLoop.main).sink { [weak self] in self?.evaluate() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.geometry = nil }.store(in: &cancellables)
        if demoStart != nil {
            lyrics = Self.demoLyrics
            remix()
            startTicker()
        }
    }

    // MARK: Following Music

    private func settingsChanged() {
        if trackKey != nil || demoStart != nil { remix() }
        evaluate()
    }

    private func evaluate() {
        guard demoStart == nil else { return }
        let s = store.settings
        guard s.rockLyrics else {
            forgetSong()
            stopTicker()
            setStatus("Off")
            return
        }
        guard let info = player.info else {
            forgetSong()
            stopTicker()
            setStatus("Waiting for a song in Music")
            return
        }
        if info.trackKey != trackKey { newSong(info) }
        foldPosition(info)
        if info.isPlaying, lyrics != nil { startTicker() } else { stopTicker() }
        if !searching { describe(info) }
    }

    private func newSong(_ info: NowPlayingInfo) {
        logClock()
        trackKey = info.trackKey
        lyrics = nil
        anchoredAnswer = nil
        lastSongTime = nil
        energy = 0.5
        lyricsIntensity = 0.5
        songIntensity = 0.5
        beatStrength = 0
        beatTempo = 0
        beatHeard = 0
        section = 0.5
        remix()
        beat.resetTempo()
        fetch?.cancel()
        guard !info.title.isEmpty else { return }
        searching = true
        setStatus("Looking for lyrics…")
        let query = TrackQuery(title: info.title, artist: info.artist, album: info.album, duration: info.duration ?? 0)
        let key = info.trackKey, traditional = Self.prefersTraditionalChinese
        fetch = Task { @MainActor [weak self, service] in
            let (found, alignment, notes) = await service.lookUp(query, traditional: traditional)
            guard let self, self.trackKey == key else { return }
            self.searching = false
            self.lyrics = found
            // How wild to go starts from how fast the words come; the beat refines it as it's heard.
            if let found {
                self.lyricsIntensity = SongIntensity.fromLyrics(found)
                self.songIntensity = self.lyricsIntensity
                self.energy = self.songIntensity
            }
            // Where the styles may change depends on the lyrics: their breaks and choruses.
            self.remix()
            let moved = switch alignment {
            case .asFetched: ""
            case .shifted(let seconds): String(format: ", moved %+.2f s to line up with this release", seconds)
            case .warped: ", each line moved onto this release's line timing"
            case .replaced: " (this release's own timing, as NetEase's is another arrangement)"
            }
            let song = "\(query.title) — \(query.artist) (\(query.album), \(Int(query.duration)) s)"
            let feel = found == nil ? "" : String(format: ", a %@ song by its words (%.2f), starting with %@",
                                                  SongIntensity.describe(self.lyricsIntensity), self.lyricsIntensity, self.style.title)
            Log.info("lyrics for \(song): \(found.map { "\($0.lines.count) lines from \($0.source), \($0.timing == .word ? "word" : "line") timing" } ?? "none found")\(moved)\(feel). \(notes.joined(separator: "; "))")
            self.evaluate()
        }
    }

    /// How well the clock kept to Music over the song: the typical and the largest gap at a re-read.
    private func logClock() {
        defer { clockGaps.removeAll() }
        let steady = clockGaps.filter { abs($0) <= 0.4 }.map(abs).sorted()
        let jumps = clockGaps.filter { abs($0) > 0.4 }.sorted()
        guard !clockGaps.isEmpty else { return }
        let jumped = jumps.isEmpty ? "no jumps" : String(format: "%d jumps (seeks), typically %+.2f s", jumps.count, jumps[jumps.count / 2])
        Log.info(String(format: "lyrics clock: %d checks against Music, typical gap %.0f ms, largest %.0f ms, %@", clockGaps.count,
                        (steady.isEmpty ? 0 : steady[steady.count / 2]) * 1000, (steady.last ?? 0) * 1000, jumped))
    }

    private func forgetSong() {
        fetch?.cancel()
        searching = false
        trackKey = nil
        lyrics = nil
        anchoredAnswer = nil
    }

    private func describe(_ info: NowPlayingInfo) {
        guard let lyrics else {
            setStatus(info.title.isEmpty ? "Waiting for a song in Music" : "No synced lyrics found for this song")
            return
        }
        let timing = lyrics.timing == .word ? "word-by-word" : "line-by-line"
        let now = fixedStyle == nil ? "A \(SongIntensity.describe(songIntensity)) song, now \(style.title)" : style.title
        setStatus("\(now), \(timing) lyrics from \(lyrics.source)\(info.isPlaying ? "" : " (paused)")")
    }

    /// The one style chosen in Settings, or nil to match the styles to the song.
    private var fixedStyle: RockStyle? {
        if let name = Self.argument("--demo-style"), let named = RockStyle(rawValue: name) { return named }
        return store.settings.rockStyle
    }

    /// Starts the song's styles afresh: the chosen one, or a mix aimed at how intense the song is.
    private func remix() {
        mix = RockMix(lyrics: lyrics, fixed: fixedStyle, energy: energy, roll: .random(in: 0..<1))
    }

    /// Takes in Music's latest answer for the position, easing small differences (an Apple Event's round trip)
    /// and jumping on big ones (a seek).
    private func foldPosition(_ info: NowPlayingInfo) {
        let now = CACurrentMediaTime()
        let wasPlaying = playing
        playing = info.isPlaying
        guard let position = info.position, info.positionDate != anchoredAnswer else {
            if wasPlaying != playing {
                // Paused or resumed without a new position: hold the clock where it is.
                anchorPosition = songPosition(at: now, playing: wasPlaying)
                anchorTime = now
            }
            return
        }
        let reported = position + (info.isPlaying ? Date().timeIntervalSince(info.positionDate) : 0)
        let mine = songPosition(at: now, playing: wasPlaying)
        if anchoredAnswer != nil, info.isPlaying, wasPlaying { clockGaps.append(reported - mine) }
        if anchoredAnswer == nil || !info.isPlaying || !wasPlaying || abs(reported - mine) > 0.4 {
            anchorPosition = reported
        } else {
            anchorPosition = mine + (reported - mine) * 0.35
        }
        anchorTime = now
        anchoredAnswer = info.positionDate
    }

    private func songPosition(at time: CFTimeInterval, playing: Bool) -> Double {
        playing ? anchorPosition + (time - anchorTime) : anchorPosition
    }

    private func setStatus(_ text: String) {
        if status != text { status = text }
    }

    // MARK: Drawing

    private func startTicker() {
        guard ticker == nil else { return }
        let fps = Double(min(max(store.settings.frameRate.rawValue, 30), 60))
        let ticker = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        tick()
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        lastSongTime = nil
        lastOpacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [dim, words, flash] { layer.opacity = 0 }
        words.contents = nil
        CATransaction.commit()
        panel.orderOut(nil)
    }

    private func tick() {
        guard let lyrics, let screen = NSScreen.screens.first else { return }
        let now = CACurrentMediaTime()
        if geometry?.screen != screen.frame { layOut(on: screen) }
        guard let geometry else { return }

        let songTime: Double
        var grid: BeatGrid?
        if let demoStart {
            // The made-up song loops every 24 seconds: a verse, a break, then louder.
            songTime = (now - demoStart).truncatingRemainder(dividingBy: Self.demoLength)
            grid = BeatGrid(anchor: 0.2, period: 0.4, confidence: 1)
            energy = songTime < 9 ? 0.1 : songTime < 15 ? 0.5 : 0.95
            songIntensity = energy
        } else {
            if now - lastResync > 4 {
                lastResync = now
                player.resync()
            }
            // What's heard now: the position Music is at, less the time its sound takes to reach the ears.
            songTime = songPosition(at: now, playing: playing) - beat.heardDelay
            grid = beat.beatGrid(at: now)?.shifted(by: songTime - now)
        }
        // A seek or a loop: no landings from the jump.
        let since = lastSongTime.flatMap { songTime >= $0 && songTime - $0 < 0.5 ? $0 : nil } ?? songTime
        lastSongTime = songTime

        // The song card first: the lyrics wait until its koi has been and the card has sunk, then come in.
        if holdWhile() {
            holding = true
            releasedAt = nil
            if lastOpacity > 0 { hideLyrics() }
            return
        }
        if holding {
            holding = false
            releasedAt = now
        }
        var scene = LyricsTimeline.scene(lyrics, at: songTime)
        if let releasedAt {
            // The line being sung comes in with its style's entrance, as a new line does.
            let entry = min(1, (now - releasedAt) / LyricsTimeline.lead)
            if entry >= 1 { self.releasedAt = nil }
            scene.arrival = min(scene.arrival, entry)
            scene.previous = nil
            scene.presence *= min(1, (now - releasedAt) / LyricsTimeline.fade * 2)
        }
        guard scene.presence > 0 || lastOpacity > 0 else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if demoStart == nil { followEnergy(grid: grid, dt: now - (lastTick ?? now)) }
        lastTick = now
        // A new style takes over only as a line comes in; the line before leaves in the style it had.
        if mix.update(line: scene.current, energy: energy, roll: .random(in: 0..<1)) {
            Log.info(String(format: "lyrics style now %@ (a %@ song, %.2f; aiming at %.2f)", style.title,
                            SongIntensity.describe(songIntensity), songIntensity, energy))
            if let info = player.info { describe(info) }
        }
        let art = RockLyricsArt(style: style, still: still)
        let frame = art.render(lyrics: lyrics, scene: scene, time: songTime, since: since, beat: grid, size: geometry.canvas,
                               leavingStyle: mix.previous)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        words.contents = frame.image
        words.opacity = Float(frame.opacity)
        dim.opacity = Float(frame.opacity)
        flash.opacity = still ? 0 : Float(frame.flash * RockLyricsArt.flashStrength)
        CATransaction.commit()
        if frame.opacity > 0, !panel.isVisible {
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            Log.info("lyrics shown, window \(panel.windowNumber), \(style.title)")
        } else if frame.opacity <= 0, panel.isVisible {
            panel.orderOut(nil)
            Log.info("lyrics hidden for a break")
        }
        lastOpacity = frame.opacity

        if let pond = wallpaper.mainPond, pond.isRunning {
            for landing in frame.landings {
                let point = SIMD2(Float(geometry.band.minX + landing.point.x * geometry.canvasPoint),
                                  Float(geometry.band.minY + landing.point.y * geometry.canvasPoint))
                pond.renderer.pond.splash(at: point, strength: landing.strength, drops: 3)
            }
        }
    }

    /// Follows how intense the song is. Its words set where it starts; while the fish dance (so Koi Pond hears
    /// Music), the beat's steadiness and tempo join in over the first 20 seconds, and the song's loud and quiet
    /// parts nudge the aim up and down.
    private func followEnergy(grid: BeatGrid?, dt: Double) {
        let dt = min(max(dt, 0), 0.25)
        let level = Double(beat.music.level)
        var beatIntensity: Double?
        if store.settings.danceToMusic, level > 0.02 {
            beatHeard += dt
            beatStrength += (grid?.confidence ?? 0) * dt
            if let grid { beatTempo += (grid.beatsPerMinute - beatTempo) * min(dt / 4, 1) }
            if beatHeard > 3 {
                beatIntensity = SongIntensity.fromBeat(strength: beatStrength / beatHeard,
                                                       beatsPerMinute: beatTempo > 0 ? beatTempo : 100)
            }
            // The level is against the song's own loudest of late: how loud this part is, for this song.
            section += (min(max((level - 0.35) / 0.55, 0), 1) - section) * min(dt / 3, 1)
        }
        songIntensity = SongIntensity.combined(lyrics: lyricsIntensity, beat: beatIntensity, heard: beatHeard)
        energy = SongIntensity.energy(song: songIntensity, section: section)
    }

    private func hideLyrics() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [dim, words, flash] { layer.opacity = 0 }
        CATransaction.commit()
        panel.orderOut(nil)
        lastOpacity = 0
    }

    private func layOut(on screen: NSScreen) {
        let geometry = Geometry(screen: screen.frame)
        self.geometry = geometry
        panel.setFrame(screen.frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = screen.frame.size
        dim.frame = CGRect(origin: .zero, size: size)
        words.frame = geometry.band
        flash.frame = CGRect(origin: .zero, size: size)
        // The dimming is smooth, so a small image scaled up with filtering does.
        let scale: CGFloat = 0.125
        if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            RockLyricsArt.drawDim(in: ctx, size: size, amount: 1)
            dim.contents = ctx.makeImage()
        }
        CATransaction.commit()
    }

    // MARK: Helpers

    /// Whether the Mac's preferred languages put Traditional Chinese before Simplified.
    static var prefersTraditionalChinese: Bool {
        for language in Locale.preferredLanguages {
            let lower = language.lowercased()
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return true
            }
            if lower.hasPrefix("zh") { return false }
        }
        return false
    }

    private static func argument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static let demoLength: Double = 24.5

    /// Made up for the demo: a verse, a break, a line, then the verse back as a chorus.
    private static let demoLyrics: Lyrics = {
        func line(_ words: [(String, Double, Double)]) -> LyricLine {
            LyricLine(start: words[0].1, end: words[words.count - 1].2,
                      words: words.map { LyricWord(text: $0.0, start: $0.1, end: $0.2) })
        }
        return Lyrics(lines: [
            line([("Turn ", 1.0, 1.2), ("it ", 1.2, 1.4), ("up, ", 1.4, 1.8), ("let ", 2.0, 2.2), ("it ", 2.2, 2.4),
                  ("roll!", 2.4, 3.4)]),
            line([("今", 3.8, 4.0), ("晚", 4.0, 4.2), ("一", 4.2, 4.4), ("起", 4.4, 4.6), ("搖", 4.6, 5.0),
                  ("到", 5.0, 5.2), ("天", 5.2, 5.4), ("亮", 5.4, 6.2)]),
            line([("Hands ", 6.6, 6.8), ("up ", 6.8, 7.0), ("high!", 7.0, 7.8)]),
            line([("We ", 10.0, 10.2), ("don't ", 10.2, 10.4), ("stop, ", 10.4, 10.8), ("we ", 11.0, 11.2),
                  ("don't ", 11.2, 11.4), ("sleep", 11.4, 12.4)]),
            line([("心", 12.8, 13.0), ("跳", 13.0, 13.2), ("跟", 13.2, 13.4), ("著", 13.4, 13.6), ("鼓", 13.6, 14.0),
                  ("聲", 14.0, 15.0)]),
            line([("Turn ", 15.6, 15.8), ("it ", 15.8, 16.0), ("up, ", 16.0, 16.4), ("let ", 16.6, 16.8), ("it ", 16.8, 17.0),
                  ("roll!", 17.0, 18.0)]),
            line([("今", 18.4, 18.6), ("晚", 18.6, 18.8), ("一", 18.8, 19.0), ("起", 19.0, 19.2), ("搖", 19.2, 19.6),
                  ("到", 19.6, 19.8), ("天", 19.8, 20.0), ("亮", 20.0, 20.8)]),
            line([("Hands ", 21.2, 21.4), ("up ", 21.4, 21.6), ("high!", 21.6, 22.4)]),
        ], timing: .word, source: "demo")
    }()
}
