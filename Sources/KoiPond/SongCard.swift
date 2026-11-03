import AppKit
import KoiPondCore
import KoiPondRender
import QuartzCore

/// When the song changes, a koi bursts up out of the middle of the pond head-first and smacks into the
/// glass, slapping a big card of the new song onto it. It hangs there flattened, X-eyed, then slides
/// down the glass and drops back into the pond, uncovering the card as it goes; the card plays the song's
/// transition, rests a few seconds and sinks back with a splash.
///
/// Played the way animators sell a hit: a wind-up before the burst; true perspective on the way in (size
/// as one over distance, so it creeps up and then fills the screen at the last moment); a hit-stop with a
/// single white impact frame and a short, small shake; squash and stretch that keeps the fish's volume;
/// and drops left on the glass. It sits just above the pond, below the desktop icons and every window,
/// and never takes a click.
final class SongCard {
    private let store: SettingsStore
    private let player: MusicPlayer
    private let wallpaper: WallpaperController
    private let panel: NSPanel
    private let stage = CALayer()
    private let shadow = CALayer()
    private let card = CALayer()
    private let smear = CALayer()
    private let fish = CALayer()
    private var drops: [Drop] = []
    private var show: Show?
    private var ticker: Timer?
    private var pending: [DispatchWorkItem] = []

    /// Seconds from the song change.
    private enum Cue {
        /// The koi coils before bursting up.
        static let windUp = 0.18
        /// It reaches the glass.
        static let hit = 0.8
        /// The hit-stop: everything holds, the first half in a white flash.
        static let freeze = 0.07
        /// It starts sliding down the glass, and the card's transition begins.
        static let peel = 1.6
        /// It has dropped back into the pond.
        static let gone = 2.8
        /// The card sinks.
        static var sink: Double { peel + SongTransition.duration + 3.2 }
    }

    private struct Show {
        let start: CFTimeInterval
        /// Where the koi left the water and where it hits the glass, in the panel's points.
        let launch: CGPoint
        let impact: CGPoint
        let look: KoiVariety.Look
        /// The fish's points per art pixel as it leaves the water, and on the glass.
        let far: CGFloat
        let near: CGFloat
        let style: SongTransition
        var song: SongFace
        let songKey: String?
        var last: CFTimeInterval
        var beat = 0.0
        var frame = 0
        var hit = false
        var change: SongChange?
        var returned = false
        var sinking = false
    }

    private struct Drop {
        let layer: CALayer
        var position: CGPoint
        var velocity: CGVector
        let slide: CGFloat
    }

    init(store: SettingsStore, player: MusicPlayer, wallpaper: WallpaperController) {
        self.store = store
        self.player = player
        self.wallpaper = wallpaper
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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

        let host = NSView()
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        shadow.backgroundColor = CGColor(gray: 0, alpha: 1)
        smear.backgroundColor = CGColor(srgbRed: 0.85, green: 0.95, blue: 1, alpha: 0.13)
        for layer in [card, fish] {
            layer.magnificationFilter = .nearest
            layer.contentsGravity = .resize
        }
        for layer in [shadow, card, smear, fish] {
            layer.opacity = 0
            stage.addSublayer(layer)
        }
        root.addSublayer(stage)
        panel.contentView = host
    }

