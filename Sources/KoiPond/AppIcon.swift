import AppKit
import ImageIO
import KoiPondCore
import UniformTypeIdentifiers

/// The app icon: the koi from the song card charging head-first out of the pond at you, drawn as pixel art and
/// set in macOS's rounded-square icon shape (824 points square, centered on a 1024 canvas).
enum AppIcon {
    enum Style: String, CaseIterable {
        /// Kohaku charging straight at you past a few faint speed lines and drops: the app's icon.
        case charge
        /// Benigoi bursting up through the surface: a crown of splash and ripple rings.
        case splash
        /// Kohaku smacked flat on the glass, X-eyed and seeing stars, with a glare across the glass and drips.
        case splat
        /// Golden ogon charging across the pond at night, beside the moon's reflection.
        case night
        /// Tancho charging out between lily pads and a lotus.
        case lily
    }

    /// The icon at `side` pixels square (1024 for the full-size icon; smaller sizes are scaled down from it).
    static func image(_ style: Style, side: Int = 1024) -> CGImage? {
        guard let art = art(style),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let unit = CGFloat(side) / 1024
        let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185.4 * unit, cornerHeight: 185.4 * unit, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        // Whole screen pixels per art pixel, enough to cover the tile; the overhang is cut off by the shape.
        let cell = (824 / CGFloat(art.width)).rounded(.up) * unit
        let artSide = cell * CGFloat(art.width)
        ctx.interpolationQuality = .none
        ctx.draw(art, in: CGRect(x: (CGFloat(side) - artSide) / 2, y: (CGFloat(side) - artSide) / 2, width: artSide, height: artSide))
        // A faint light edge, like the rim of a glass tile.
        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        ctx.setLineWidth(8 * unit)
        ctx.strokePath()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: The pixel art

    private static func art(_ style: Style) -> CGImage? {
        switch style {
        case .charge: charge()
        case .splash: splash()
        case .splat: splat()
        case .night: night()
        case .lily: lily()
        }
    }

    static let streak = SIMD3<Float>(0.78, 0.96, 0.92)
    static let foam = SIMD3<Float>(0.93, 0.99, 0.98)
    private static let pond: [SIMD3<Float>] = [[0.38, 0.72, 0.65], [0.25, 0.56, 0.53], [0.16, 0.42, 0.42], [0.1, 0.3, 0.32], [0.07, 0.21, 0.25]]

    private static func charge() -> CGImage? {
        guard let c = Canvas(72), let face = KoiFace.image(look: KoiVariety.kohaku.look, pose: .charging, beat: 0) else { return nil }
        let center = (36.0, 39.0)
        c.fill { x, y in banded(hypot(Double(x) + 0.5 - center.0, Double(y) + 0.5 - center.1) / 48, pond, x, y) }
        var random = Random(seed: 7)
        // A few faint speed lines rushing out past the edges: the fish is coming at you.
        for i in 0..<14 {
            let angle = Double(i) / 14 * 2 * .pi + random.next(-0.08, 0.08)
            let r0 = 31 + random.next(0, 7), r1 = r0 + 6 + random.next(0, 12)
            c.line(center, angle, r0, r1, c.color(streak, CGFloat(random.next(0.2, 0.42))))
        }
        // A handful of drops flung off ahead of it, each with a short trail.
        for angle in [-2.45, -0.62, 0.55, 2.6] {
            let r = 29 + random.next(0, 4)
            let x = center.0 + cos(angle) * r, y = center.1 + sin(angle) * r
            c.block(Int(x), Int(y), 2, 2, c.color(foam, 0.85))
            c.dot(Int(x - cos(angle) * 3), Int(y - sin(angle) * 3), c.color(foam, 0.35))
        }
        c.draw(face, x: 4, y: 3)
        return c.image()
    }

    private static func splash() -> CGImage? {
        guard let c = Canvas(96), let face = KoiFace.image(look: KoiVariety.benigoi.look, pose: .charging, beat: 0.5) else { return nil }
        let center = (48.0, 57.0)
        c.fill { x, y in
            let d = hypot(Double(x) + 0.5 - center.0, Double(y) + 0.5 - center.1)
            return banded(0.15 + 0.5 * Double(y) / 96 + 0.45 * d / 70, pond, x, y)
        }
        // Ripple rings running out from where it broke the surface.
        for (radius, width, alpha) in [(31.0, 2.2, 0.5), (38.5, 1.6, 0.34), (45.5, 1.2, 0.22)] {
            c.ring(center, radius, width, c.color(streak, alpha))
        }
        // The surface torn open around the body: a ring of foam, then a crown of drops thrown up and out.
        c.ring(center, 23, 3.2, c.color(foam, 0.6))
        var random = Random(seed: 3)
        for i in 0..<16 {
            let angle = Double(i) / 16 * 2 * .pi + random.next(-0.12, 0.12), r = 30 + random.next(0, 5)
            c.line(center, angle, r, r + 2.5, c.color(foam, 0.9))
            let tip = (center.0 + cos(angle) * (r + 4.5), center.1 + sin(angle) * (r + 4.5))
            c.block(Int(tip.0), Int(tip.1), 2, 2, c.color(foam))
        }
        c.draw(face, x: 16, y: 17)
        return c.image()
    }

    private static func splat() -> CGImage? {
        guard let c = Canvas(72), let face = KoiFace.image(look: KoiVariety.kohaku.look, pose: .splat, beat: 0) else { return nil }
        c.fill { x, y in banded(0.25 + hypot(Double(x) + 0.5 - 36, Double(y) + 0.5 - 38) / 52, pond, x, y) }
        c.draw(face, x: 4, y: 4)
        // Water squeezed out by the impact, running down the glass.
        var random = Random(seed: 11)
        for x in [14, 23, 47, 57] {
            let bottom = 60 + Int(random.next(2, 9))
            c.block(x, 54, 1, bottom - 54, c.color(foam, 0.45))
            c.block(x, bottom, 2, 2, c.color(foam, 0.8))
        }
        // Seeing stars.
        for (x, y) in [(8, 14), (63, 10), (60, 24)] {
            let star = c.color([1, 0.9, 0.45])
            c.dot(x, y, star)
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { c.dot(x + dx, y + dy, c.color([1, 0.9, 0.45], 0.7)) }
        }
        // The glass itself: a faint tint and a two-stripe glare across the top left.
        c.fill(alpha: 0.05) { _, _ in SIMD3(1, 1, 1) }
        c.fill(alpha: 0.32) { x, y in
            let s = x + y
            return (18...21).contains(s) || (25...26).contains(s) ? SIMD3(1, 1, 1) : nil
        }
        return c.image()
    }

    private static func night() -> CGImage? {
        guard let c = Canvas(80), let face = KoiFace.image(look: KoiVariety.ogon.look, pose: .charging, beat: 0.3) else { return nil }
        let palette: [SIMD3<Float>] = [[0.13, 0.33, 0.37], [0.09, 0.24, 0.3], [0.06, 0.16, 0.23], [0.04, 0.1, 0.17]]
        let center = (40.0, 48.0)
        c.fill { x, y in banded(0.2 + hypot(Double(x) + 0.5 - center.0, Double(y) + 0.5 - center.1) / 55, palette, x, y) }
        for (radius, alpha) in [(30.0, 0.3), (37.0, 0.18)] { c.ring(center, radius, 1.4, c.color(streak, alpha)) }
        // The moon's reflection, cut by the ripples crossing it.
        let moon = (63.0, 15.0)
        c.ring(moon, 9.5, 2, c.color([0.97, 0.94, 0.78], 0.16))
        c.disc(moon, 6.6, c.color([0.97, 0.94, 0.78]))
        for y in [12, 16] { c.block(56, y, 15, 1, c.color(palette[2], 0.45)) }
        var random = Random(seed: 5)
        for _ in 0..<9 {
            let x = Int(random.next(2, 78)), y = Int(random.next(2, 30))
            if hypot(Double(x) - moon.0, Double(y) - moon.1) > 11 { c.dot(x, y, c.color([1, 0.95, 0.75], CGFloat(random.next(0.4, 0.9)))) }
        }
        c.draw(face, x: 8, y: 9)
        return c.image()
    }

    private static func lily() -> CGImage? {
        guard let c = Canvas(88), let face = KoiFace.image(look: KoiVariety.tancho.look, pose: .charging, beat: -0.4) else { return nil }
        let palette: [SIMD3<Float>] = [[0.32, 0.66, 0.56], [0.21, 0.52, 0.47], [0.13, 0.39, 0.38], [0.08, 0.28, 0.29]]
        let center = (44.0, 53.0)
        c.fill { x, y in banded(0.1 + hypot(Double(x) + 0.5 - center.0, Double(y) + 0.5 - center.1) / 56, palette, x, y) }
        for (radius, alpha) in [(29.0, 0.42), (35.5, 0.26)] { c.ring(center, radius, 1.6, c.color(streak, alpha)) }
        for (x, y, r, notch) in [(17.0, 17.0, 10.5, 0.8), (73.0, 72.0, 11.0, 3.9), (73.0, 17.0, 7.5, 2.3), (15.0, 73.0, 8.0, -0.6)] {
            c.lilyPad((x, y), r, notch: notch)
        }
        // A lotus on the bottom right pad.
        let lotus = (70, 68)
        for (dx, dy) in [(0, -3), (-3, 0), (3, 0), (-2, -2), (2, -2), (0, 2)] {
            c.disc((Double(lotus.0 + dx) + 0.5, Double(lotus.1 + dy) + 0.5), 1.8, c.color([0.98, 0.66, 0.78]))
        }
        c.disc((Double(lotus.0) + 0.5, Double(lotus.1) + 0.5), 1.3, c.color([1, 0.86, 0.36]))
        c.draw(face, x: 12, y: 13)
        return c.image()
    }

    // MARK: Helpers

    /// A 4 × 4 ordered dither between the palette's colors, for smooth pixel-art gradients.
    static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }

