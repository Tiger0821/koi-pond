import AppKit
import KoiPondRender
import Combine
import KoiPondCore

/// One borderless window per display, parked just above the desktop picture and below the icons.
final class ScreenPond {
    let displayID: CGDirectDisplayID
    private(set) var frame: NSRect
    let window: NSWindow
    let view: PondView
    let renderer: PondRenderer

    var isRunning: Bool { !view.isPaused }

    init(screen: NSScreen, displayID: CGDirectDisplayID, ctx: MetalContext, settings: PondSettings) {
        self.displayID = displayID
        frame = screen.frame
        renderer = PondRenderer(ctx: ctx, size: SIMD2(Float(frame.width), Float(frame.height)),
                                backingScale: Float(screen.backingScaleFactor), settings: settings,
                                seed: UInt64(displayID) &+ 0x6B6F69)

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        // Stationary keeps the window (and the animation) in place across Space switches.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Clicks fall through to Finder; DesktopInteraction watches them separately.
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.canHide = false
        window.isExcludedFromWindowsMenu = true

        view = PondView(frame: NSRect(origin: .zero, size: frame.size), renderer: renderer, device: ctx.device)
        view.preferredFramesPerSecond = settings.frameRate.rawValue
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
    }

    func update(screen: NSScreen) {
        frame = screen.frame
        window.setFrame(frame, display: true)
        renderer.backingScale = Float(screen.backingScaleFactor)
        renderer.pond.resize(to: SIMD2(Float(frame.width), Float(frame.height)))
        redrawIfPaused()
    }

    func setRunning(_ running: Bool, fps: Int) {
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        guard isRunning != running else { return }
        renderer.advancing = running
        view.isPaused = !running
    }

    /// A paused pond is a still wallpaper; redraw it once so setting changes still show.
    func redrawIfPaused() {
        if view.isPaused { view.drawFrame() }
    }

    func world(from point: NSPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x - frame.minX), Float(point.y - frame.minY))
    }

    func close() {
        view.isPaused = true
        window.orderOut(nil)
        window.close()
    }
}

/// Keeps a pond on every display and decides when each one runs, slows or rests.
final class WallpaperController {
    private let ctx: MetalContext
    private let store: SettingsStore
    private let power: PowerMonitor
    private(set) var screens: [CGDirectDisplayID: ScreenPond] = [:]
    private var covered: Set<CGDirectDisplayID> = []
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var coverageTimer: Timer?
    private var pendingRebuild: DispatchWorkItem?
    private var lastRunState = ""
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// What the fish dance to; given to every display's pond.
    var music: (() -> PondMusic)?

    init(ctx: MetalContext, store: SettingsStore, power: PowerMonitor) {
        self.ctx = ctx
        self.store = store
        self.power = power
    }

    var isAnyRunning: Bool { screens.values.contains { $0.isRunning } }

    /// The pond on the display with the menu bar.
    var mainPond: ScreenPond? {
        guard let number = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return screens[CGDirectDisplayID(number.uint32Value)]
    }

    func start() {
        rebuildScreens()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRebuild() })
        // Re-assert ordering after Space switches so the pond never shows up late.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screens.values.forEach { $0.window.orderFrontRegardless() }
            self?.checkCoverage()
        })
        // Delivered on the next run loop pass, after the store has taken the new value.
        store.$settings.dropFirst().receive(on: RunLoop.main).sink { [weak self] settings in
            self?.settingsChanged(settings)
        }.store(in: &cancellables)
        power.onChange = { [weak self] in self?.updateRunState() }
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkCoverage()
        }
    }

    func screenPond(containing point: NSPoint) -> ScreenPond? {
        screens.values.first { NSMouseInRect(point, $0.frame, false) }
    }

    func setCursor(_ point: NSPoint?) {
        for pond in screens.values {
            if let point, NSMouseInRect(point, pond.frame, false) {
                pond.renderer.pond.cursor = pond.world(from: point)
            } else {
                pond.renderer.pond.cursor = nil
            }
        }
    }

    private func scheduleRebuild() {
        // Display changes arrive in bursts; settle before rebuilding.
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildScreens() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuildScreens() {
        var next: [CGDirectDisplayID: ScreenPond] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if let existing = screens[id] {
                existing.update(screen: screen)
                next[id] = existing
            } else {
                let pond = ScreenPond(screen: screen, displayID: id, ctx: ctx, settings: store.settings)
                pond.renderer.music = music
                next[id] = pond
            }
        }
        for (id, pond) in screens where next[id] == nil { pond.close() }
        screens = next
        covered = covered.intersection(next.keys)
        updateRunState()
        Log.info("ponds on \(screens.count) display(s)")
    }

    private func settingsChanged(_ settings: PondSettings) {
        for pond in screens.values { pond.renderer.apply(settings) }
        updateRunState()
        checkCoverage()
        for pond in screens.values { pond.redrawIfPaused() }
    }

    func updateRunState() {
        let s = store.settings
        var reasons: [String] = []
        if s.paused { reasons.append("paused from the menu") }
        if power.isAsleep { reasons.append("asleep or locked") }
        if power.onBattery && s.onBattery == .pause { reasons.append("on battery") }
        if power.lowPower && s.pauseInLowPower { reasons.append("Low Power Mode") }
        let slow = (power.onBattery && s.onBattery == .slowDown) || (power.lowPower && !s.pauseInLowPower)
            || power.thermalHot
        let fps = slow ? min(24, s.frameRate.rawValue) : s.frameRate.rawValue
        var states: [String] = []
        for (id, pond) in screens {
            var screenReasons = reasons
            if s.pauseWhenCovered && covered.contains(id) { screenReasons.append("covered by windows") }
            pond.setRunning(screenReasons.isEmpty, fps: fps)
            states.append(screenReasons.isEmpty ? "moving at \(fps) fps" : "resting (\(screenReasons.joined(separator: ", ")))")
        }
        let summary = states.joined(separator: "; ")
        if summary != lastRunState {
            lastRunState = summary
            Log.info("pond \(summary)")
        }
    }

    /// Rests a display's pond while app windows hide most of it (or a full-screen app owns it).
    private func checkCoverage() {
        var next: Set<CGDirectDisplayID> = []
        if store.settings.pauseWhenCovered && !store.settings.paused {
            let windows = WindowList.snapshot()
            for (id, pond) in screens {
                let fraction = DesktopHitTest.coveredFraction(of: WindowList.quartzRect(pond.frame), windows: windows,
                                                              ownPID: ownPID)
                if fraction >= 0.85 { next.insert(id) }
            }
        }
        guard next != covered else { return }
        covered = next
        updateRunState()
    }
}
