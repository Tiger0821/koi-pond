import AppKit
import ImageIO
import KoiPondCore
import QuartzCore
import UniformTypeIdentifiers

/// When Koi Pond opens, ten koi burst up out of the pond and charge the screen together: a ragged volley, each
/// a few hundredths of a second off the others rather than one after another. They grow in true perspective
/// (size as one over distance, so they creep up and then fill the screen at the last instant), slam into the
/// glass all over it in a quick run of thuds, each with its own white impact frame and a jolt of the screen,
/// hang there squashed and X-eyed, then peel off at their own moments and slide down the glass, leaving wet
/// trails and drops. The biggest hits dead center, last. It plays in a click-through window above everything
/// for under three seconds, so it's seen even with windows open.
final class LaunchCharge {
    private let panel: NSPanel
    private let stage = CALayer()
    private var fishLayers: [CALayer] = []
    private var trails: [CALayer] = []
    private var drops: [Drop] = []
    private var plan: Plan?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var landed: Set<Int> = []
    private var ticker: Timer?

    private struct Drop {
        let layer: CALayer
        var position: CGPoint
        var velocity: CGVector
        let slide: CGFloat
        let born: Double
    }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        // Hide Koi Pond (Command-H) hides its windows, not what lives on the desktop.
        panel.canHide = false
        let host = NSView()
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        root.addSublayer(stage)
        panel.contentView = host
    }

    /// Plays the show on the display with the pointer, where the app was just opened from.
    func play() {
        let mouse = NSEvent.mouseLocation
        guard plan == nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        var random = SystemRandomNumberGenerator()
        let plan = Plan(size: screen.frame.size, using: &random)
        self.plan = plan
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(origin: .zero, size: screen.frame.size)
        for _ in plan.fish {
            let trail = CALayer(), fish = CALayer()
            for layer in [trail, fish] {
                layer.magnificationFilter = .nearest
                layer.contentsGravity = .resize
                layer.opacity = 0
                stage.addSublayer(layer)
            }
            trails.append(trail)
            fishLayers.append(fish)
        }
        CATransaction.commit()
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        start = CACurrentMediaTime()
        last = start
        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        step()
    }

    private func step() {
        guard let plan else { return }
        let now = CACurrentMediaTime(), t = now - start, dt = now - last
        last = now
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, fish) in plan.fish.enumerated() {
            let layer = fishLayers[i]
            guard let frame = plan.frame(fish, at: t, calm: calm) else {
                layer.opacity = 0
                trails[i].opacity = Float(max(0, 1 - (t - fish.gone) / 0.5))
                continue
            }
            layer.contents = KoiFace.image(look: fish.look, pose: frame.pose, beat: frame.beat, flash: frame.flash)
            layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(KoiFace.size) * frame.scale, height: CGFloat(KoiFace.size) * frame.scale)
            layer.position = frame.position
            layer.transform = CATransform3DRotate(CATransform3DMakeScale(frame.stretch.x, frame.stretch.y, 1), frame.angle, 0, 0, 1)
            layer.opacity = frame.opacity
            layer.zPosition = frame.layer
            if t >= fish.hit, !landed.contains(i) {
                landed.insert(i)
                spawnDrops(at: fish.impact, scale: fish.near, t: t)
            }
            if t >= fish.peel { trail(fish, index: i, fishAt: frame.position) }
        }
        let shake = calm ? .zero : plan.shake(at: t)
        stage.position = CGPoint(x: stage.bounds.midX + shake.dx, y: stage.bounds.midY + shake.dy)
        updateDrops(t: t, dt: dt)
        CATransaction.commit()
        if t >= plan.duration { finish() }
    }

    /// The wet streak from where the mouth met the glass down to the sliding fish, in the fish's own pixels.
    private func trail(_ fish: Fish, index: Int, fishAt position: CGPoint) {
        let unit = fish.near
        let top = fish.impact.y - 10 * unit
        let rows = Int(((top - position.y) / unit).rounded(.down))
        let slant = Int(((position.x - fish.impact.x) / unit).rounded())
        guard rows > 0, let image = SongCard.WetTrail.image(width: 18, rows: rows, slant: slant, seed: fish.seed) else { return }
        let left = min(fish.impact.x, position.x) - CGFloat(18 / 2 + SongCard.WetTrail.margin) * unit
        let layer = trails[index]
        layer.contents = image
        layer.frame = CGRect(x: left, y: top - CGFloat(image.height) * unit, width: CGFloat(image.width) * unit,
                             height: CGFloat(image.height) * unit)
        layer.zPosition = 150
        layer.opacity = 1
    }

    /// Water thrown off by a hit, flying out and sticking to the glass.
    private func spawnDrops(at point: CGPoint, scale: CGFloat, t: Double) {
        for _ in 0..<7 {
            let angle = Double.random(in: 0...(2 * .pi)), speed = Double.random(in: 350...1100)
            let size = CGFloat(Int.random(in: 2...max(3, Int(scale * 0.8))))
            let layer = CALayer()
            layer.contents = SongCard.dropImage
            layer.magnificationFilter = .nearest
            layer.bounds = CGRect(x: 0, y: 0, width: 5 * size, height: 7 * size)
            layer.position = point
            layer.zPosition = 400
            stage.addSublayer(layer)
            drops.append(Drop(layer: layer, position: point, velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                              slide: CGFloat.random(in: 10...40), born: t))
        }
    }

    private func updateDrops(t: Double, dt: Double) {
        for i in drops.indices {
            var drop = drops[i]
            if hypot(drop.velocity.dx, drop.velocity.dy) > 15 {
                drop.position.x += drop.velocity.dx * dt
                drop.position.y += drop.velocity.dy * dt
                let drag = exp(-dt * 12)
                drop.velocity = CGVector(dx: drop.velocity.dx * drag, dy: drop.velocity.dy * drag)
            } else {
                drop.position.y -= drop.slide * dt
            }
            drop.layer.position = drop.position
            drop.layer.opacity = Float(max(0, 1 - (t - drop.born - 0.9) / 0.7))
            drops[i] = drop
        }
    }

    private func finish() {
        ticker?.invalidate()
        ticker = nil
        plan = nil
        landed.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (fishLayers + trails + drops.map(\.layer)).forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        fishLayers.removeAll()
        trails.removeAll()
        drops.removeAll()
        panel.orderOut(nil)
    }

    // MARK: The choreography

    /// One koi's run. Times are seconds from the start of the show; points are the window's, y up.
    struct Fish {
        let look: KoiVariety.Look
        /// Where it leaves the water, and where it hits the glass.
        let launch: CGPoint
        let impact: CGPoint
        /// Points per art pixel as it leaves the water, and on the glass.
        let far: CGFloat
        let near: CGFloat
        /// When it coils to burst out, and when it lets go of the glass.
        let start: Double
        let peel: Double
        /// Sideways speed as it slides down, in points a second.
        let drift: CGFloat
        let seed: Double
        var hit: Double { start + Plan.windUp + Plan.travel }
        var gone: Double { peel + Plan.slide }
    }

    /// How one koi looks at one moment.
    struct Frame {
        var position: CGPoint
        var scale: CGFloat
        var stretch: (x: CGFloat, y: CGFloat)
        var angle: CGFloat
        var pose: KoiFace.Pose
        var beat: Double
        var flash: Bool
        var opacity: Float
        /// Draw order: nearer koi in front while they fly, and on the glass the later hit lands on top.
        var layer: CGFloat
    }

    /// Where each koi comes from and hits, and when. Drawn fresh each launch, so no two are alike.
    struct Plan {
        /// Each koi coils this long, then takes this long to reach the glass.
        static let windUp = 0.16
        static let travel = 0.4
        /// The hit-stop: held at the moment of contact, the first half in white.
        static let freeze = 0.06
        /// From letting go of the glass to out of sight.
        static let slide = 0.95
        /// The last koi sets off this long after the first: together, but not in step.
        static let spread = 0.1

        let size: CGSize
        let fish: [Fish]

        var duration: Double {
            max(fish.map(\.gone).max() ?? 0, (fish.map(\.hit).max() ?? 0) + 1.65) + 0.05
        }

        init(size: CGSize, using random: inout some RandomNumberGenerator) {
            self.size = size
            let w = size.width, h = size.height
            let center = CGPoint(x: w / 2, y: h / 2)
            // Spread over the whole screen, with the biggest dead center and last.
            let spots: [(x: CGFloat, y: CGFloat)] = [(0.15, 0.74), (0.4, 0.8), (0.64, 0.76), (0.87, 0.7), (0.21, 0.47),
                                                     (0.79, 0.46), (0.13, 0.2), (0.4, 0.22), (0.69, 0.2), (0.5, 0.5)]
            let looks = KoiVariety.allCases.shuffled(using: &random).map { $0.designs.randomElement(using: &random) ?? $0.look }
            let order = Array(0..<(spots.count - 1)).shuffled(using: &random)
            var fish: [Fish] = []
            for (i, spot) in spots.enumerated() {
                let last = i == spots.count - 1
                let wobble = last ? 0.012 : 0.035
                let impact = CGPoint(x: (spot.x + CGFloat.random(in: -wobble...wobble, using: &random)) * w,
                                     y: (spot.y + CGFloat.random(in: -wobble...wobble, using: &random)) * h)
                // They break the surface bunched toward the middle and fan out as they come, so the volley
                // reads as coming straight at you.
                let launch = CGPoint(x: center.x + (impact.x - center.x) * 0.3 + CGFloat.random(in: -24...24, using: &random),
                                     y: center.y + (impact.y - center.y) * 0.3 + CGFloat.random(in: -24...24, using: &random))
                let height = last ? 0.54 : CGFloat.random(in: 0.3...0.42, using: &random)
                let near = max((h * height / CGFloat(KoiFace.size)).rounded(.down), 3)
                let start = last ? Self.spread
                    : max(0, Double(order[i]) / Double(spots.count - 2) * Self.spread * 0.85 + Double.random(in: -0.012...0.012, using: &random))
                let hit = start + Self.windUp + Self.travel
                let hang = last ? 0.75 : Double.random(in: 0.45...0.85, using: &random)
                fish.append(Fish(look: looks[i % looks.count], launch: launch, impact: impact, far: 0.5, near: near,
                                 start: start, peel: hit + Self.freeze + hang,
                                 drift: (impact.x < center.x ? -1 : 1) * CGFloat.random(in: 8...40, using: &random),
                                 seed: Double.random(in: 0...100, using: &random)))
            }
            self.fish = fish
        }

        func frame(_ f: Fish, at t: Double, calm: Bool) -> Frame? {
            let s = t - f.start
            guard s >= 0, t < f.gone else { return nil }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var frame = Frame(position: f.impact, scale: f.near, stretch: (1, 1), angle: 0, pose: .charging,
                              beat: t * 28 + f.seed, flash: false, opacity: 1, layer: 200 + CGFloat(f.hit) * 100)
            if s < Self.windUp {
                // Anticipation: it sinks a little and coils before the burst.
                let coil = CGFloat(sin(s / Self.windUp * .pi))
                frame.scale = f.far * (1 - 0.15 * coil)
                frame.position = f.launch
                frame.stretch = (1 + 0.14 * coil, 1 - 0.14 * coil)
                frame.beat = t * 10 + f.seed
                frame.layer = 0
            } else if t < f.hit {
                // Straight at the lens at a steady speed in depth: it creeps up, then fills its spot at the end.
                let p = CGFloat((s - Self.windUp) / Self.travel)
                let nearest = f.far / f.near
                let z = 1 - (1 - nearest) * p
                let from = CGPoint(x: f.launch.x - center.x, y: f.launch.y - center.y)
                let to = CGPoint(x: (f.impact.x - center.x) * nearest, y: (f.impact.y - center.y) * nearest)
                frame.scale = f.far / z
                frame.position = CGPoint(x: center.x + (from.x + (to.x - from.x) * p) / z,
                                         y: center.y + (from.y + (to.y - from.y) * p) / z)
                frame.stretch = (1 - 0.06 * p, 1 + 0.1 * p)
                frame.angle = 0.06 * CGFloat(sin(t * 9 + f.seed))
                frame.layer = 100 * (1 - z)
            } else if t < f.peel {
                let since = t - f.hit
                if since < Self.freeze {
                    frame.flash = since < Self.freeze / 2 && !calm
                } else {
                    // Squashed flat on the glass, keeping its volume, jiggling as it settles.
                    let jiggle = CGFloat(exp(-(since - Self.freeze) * 7) * cos((since - Self.freeze) * 22))
                    frame.stretch = (1.06 + 0.32 * jiggle, 0.95 - 0.28 * jiggle)
                    frame.pose = .splat
                }
                frame.beat = f.seed
            } else {
                // It peels off and slides down the glass, slow then faster, falling away from the lens.
                let since = t - f.peel
                frame.scale = f.near * CGFloat(1 - 0.4 * since / Self.slide)
                frame.position = CGPoint(x: f.impact.x + f.drift * CGFloat(since),
                                         y: f.impact.y - CGFloat(0.5 * 1300 * since * since))
                frame.angle = CGFloat(-0.3 * since) * (f.drift < 0 ? -1 : 1)
                frame.stretch = (1.04, 0.97)
                frame.pose = .dazed
                frame.beat = t * 4 + f.seed
                frame.opacity = Float(min(1, (Self.slide - since) / 0.25))
            }
            return frame
        }

        /// Every hit jolts the screen; jolts close together add up, to a limit.
        func shake(at t: Double) -> CGVector {
            var amount = 0.0
            for f in fish {
                let since = t - f.hit
                if since >= 0, since < 0.3 { amount += 7 * exp(-since / 0.07) }
            }
            amount = min(amount, 16)
            return CGVector(dx: amount * sin(t * 97), dy: amount * cos(t * 83))
        }
    }
}

