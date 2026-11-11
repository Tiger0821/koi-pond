import IOSurface
import KoiPondCore
import KoiPondRender
import Metal
import os
import QuartzCore
import ScreenSaver

/// The live pond as a macOS screen saver. Koi Pond.app copies this bundle to ~/Library/Screen Savers
/// and keeps `Contents/Resources/settings.json` in step with the app's settings.
///
/// The screen saver host shows this view through a remote window: MTKView's display link never fires
/// there, and startAnimation isn't always called. So frames are drawn with Metal into IOSurfaces and
/// handed to a plain Core Animation layer, driven by our own timer whenever the view is in a window.
@objc(KoiPondSaverView)
public final class KoiPondSaverView: ScreenSaverView {
    private let canvas = CALayer()
    private var renderer: PondRenderer?
    private var device: MTLDevice?
    private var surfaces: [(surface: IOSurface, texture: MTLTexture)] = []
    private var nextSurface = 0
    private var timer: Timer?
    private var lastTick: CFTimeInterval?
    private var frameInterval: TimeInterval = 1.0 / 30
    private var framesDrawn = 0
    private var stopped = false

    private static let log = Logger(subsystem: "com.koifishwallpaper.koipond.saver", category: "saver")

    override public init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        canvas.frame = bounds
        canvas.contentsGravity = .resize
        canvas.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(canvas)

        guard let ctx = MetalContext.make() else {
            Self.log.error("Metal setup failed")
            return
        }
        var settings = PondSettings.load(from: Self.settingsData())
        settings.paused = false
        frameInterval = 1 / Double(isPreview ? 20 : min(settings.frameRate.rawValue, 60))
        animationTimeInterval = frameInterval

        let size = SIMD2(Float(max(frame.width, 64)), Float(max(frame.height, 64)))
        let renderer = PondRenderer(ctx: ctx, size: size, settings: settings, seed: UInt64.random(in: 1...UInt64.max))
        // Start with the animals already spread out rather than all appearing at once.
        for _ in 0..<60 { renderer.advance(dt: 1 / 30) }
        self.renderer = renderer
        device = ctx.device

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenSaverWillStop),
                                                            name: Notification.Name("com.apple.screensaver.willstop"),
                                                            object: nil)
        Self.log.notice("created \(isPreview ? "preview" : "full screen", privacy: .public) \(NSStringFromRect(frame), privacy: .public)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startTimer() } else { stopTimer() }
    }

    override public func startAnimation() {
        super.startAnimation()
        stopped = false
        startTimer()
    }

    override public func stopAnimation() {
        super.stopAnimation()
        stopTimer()
    }

    override public func animateOneFrame() {
        // Frames come from our own timer; see the type comment.
    }

    override public func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override public var hasConfigureSheet: Bool { false }
    override public var configureSheet: NSWindow? { nil }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer?.pond.resize(to: SIMD2(Float(max(newSize.width, 64)), Float(max(newSize.height, 64))))
    }

    /// Since Sonoma the host keeps old screen saver views alive after the screen saver ends, still
    /// animating. Stop, and for the full-screen saver leave the host process as other savers do.
    @objc private func screenSaverWillStop() {
        stopped = true
        stopTimer()
        if !isPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
    }

    private func startTimer() {
        guard timer == nil, !stopped, renderer != nil else { return }
        lastTick = nil
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Drawing

    private func tick() {
        guard let renderer, bounds.width > 0, bounds.height > 0 else { return }
        let now = CACurrentMediaTime()
        renderer.advance(dt: lastTick.map { Float(now - $0) } ?? 0)
        lastTick = now

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let target = surface(width: width, height: height) else { return }
        renderer.render(into: target.texture)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        canvas.contents = target.surface
        CATransaction.commit()

        if framesDrawn == 0 || framesDrawn == 300 {
            Self.log.notice("drew frame \(self.framesDrawn, privacy: .public) at \(width, privacy: .public)x\(height, privacy: .public)")
        }
        framesDrawn += 1
    }

    /// Three surfaces in rotation, so Metal never draws into one Core Animation is still showing.
    private func surface(width: Int, height: Int) -> (surface: IOSurface, texture: MTLTexture)? {
        if surfaces.first.map({ $0.texture.width != width || $0.texture.height != height }) ?? true {
            surfaces = (0..<3).compactMap { _ in makeSurface(width: width, height: height) }
            nextSurface = 0
        }
        guard !surfaces.isEmpty else { return nil }
        defer { nextSurface = (nextSurface + 1) % surfaces.count }
        return surfaces[nextSurface]
    }

    private func makeSurface(width: Int, height: Int) -> (surface: IOSurface, texture: MTLTexture)? {
        guard let device, let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: width * 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
        return (surface, texture)
    }

    // MARK: Checks and settings

    /// How many frames have been drawn, for checking the bundle outside the screen saver host.
    @objc public var drawnFrameCount: Int { framesDrawn }

    /// The surface most recently handed to Core Animation, for the same checks.
    @objc public var displayedSurface: IOSurface? { canvas.contents as? IOSurface }

    private static func settingsData() -> Data? {
        let bundle = Bundle(for: KoiPondSaverView.self)
        guard let url = bundle.url(forResource: "settings", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}
