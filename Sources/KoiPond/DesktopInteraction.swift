import AppKit
import KoiPondRender
import KoiPondCore

/// Turns clicks on bare desktop into ripples and food, and lets the fish see the cursor.
/// The wallpaper windows ignore the mouse, so this only observes copies of clicks sent to
/// other apps (no Accessibility or Input Monitoring needed) and checks the window list to see
/// whether the click landed on the desktop.
final class DesktopInteraction {
    private let wallpaper: WallpaperController
    private let store: SettingsStore
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    /// At most one click every 0.05 s reaches the pond (faster than anyone clicks by hand), so an auto
    /// clicker can't bog it down with window-list lookups, food and splashes.
    private var clickLimit = RateLimiter(interval: 0.05)
    /// The pond whose koi is being dragged.
    private var holding: ScreenPond?
    private var cachedWindows: (time: CFTimeInterval, windows: [WindowSnapshot])?
    private var lastCursor: NSPoint?
    private var lastCursorCheck: CFTimeInterval = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

    init(wallpaper: WallpaperController, store: SettingsStore) {
        self.wallpaper = wallpaper
        self.store = store
    }

    func start() {
        registerMonitors()
        // Global monitors can go quiet after sleep or a user switch; re-register on those
        // transitions and every minute so a silent failure recovers on its own.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.registerMonitors()
            })
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.registerMonitors()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.trackCursor()
        })
    }

    private func registerMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown()
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.mouseDragged()
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseUp()
        }) {
            monitors.append(monitor)
        }
    }

    private func mouseDown() {
        guard clickLimit.allow(at: CACurrentMediaTime()) else { return }
        let point = NSEvent.mouseLocation
        guard isDesktop(point, maxAge: 0), let pond = wallpaper.screenPond(containing: point), pond.isRunning else {
            if Log.debug { Log.info("click seen, not on a running pond: \(clickBlocker(point))") }
            return
        }
        let s = store.settings
        let world = pond.world(from: point)
        // Pressing on a koi picks it up; anywhere else touches the water and feeds.
        if pond.renderer.pond.grab(at: world) {
            holding = pond
            return
        }
        pond.renderer.pond.touch(at: world, ripple: s.touchRipples)
        if s.feedTheFish {
            // One splash per click: the touch's, or the food's own when touch ripples are off.
            pond.renderer.pond.dropFood(at: world, count: 4, ripple: !s.touchRipples)
        }
        if Log.debug { Log.info("desktop click at \(Int(world.x)),\(Int(world.y)) on display \(pond.displayID)") }
    }

    private func mouseDragged() {
        guard let holding else { return }
        holding.renderer.pond.drag(to: holding.world(from: NSEvent.mouseLocation))
    }

    private func mouseUp() {
        holding?.renderer.pond.release()
        holding = nil
    }

    private func trackCursor() {
        guard wallpaper.isAnyRunning else { return }
        let point = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if point == lastCursor && now - lastCursorCheck < 1 { return }
        lastCursor = point
        lastCursorCheck = now
        wallpaper.setCursor(isDesktop(point, maxAge: 0.3) ? point : nil)
    }

    private func clickBlocker(_ point: NSPoint) -> String {
        guard let w = DesktopHitTest.blocker(at: WindowList.quartzPoint(point), windows: cachedWindows?.windows ?? [],
                                             ownPID: ownPID, iconLevel: iconLevel,
                                             screens: NSScreen.screens.map { WindowList.quartzRect($0.frame) })
        else { return "the pond is resting or off screen" }
        return "\(w.ownerName) window (layer \(w.layer)) at \(Int(w.bounds.minX)),\(Int(w.bounds.minY)) \(Int(w.bounds.width))x\(Int(w.bounds.height))"
    }

    private func isDesktop(_ point: NSPoint, maxAge: CFTimeInterval) -> Bool {
        let now = CACurrentMediaTime()
        let windows: [WindowSnapshot]
        if let cachedWindows, now - cachedWindows.time <= maxAge {
            windows = cachedWindows.windows
        } else {
            windows = WindowList.snapshot()
            cachedWindows = (now, windows)
        }
        return DesktopHitTest.isDesktop(at: WindowList.quartzPoint(point), windows: windows, ownPID: ownPID,
                                        iconLevel: iconLevel,
                                        screens: NSScreen.screens.map { WindowList.quartzRect($0.frame) })
    }
}