/// A repeatable random source, for previews.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `KoiPond --launch-preview out.png [--seed 1] [--times 0.1,0.3,…]` draws frames of the launch show side by side,
/// a quarter size, on pond-colored glass, with each frame's time.
enum LaunchChargePreview {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--launch-preview"), index + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let times = value("--times")?.split(separator: ",").compactMap { Double($0) }
            ?? [0.08, 0.3, 0.5, 0.62, 0.7, 0.8, 0.9, 1.1, 1.4, 1.7, 2.0, 2.3]
        var random = SeededRandom(seed: UInt64(value("--seed") ?? "1") ?? 1)
        let size = CGSize(width: 1512, height: 982)
        let plan = LaunchCharge.Plan(size: size, using: &random)
        let quarter: CGFloat = 0.25, columns = 4
        let cell = CGSize(width: size.width * quarter, height: size.height * quarter)
        let rows = (times.count + columns - 1) / columns
        let width = Int(cell.width) * columns, height = Int(cell.height) * rows
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[index + 1]) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        ctx.interpolationQuality = .none
        for (n, t) in times.enumerated() {
            let origin = CGPoint(x: CGFloat(n % columns) * cell.width, y: CGFloat(rows - 1 - n / columns) * cell.height)
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: origin, size: cell))
            ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.43, blue: 0.41, alpha: 1))
            ctx.fill(CGRect(origin: origin, size: cell))
            let shake = plan.shake(at: t)
            ctx.translateBy(x: origin.x + shake.dx * quarter, y: origin.y + shake.dy * quarter)
            ctx.scaleBy(x: quarter, y: quarter)
            let frames = plan.fish.compactMap { f in plan.frame(f, at: t, calm: false).map { (f, $0) } }.sorted { $0.1.layer < $1.1.layer }
            for (f, frame) in frames {
                guard let image = KoiFace.image(look: f.look, pose: frame.pose, beat: frame.beat, flash: frame.flash) else { continue }
                let side = CGFloat(KoiFace.size) * frame.scale
                ctx.saveGState()
                ctx.setAlpha(CGFloat(frame.opacity))
                ctx.translateBy(x: frame.position.x, y: frame.position.y)
                ctx.rotate(by: frame.angle)
                ctx.scaleBy(x: frame.stretch.x, y: frame.stretch.y)
                ctx.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                ctx.restoreGState()
            }
            ctx.restoreGState()
            let label = NSAttributedString(string: String(format: "%.2f s", t), attributes: [
                .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white,
            ])
            let line = CTLineCreateWithAttributedString(label)
            ctx.textPosition = CGPoint(x: origin.x + 8, y: origin.y + 8)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        print(String(format: "hits from %.2f to %.2f s, done at %.2f s", plan.fish.map(\.hit).min() ?? 0,
                     plan.fish.map(\.hit).max() ?? 0, plan.duration))
        return CGImageDestinationFinalize(destination)
    }
}
