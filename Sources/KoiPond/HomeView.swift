import AppKit
import Combine
import KoiPondCore
import KoiPondRender
import SwiftUI

/// The window Koi Pond opens on: a live pond to play with and change at a glance, and where else the pond
/// lives (desktop, lock screen, screen saver, Music), each a switch away. Everything else is in Settings.
final class HomeWindowController: NSObject, NSWindowDelegate {
    private let ctx: MetalContext
    private let store: SettingsStore
    private let lockScreen: LockScreenInstaller
    private let screenSaver: ScreenSaverInstaller
    private let music: MusicPlayer
    private let beat: MusicBeat
    private let openSettings: (SettingsPane) -> Void
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    init(ctx: MetalContext, store: SettingsStore, lockScreen: LockScreenInstaller, screenSaver: ScreenSaverInstaller,
         music: MusicPlayer, beat: MusicBeat, openSettings: @escaping (SettingsPane) -> Void) {
        self.ctx = ctx
        self.store = store
        self.lockScreen = lockScreen
        self.screenSaver = screenSaver
        self.music = music
        self.beat = beat
        self.openSettings = openSettings
    }

    func show() {
        if window == nil { build() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let preview = PondPreviewView(ctx: ctx, store: store, music: { [beat] in beat.music })
        let home = HomeView(store: store, lockScreen: lockScreen, screenSaver: screenSaver, music: music, preview: preview,
                            openSettings: openSettings)
        let host = NSHostingController(rootView: home)
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Koi Pond"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 800))
        window.delegate = self
        if !window.setFrameUsingName("KoiPondHome") { window.center() }
        window.setFrameAutosaveName("KoiPondHome")
        self.window = window
    }
}

/// A live pond of its own, at the desktop's proportions, that plays only while it can be seen. Clicking it
/// touches the water and feeds the fish, and a koi can be picked up and flung, as on the desktop.
final class PondPreviewView: NSView {
    let aspect: CGFloat
    private let world: SIMD2<Float>
    private let renderer: PondRenderer
    private let pond: PondView
    private let store: SettingsStore
    private var cancellable: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var holding = false

