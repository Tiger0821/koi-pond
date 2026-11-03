import AppKit
import IOSurface
import Metal
import QuartzCore

/// Shows a pond on screen. Frames are rendered into IOSurfaces we own and handed to a plain layer, on the
/// view's display link. A CAMetalLayer would make every frame wait for one of its three drawables, and the
/// window server keeps those for a whole second while switching Spaces, which froze the pond.
public final class PondView: NSView {
    public let renderer: PondRenderer
    public var isPaused = true {
        didSet {
            link?.isPaused = isPaused
            if !isPaused { lastTimestamp = nil }
        }
    }
    public var preferredFramesPerSecond = 30 {
        didSet { applyFrameRate() }
    }

    private final class Frame {
        let surface: IOSurface
        let texture: MTLTexture
        var rendering = false

        init(surface: IOSurface, texture: MTLTexture) {
            self.surface = surface
            self.texture = texture
        }
    }

    private let device: MTLDevice
    private var frames: [Frame] = []
    private weak var shown: Frame?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// Frames drawn and skipped since the last debug report.
    private var tally = (drawn: 0, skipped: 0, since: CACurrentMediaTime())
    private var skippingSince: CFTimeInterval?

    public init(frame: NSRect, renderer: PondRenderer, device: MTLDevice) {
        self.renderer = renderer
        self.device = device
        super.init(frame: frame)
        // A layer-hosting view: AppKit leaves the layer's contents to us.
        let canvas = CALayer()
        canvas.contentsGravity = .resize
        canvas.isOpaque = true
        canvas.backgroundColor = .black
        layer = canvas
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        // Common modes, so the pond keeps moving while a menu is open.
        link.add(to: .main, forMode: .common)
        link.isPaused = isPaused
        self.link = link
        applyFrameRate()
    }

    private func applyFrameRate() {
        let fps = Float(preferredFramesPerSecond)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    @objc private func step() {
        drawFrame()
    }

    /// Moves the pond on to now and shows it; also the one-off redraw of a paused pond.
    public func drawFrame() {
        let now = CACurrentMediaTime()
        let dt = lastTimestamp.map { Float(now - $0) } ?? 0
        lastTimestamp = now
        renderer.tick(dt: isPaused ? 0 : dt)
        report(now)
        // Two frames still on the GPU, or every surface still on screen: skip rather than wait.
        guard frames.filter(\.rendering).count < 2, let frame = nextFrame() else {
            tally.skipped += 1
            if skippingSince == nil { skippingSince = now }
            return
        }
        if let skippingSince, now - skippingSince > 0.1, Log.debug {
            Log.info("skipped frames for \(String(format: "%.2f", now - skippingSince)) s")
        }
        skippingSince = nil
        tally.drawn += 1
        frame.rendering = true
        renderer.render(into: frame.texture) { [weak self, weak frame] in
            guard let self, let frame else { return }
            frame.rendering = false
            show(frame)
        }
    }

    private func show(_ frame: Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame.surface
        CATransaction.commit()
        shown = frame
    }

    /// A surface neither on the GPU, on screen, nor still being read by the window server.
    private func nextFrame() -> Frame? {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = max(1, Int((bounds.width * scale).rounded())), height = max(1, Int((bounds.height * scale).rounded()))
        if let first = frames.first, first.texture.width != width || first.texture.height != height {
            frames.removeAll { !$0.rendering }
        }
        if let free = frames.first(where: { !$0.rendering && $0 !== shown && !$0.surface.isInUse }) { return free }
        guard frames.count < 4, let made = makeFrame(width: width, height: height) else { return nil }
        frames.append(made)
        return made
    }

    private func makeFrame(width: Int, height: Int) -> Frame? {
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: width * 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, srgb)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
        return Frame(surface: surface, texture: texture)
    }

    private func report(_ now: CFTimeInterval) {
        guard now - tally.since > 10 else { return }
        if Log.debug { Log.info("drew \(tally.drawn) frames, skipped \(tally.skipped) in 10 s") }
        tally = (0, 0, now)
    }
}