    static func banded(_ t: Double, _ palette: [SIMD3<Float>], _ x: Int, _ y: Int) -> SIMD3<Float> {
        let scaled = min(max(t, 0), 1) * Double(palette.count - 1)
        let index = Int(scaled)
        let step = scaled - Double(index) > bayer[(y % 4) * 4 + x % 4] ? 1 : 0
        return palette[min(index + step, palette.count - 1)]
    }

    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
        mutating func next(_ low: Double, _ high: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return low + (high - low) * Double(state >> 11) / Double(1 << 53)
        }
    }

    /// A square of art pixels with top-left coordinates and no antialiasing.
    final class Canvas {
        let ctx: CGContext
        let side: Int

        init?(_ side: Int) {
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            ctx.setShouldAntialias(false)
            ctx.interpolationQuality = .none
            self.ctx = ctx
            self.side = side
        }

        func color(_ c: SIMD3<Float>, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
        }

        func dot(_ x: Int, _ y: Int, _ c: CGColor) { block(x, y, 1, 1, c) }

        func block(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ c: CGColor) {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: x, y: side - y - height, width: width, height: height))
        }

        /// Paints every pixel the closure gives a color for.
        func fill(alpha: CGFloat = 1, _ shade: (Int, Int) -> SIMD3<Float>?) {
            for y in 0..<side {
                for x in 0..<side {
                    if let c = shade(x, y) { dot(x, y, color(c, alpha)) }
                }
            }
        }

        private func each(around center: (Double, Double), _ reach: Double, _ body: (Int, Int, Double, Double) -> Void) {
            for y in max(0, Int(center.1 - reach))...min(side - 1, Int(center.1 + reach) + 1) {
                for x in max(0, Int(center.0 - reach))...min(side - 1, Int(center.0 + reach) + 1) {
                    let dx = Double(x) + 0.5 - center.0, dy = Double(y) + 0.5 - center.1
                    body(x, y, hypot(dx, dy), atan2(dy, dx))
                }
            }
        }

        func disc(_ center: (Double, Double), _ radius: Double, _ c: CGColor) {
            each(around: center, radius) { x, y, d, _ in if d <= radius { dot(x, y, c) } }
        }

        func ring(_ center: (Double, Double), _ radius: Double, _ width: Double, _ c: CGColor) {
            each(around: center, radius + width) { x, y, d, _ in if abs(d - radius) <= width / 2 { dot(x, y, c) } }
        }

        /// A radial line from `r0` to `r1` out from `center`.
        func line(_ center: (Double, Double), _ angle: Double, _ r0: Double, _ r1: Double, _ c: CGColor) {
            let steps = Int((r1 - r0) * 1.5) + 1
            var last: (Int, Int)?
            for i in 0...steps {
                let r = r0 + (r1 - r0) * Double(i) / Double(steps)
                let p = (Int((center.0 + cos(angle) * r).rounded(.down)), Int((center.1 + sin(angle) * r).rounded(.down)))
                if last.map({ $0 != p }) ?? true { dot(p.0, p.1, c) }
                last = p
            }
        }

        /// A lily pad with its notch facing `notch` (radians), a darker rim, veins and a highlight.
        func lilyPad(_ center: (Double, Double), _ radius: Double, notch: Double) {
            let rim = color([0.2, 0.42, 0.2]), leaf = color([0.38, 0.64, 0.3]), vein = color([0.29, 0.53, 0.24])
            each(around: center, radius) { x, y, d, angle in
                var off = abs(angle - notch).truncatingRemainder(dividingBy: 2 * .pi)
                if off > .pi { off = 2 * .pi - off }
                guard d <= radius, off > 0.32 || d < 1.5 else { return }
                dot(x, y, d > radius - 1.2 ? rim : leaf)
            }
            for k in 1...4 { line(center, notch + Double(k) * 2 * .pi / 5, 1, radius - 2, vein) }
            disc((center.0 - radius * 0.35, center.1 - radius * 0.4), radius * 0.16, color([0.62, 0.82, 0.48], 0.8))
        }

        func draw(_ image: CGImage, x: Int, y: Int) {
            ctx.draw(image, in: CGRect(x: x, y: side - y - image.height, width: image.width, height: image.height))
        }

        func image() -> CGImage? { ctx.makeImage() }
    }
}

/// `KoiPond --app-icon out.png [--style charge|splash|splat|night|lily] [--size 1024]` draws the app icon to a PNG.
enum AppIconCommand {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--app-icon"), index + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let style = value("--style").flatMap(AppIcon.Style.init(rawValue:)) ?? .charge
        let size = value("--size").flatMap(Int.init) ?? 1024
        guard let image = AppIcon.image(style, side: size),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[index + 1]) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