    /// Plays the new song's entrance with the transition the desktop player picked. A newer song replaces
    /// one still in flight.
    func present(from: SongFace?, to: SongFace, style: SongTransition) {
        guard store.settings.songCard, let screen = NSScreen.screens.first else { return }
        reset()
        let size = screen.frame.size
        let impact = CGPoint(x: (size.width / 2).rounded(), y: (size.height * 0.52).rounded())
        var launch = CGPoint(x: impact.x, y: (size.height * 0.3).rounded())
        var look = KoiVariety.kohaku.look
        if let pond = wallpaper.mainPond, pond.isRunning,
           let koi = pond.renderer.pond.borrowKoi(near: SIMD2(Float(impact.x), Float(impact.y))) {
            launch = CGPoint(x: CGFloat(koi.position.x), y: CGFloat(koi.position.y))
            look = koi.variety.look
        }
        let now = CACurrentMediaTime()
        show = Show(start: now, launch: launch, impact: impact, look: look, far: 0.6,
                    near: max((size.height * 0.8 / CGFloat(KoiFace.size)).rounded(.down), 4), style: style, song: to,
                    songKey: player.info?.trackKey, last: now)

        let art = ArtLayout.card.size
        let scale = min(max((size.width * 0.6 / art.width).rounded(.down), 2), 5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(origin: .zero, size: size)
        for layer in [card, shadow] {
            layer.removeAllAnimations()
            layer.bounds = CGRect(x: 0, y: 0, width: art.width * scale, height: art.height * scale)
            layer.transform = CATransform3DIdentity
            layer.opacity = 0
        }
        card.position = impact
        shadow.position = CGPoint(x: impact.x + 14, y: impact.y - 14)
        CATransaction.commit()
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()

        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        step()
    }

    // MARK: The timeline

    private func step() {
        guard var show else { return }
        let now = CACurrentMediaTime(), t = now - show.start, dt = now - show.last
        show.last = now
        show.frame += 1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moveFish(&show, t: t, dt: dt, calm: calm)

        // The hit: a short, small shake of everything on the glass.
        let since = t - Cue.hit
        let shake = since >= 0 && since < 0.35 && !calm ? 12 * exp(-since / 0.09) : 0
        stage.position = CGPoint(x: stage.bounds.midX + shake * sin(t * 97), y: stage.bounds.midY + shake * cos(t * 83))

        // The card is slapped onto the glass with the fish and waits, blank, behind it; its transition
        // starts as the fish peels off.
        if t >= Cue.hit, !show.hit {
            show.hit = true
            show.change = SongChange(from: nil, style: show.style, start: show.start + Cue.peel)
            card.opacity = 1
            shadow.opacity = 0.28
            spawnDrops(at: show.impact)
        }
        if show.hit, !show.sinking {
            let slap = 1 + 0.15 * exp(-since * 9) * cos(since * 20)
            card.transform = CATransform3DMakeScale(slap, slap, 1)
            shadow.transform = card.transform
            let changing = show.change.map { !$0.isOver(at: now) } ?? false
            if changing || show.frame % 30 == 0 { drawCard(&show, now: now) }
        }
        updateDrops(t: t, dt: dt)

        if t >= Cue.gone, !show.returned {
            show.returned = true
            fish.opacity = 0
            wallpaper.mainPond?.renderer.pond.returnKoi(at: SIMD2(Float(show.impact.x), Float(show.impact.y - 140)))
        }
        if show.returned { smear.opacity = Float(max(0, 1 - (t - Cue.gone) / 1.2)) }
        CATransaction.commit()

        if t >= Cue.sink, !show.sinking {
            show.sinking = true
            sink(center: show.impact)
        }
        self.show = show
    }

    private func moveFish(_ show: inout Show, t: Double, dt: Double, calm: Bool) {
        guard t < Cue.gone else { return }
        var pose = KoiFace.Pose.charging
        var scale = show.near, position = show.impact
        var sx: CGFloat = 1, sy: CGFloat = 1, angle: CGFloat = 0, opacity: Float = 1, flash = false
        if t < Cue.windUp {
            // Anticipation: it sinks a little and coils before the burst.
            let coil = CGFloat(sin(t / Cue.windUp * .pi))
            scale = show.far * (1 - 0.15 * coil)
            position = show.launch
            sx = 1 + 0.14 * coil
            sy = 1 - 0.14 * coil
            show.beat += dt * 10
        } else if t < Cue.hit {
            // Straight at the lens, at a steady speed in depth. Projected, it creeps up and then fills the
            // screen at the last moment, stretching with the speed and drifting to where it will hit.
            let p = (t - Cue.windUp) / (Cue.hit - Cue.windUp)
            let nearest = show.far / show.near
            let z = 1 - (1 - nearest) * CGFloat(p)
            let center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
            let from = CGPoint(x: show.launch.x - center.x, y: show.launch.y - center.y)
            let to = CGPoint(x: (show.impact.x - center.x) * nearest, y: (show.impact.y - center.y) * nearest)
            scale = show.far / z
            position = CGPoint(x: center.x + (from.x + (to.x - from.x) * CGFloat(p)) / z,
                               y: center.y + (from.y + (to.y - from.y) * CGFloat(p)) / z)
            sx = 1 - 0.06 * CGFloat(p)
            sy = 1 + 0.1 * CGFloat(p)
            angle = 0.06 * CGFloat(sin(t * 9))
            show.beat += dt * 28
        } else if t < Cue.peel {
            let since = t - Cue.hit
            if since < Cue.freeze {
                // Hit-stop: held at the moment of contact, the first frames in white.
                flash = since < Cue.freeze / 2 && !calm
            } else {
                // Squashed flat on the glass, keeping its volume, jiggling as it settles.
                let jiggle = CGFloat(exp(-(since - Cue.freeze) * 7) * cos((since - Cue.freeze) * 22))
                sx = 1.06 + 0.32 * jiggle
                sy = 0.95 - 0.28 * jiggle
                pose = .splat
            }
        } else {
            // It peels off and slides down the glass, slow then faster, falling away from the lens.
            let since = t - Cue.peel, span = Cue.gone - Cue.peel
            scale = show.near * CGFloat(1 - 0.4 * since / span)
            position = CGPoint(x: show.impact.x + CGFloat(20 * since), y: show.impact.y - CGFloat(0.5 * 1150 * since * since))
            angle = CGFloat(-0.3 * since)
            sx = 1.04
            sy = 0.97
            pose = .dazed
            opacity = Float(min(1, (span - since) / 0.25))
            show.beat += dt * 4
            let width = CGFloat(KoiFace.size) * show.near * 0.42
            smear.frame = CGRect(x: show.impact.x - width / 2, y: position.y, width: width, height: max(0, show.impact.y - position.y))
            smear.opacity = 1
        }
        fish.contents = KoiFace.image(look: show.look, pose: pose, beat: show.beat, flash: flash)
        fish.bounds = CGRect(x: 0, y: 0, width: CGFloat(KoiFace.size) * scale, height: CGFloat(KoiFace.size) * scale)
        fish.position = position
        fish.transform = CATransform3DRotate(CATransform3DMakeScale(sx, sy, 1), angle, 0, 0, 1)
        fish.opacity = opacity
    }

    private func drawCard(_ show: inout Show, now: CFTimeInterval) {
        // The cover may come in after the card is out, from the online lookup.
        if let info = player.info, info.trackKey == show.songKey, let cover = player.cover { show.song.cover = cover }
        let change = show.change.flatMap { $0.isOver(at: now) ? nil : $0 }
        card.contents = NowPlayingArt.card(song: show.song, change: change)
    }

    // MARK: Drops on the glass

    private static let dropImage: CGImage? = {
        let rows = ["..X..", ".XXX.", ".XXX.", "XXXXX", "XXOXX", "XXXXX", ".XXX."]
        guard let ctx = CGContext(data: nil, width: 5, height: 7, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        for (y, row) in rows.enumerated() {
            for (x, mark) in row.enumerated() where mark != "." {
                ctx.setFillColor(mark == "O" ? CGColor(gray: 1, alpha: 0.95)
                    : CGColor(srgbRed: 0.78, green: 0.92, blue: 0.96, alpha: 0.8))
                ctx.fill(CGRect(x: x, y: 6 - y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()
    }()

    /// Water thrown off by the hit, flying out and sticking to the glass.
    private func spawnDrops(at point: CGPoint) {
        for _ in 0..<18 {
            let angle = Double.random(in: 0...(2 * .pi)), speed = Double.random(in: 500...1500)
            let size = CGFloat(Int.random(in: 3...6))
            let layer = CALayer()
            layer.contents = Self.dropImage
            layer.magnificationFilter = .nearest
            layer.bounds = CGRect(x: 0, y: 0, width: 5 * size, height: 7 * size)
            layer.position = point
            stage.addSublayer(layer)
            drops.append(Drop(layer: layer, position: point, velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                              slide: CGFloat.random(in: 8...30)))
        }
    }

    private func updateDrops(t: Double, dt: Double) {
        let fade = Float(max(0, 1 - (t - Cue.hit - 1.6) / 1.6))
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
            drop.layer.opacity = fade
            drops[i] = drop
        }
        if fade <= 0, !drops.isEmpty {
            drops.forEach { $0.layer.removeFromSuperlayer() }
            drops.removeAll()
        }
    }

    // MARK: Leaving

    /// The card drops back to the water, shrinking and fading, and the pond takes it with a splash.
    private func sink(center: CGPoint) {
        let duration = 0.7
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = 0
        shadow.opacity = 0
        CATransaction.commit()
        for (layer, start, opacity) in [(card, center, Float(1)), (shadow, CGPoint(x: center.x + 14, y: center.y - 14), Float(0.28))] {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: start)
            move.toValue = NSValue(point: CGPoint(x: center.x, y: center.y - 26))
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.55
            let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
            tilt.fromValue = 0
            tilt.toValue = 0.12
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [move, shrink, tilt, fade]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(group, forKey: "sink")
        }
        later(duration * 0.8) { [weak self] in
            self?.wallpaper.mainPond?.renderer.pond.splash(at: SIMD2(Float(center.x), Float(center.y - 26)), strength: 1.3, drops: 3)
        }
        later(duration) { [weak self] in self?.finish() }
    }

    private func later(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0), execute: item)
    }

    /// Stops whatever is playing; a koi still out at the glass goes back to the pond.
    private func reset() {
        if let show, !show.returned {
            wallpaper.mainPond?.renderer.pond.returnKoi(at: SIMD2(Float(show.launch.x), Float(show.launch.y)))
        }
        show = nil
        ticker?.invalidate()
        ticker = nil
        pending.forEach { $0.cancel() }
        pending.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [card, shadow, fish, smear] {
            layer.removeAllAnimations()
            layer.opacity = 0
        }
        drops.forEach { $0.layer.removeFromSuperlayer() }
        drops.removeAll()
        stage.position = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        CATransaction.commit()
    }

    private func finish() {
        reset()
        card.contents = nil
        fish.contents = nil
        panel.orderOut(nil)
    }
}