    init(ctx: MetalContext, store: SettingsStore, music: @escaping () -> PondMusic) {
        let size = (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? CGSize(width: 1512, height: 982)
        world = SIMD2(Float(size.width), Float(size.height))
        aspect = size.width / size.height
        renderer = PondRenderer(ctx: ctx, size: world, settings: store.settings, seed: 0x686F_6D65)
        renderer.music = music
        // Let the animals spread out before the first frame.
        for _ in 0..<90 { renderer.advance(dt: 1 / 30) }
        pond = PondView(frame: .zero, renderer: renderer, device: ctx.device)
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        pond.autoresizingMask = [.width, .height]
        addSubview(pond)
        cancellable = store.$settings.receive(on: RunLoop.main).sink { [weak self] settings in
            guard let self else { return }
            renderer.apply(settings)
            pond.preferredFramesPerSecond = min(settings.frameRate.rawValue, 60)
            updateRunning()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    self?.updateRunning(closing: note.name == NSWindow.willCloseNotification)
                })
            }
        }
        updateRunning()
    }

    override func layout() {
        super.layout()
        pond.frame = bounds
        if pond.isPaused { pond.drawFrame() }
    }

    /// Plays while the window is on screen and the pond isn't paused; otherwise holds a still frame, or stops.
    private func updateRunning(closing: Bool = false) {
        let visible = !closing && (window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
        let running = visible && !store.settings.paused
        renderer.advancing = running
        pond.isPaused = !running
        if visible, !running { pond.drawFrame() }
    }

    private func worldPoint(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x / max(bounds.width, 1)) * world.x, Float(p.y / max(bounds.height, 1)) * world.y)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = worldPoint(event)
        if renderer.pond.grab(at: point) {
            holding = true
            NSCursor.closedHand.set()
            return
        }
        let s = store.settings
        renderer.pond.touch(at: point, ripple: s.touchRipples)
        if s.feedTheFish { renderer.pond.dropFood(at: point, count: 4, ripple: !s.touchRipples) }
        if pond.isPaused { pond.drawFrame() }
    }

    override func mouseDragged(with event: NSEvent) {
        if holding { renderer.pond.drag(to: worldPoint(event)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard holding else { return }
        renderer.pond.release()
        holding = false
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct PondPreview: NSViewRepresentable {
    let view: PondPreviewView
    func makeNSView(context: Context) -> PondPreviewView { view }
    func updateNSView(_ nsView: PondPreviewView, context: Context) {}
}

/// Liquid Glass on macOS 26 and later, frosted material before it.
private struct Glass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

private extension View {
    func glass<S: Shape>(in shape: S) -> some View { modifier(Glass(shape: shape)) }
}

struct HomeView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var lockScreen: LockScreenInstaller
    @ObservedObject var screenSaver: ScreenSaverInstaller
    @ObservedObject var music: MusicPlayer
    let preview: PondPreviewView
    let openSettings: (SettingsPane) -> Void
    @AppStorage("HomeTipsDismissed") private var tipsDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    desktopCard
                    lockScreenCard
                    screenSaverCard
                    musicCard
                }
                if !tipsDismissed { tips }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 600, minHeight: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Koi Pond").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(store.settings.paused ? "Your pond is paused" : "Your pond is alive behind your desktop")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openSettings(.general)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.large)
            .help("All settings (⌘,)")
        }
        .padding(.top, 4)
    }

    // MARK: The live pond

    private var hero: some View {
        PondPreview(view: preview)
            .aspectRatio(preview.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .overlay(alignment: .topLeading) {
                Label("Live · click the water", systemImage: "hand.tap.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glass(in: Capsule())
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    store.update { $0.paused.toggle() }
                } label: {
                    Image(systemName: store.settings.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glass(in: Circle())
                .padding(12)
                .help(store.settings.paused ? "Resume the pond" : "Pause the pond")
            }
            .overlay(alignment: .bottom) { lookBar.padding(12) }
    }

    /// The weather and the water's color, changed right where they show.
    private var lookBar: some View {
        HStack(spacing: 2) {
            ForEach(WeatherPreset.allCases, id: \.self) { weather in
                let chosen = store.settings.weather == weather
                Button {
                    store.update { $0.weather = weather }
                } label: {
                    Image(systemName: weather.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .background(chosen ? Color.white.opacity(0.28) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(weather.title)
                .accessibilityLabel(weather.title)
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            WaterSwatches(store: store)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glass(in: Capsule())
    }

    // MARK: Where the pond lives

    private var desktopCard: some View {
        FeatureCard(symbol: "menubar.dock.rectangle", tint: .teal, title: "Desktop",
                    status: store.settings.paused ? "Paused"
                        : "Pixel art · \(store.settings.frameRate == .max ? "up to 120 fps" : store.settings.frameRate.title)",
                    isOn: Binding(get: { !store.settings.paused }, set: { on in store.update { $0.paused = !on } }),
                    options: { openSettings(.pond) })
    }

    private var lockScreenCard: some View {
        FeatureCard(symbol: "lock.fill", tint: .indigo, title: "Lock Screen",
                    status: lockScreen.statusText, isOn: store.binding(\.animatedLockScreen),
                    options: { openSettings(.lockScreen) })
    }

    private var screenSaverCard: some View {
        FeatureCard(symbol: "sparkles.tv.fill", tint: .purple, title: "Screen Saver",
                    status: store.settings.pondScreenSaver ? screenSaver.status : "Off",
                    isOn: store.binding(\.pondScreenSaver), options: { openSettings(.lockScreen) })
    }

    private var musicCard: some View {
        let status: String = if let info = music.info, store.settings.nowPlaying {
            "\(music.isPlaying ? "Playing" : "Paused"): \(info.title)"
        } else {
            store.settings.nowPlaying ? music.status : "Off"
        }
        return FeatureCard(symbol: "music.note", tint: .pink, title: "Music", status: status,
                           isOn: store.binding(\.nowPlaying), options: { openSettings(.music) })
    }

    private var tips: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            Text("Click bare desktop to feed the fish, press on a koi to pick it up, and play something in Music to watch them dance.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                tipsDismissed = true
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide this tip")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One place the pond lives: what it is, how it's doing, a switch, and the way to its settings.
private struct FeatureCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let status: String
    @Binding var isOn: Bool
    let options: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
                Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text(title).font(.headline)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Button("Options…", action: options)
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}
