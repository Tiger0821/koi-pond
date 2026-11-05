import AppKit
import Combine
import KoiPondCore
import KoiPondRender

/// Takes clicks without activating Koi Pond or taking focus from the app in front.
private final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the player bitmap scaled up with nearest-neighbour filtering and turns clicks into button presses.
private final class PlayerView: NSView {
    var pointsPerPixel: CGFloat = 2
    var hovered: NowPlayingButton? { didSet { if hovered != oldValue { onChange?() } } }
    var pressed: NowPlayingButton? { didSet { if pressed != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    var onClick: ((NowPlayingButton) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: (() -> Void)?
    /// Says whether the player actually moved; if not, the press was a click.
    var onDragEnded: ((Bool) -> Void)?
    var onCoverClick: (() -> Void)?
    /// Where a press off the buttons began, on screen; it only becomes a drag once it moves a few points.
    private var downAt: NSPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A layer-hosting view: AppKit leaves the layer's contents to us.
        let canvas = CALayer()
        canvas.magnificationFilter = .nearest
        canvas.contentsGravity = .resize
        layer = canvas
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    private func artPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / pointsPerPixel, y: (bounds.height - point.y) / pointsPerPixel)
    }

    private func button(for event: NSEvent, slack: CGFloat = 0) -> NowPlayingButton? {
        NowPlayingArt.button(at: artPoint(event), slack: slack)
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = button(for: event)
        let pointing = hovered != nil || NowPlayingArt.isCover(at: artPoint(event))
        (pointing ? NSCursor.pointingHand : NSCursor.openHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        NSCursor.arrow.set()
    }

    /// A press on a button presses it. Anywhere else picks the player up to move it once the mouse moves;
    /// let go without moving on the cover, and it opens Music.
    override func mouseDown(with event: NSEvent) {
        pressed = button(for: event)
        if pressed == nil {
            downAt = NSEvent.mouseLocation
            onDragBegan?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let downAt, !dragging, hypot(NSEvent.mouseLocation.x - downAt.x, NSEvent.mouseLocation.y - downAt.y) > 3 {
            dragging = true
            NSCursor.closedHand.set()
        }
        if dragging { onDragMoved?() } else if downAt == nil { hovered = button(for: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil {
            onDragEnded?(dragging)
            if !dragging, NowPlayingArt.isCover(at: artPoint(event)) { onCoverClick?() }
            dragging = false
            downAt = nil
            NSCursor.openHand.set()
        } else if let pressed, button(for: event, slack: 3) == pressed {
            onClick?(pressed)
        }
        pressed = nil
    }
}

/// The pixel-art Apple Music player in a corner of the main display: above the desktop icons, below
/// every window, and only while Music has a song playing or paused.
final class NowPlayingWidget {
    private let store: SettingsStore
    private let player: MusicPlayer
    private let panel: PlayerPanel
    private let view: PlayerView
    private var timer: Timer?
    private var lastResync = Date.distantPast
    /// The song showing, to tell when the next one starts and to animate away from.
    private var shownKey: String?
    private var shownSong: SongFace?
    /// The song change being animated, redrawn at 30 frames a second until it's over.
    private var change: SongChange?
    private var changeTimer: Timer?
    /// Told of every new song after the first, with the transition the player picked for it.
    var onSongChange: ((SongFace?, SongFace, SongTransition) -> Void)?
    /// Where the mouse and the player were when a drag began.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init(store: SettingsStore, player: MusicPlayer) {
        self.store = store
        self.player = player
        panel = PlayerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // One level above the icons so the buttons get clicks; still far below app windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        // Hide Koi Pond (Command-H) hides its windows, not what lives on the desktop.
        panel.canHide = false
        view = PlayerView(frame: .zero)
        panel.contentView = view
    }

    func start() {
        view.onChange = { [weak self] in self?.render() }
        view.onClick = { [weak self] button in self?.player.perform(button) }
        view.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStart = (NSEvent.mouseLocation, panel.frame.origin)
        }
        view.onDragMoved = { [weak self] in self?.dragMoved() }
        view.onDragEnded = { [weak self] moved in self?.dragEnded(moved: moved) }
        view.onCoverClick = { MusicPlayer.openMusic() }
        player.onChange = { [weak self] in self?.update() }
        store.$settings.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.update()
        }.store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() })
        update()
    }

    private func update() {
        let s = store.settings
        // The fish dancing and the song card need to know what plays, even with the player hidden.
        player.setEnabled(s.nowPlaying || s.danceToMusic || s.songCard)
        noticeSongChange()
        guard s.nowPlaying, let info = player.info, let screen = NSScreen.screens.first else {
            hide()
            return
        }
        let scale = CGFloat(s.nowPlayingSize.pointsPerPixel)
        let size = CGSize(width: NowPlayingArt.size.width * scale, height: NowPlayingArt.size.height * scale)
        let area = Self.area(of: screen)
        let frame = NSRect(x: (area.minX + max(0, area.width - size.width) * CGFloat(s.nowPlayingX)).rounded(),
                           y: (area.minY + max(0, area.height - size.height) * CGFloat(s.nowPlayingY)).rounded(),
                           width: size.width, height: size.height)
        if dragStart == nil, panel.frame != frame { panel.setFrame(frame, display: false) }
        view.pointsPerPixel = scale
        render()
        if !panel.isVisible {
            panel.orderFrontRegardless()
            Log.info("now playing shown, window \(panel.windowNumber)")
        }
        // Tick once a second for the progress bar, only while a song with a known length plays.
        let ticking = info.isPlaying && info.duration != nil && info.position != nil
        if ticking, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !ticking {
            stopTimer()
        }
    }

    // MARK: Moving

    private static func area(of screen: NSScreen) -> NSRect {
        screen.visibleFrame.insetBy(dx: 20, dy: 20)
    }

    private func dragMoved() {
        guard let start = dragStart, let screen = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        let proposed = NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        panel.setFrameOrigin(Snapping.snap(proposed, size: panel.frame.size, area: Self.area(of: screen)))
    }

    private func dragEnded(moved: Bool) {
        dragStart = nil
        guard moved, let screen = NSScreen.screens.first else { return }
        let area = Self.area(of: screen), frame = panel.frame
        let x = area.width > frame.width ? (frame.minX - area.minX) / (area.width - frame.width) : 0
        let y = area.height > frame.height ? (frame.minY - area.minY) / (area.height - frame.height) : 0
        store.update {
            $0.nowPlayingX = Double(min(max(x, 0), 1))
            $0.nowPlayingY = Double(min(max(y, 0), 1))
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastResync) > 10 {
            lastResync = Date()
            player.resync()
        }
        render()
    }

    private func render() {
        guard let info = player.info else { return }
        view.layer?.contents = NowPlayingArt.image(info: info, cover: player.cover, hovered: view.hovered,
                                                   pressed: view.pressed, controllable: player.access != .denied,
                                                   change: change)
    }

    // MARK: Song changes

    /// A new song (not the first one heard, nor the same one paused and resumed) starts a transition, in a
    /// style picked at random. Skipping again mid-way starts over from the song that was arriving.
    private func noticeSongChange() {
        let info = player.info
        if let info, info.trackKey != shownKey {
            if shownKey != nil {
                let style = SongTransition.allCases.randomElement() ?? .mosaic
                change = SongChange(from: shownSong, style: style, start: CACurrentMediaTime())
                startChangeTimer()
                onSongChange?(shownSong, SongFace(title: info.title, artist: info.artist, cover: player.cover), style)
            }
            shownKey = info.trackKey
        }
        if let info { shownSong = SongFace(title: info.title, artist: info.artist, cover: player.cover) }
    }

    private func startChangeTimer() {
        changeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if change?.isOver(at: CACurrentMediaTime()) ?? true {
                change = nil
                changeTimer?.invalidate()
                changeTimer = nil
            }
            render()
        }
        RunLoop.main.add(timer, forMode: .common)
        changeTimer = timer
    }

    private func hide() {
        stopTimer()
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
