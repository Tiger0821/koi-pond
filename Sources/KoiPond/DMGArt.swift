import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The picture behind the install disk's window: pond water in pixel art, "Drag Koi Pond onto
/// Applications" across the top and a big arrow from where Finder puts Koi Pond to where it puts the
/// Applications shortcut, so there's no mistaking what to do. The water is a mid-tone so Finder's own icon
/// labels read in light mode (black) and dark mode (white) alike. `scripts/make-dmg.sh` places the icons to match.
enum DMGArt {
    /// The window's content size in points.
    static let size = CGSize(width: 640, height: 400)
    /// Where Finder centers each icon, in points from the window's top left.
    static let appIcon = CGPoint(x: 160, y: 180)
    static let applications = CGPoint(x: 480, y: 180)

    /// Points per art pixel: the water, arrow and title are drawn on a 320 × 200 grid.
    private static let unit = 2
    private static let palette: [SIMD3<Float>] = [[0.36, 0.62, 0.58], [0.32, 0.57, 0.54], [0.28, 0.52, 0.5], [0.24, 0.46, 0.45]]

    /// The background at `scale` pixels per point (1, or 2 for Retina).
    static func image(scale: Int) -> CGImage? {
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        guard let art = pixelArt(),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(art, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The first-open tip, small and crisp, under the icons.
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let tip = "First time? If it won't open: System Settings › Privacy & Security › Open Anyway"
        // High enough that a Finder path bar along the window's foot doesn't cover it.
        draw(tip, size: 11, weight: .medium, color: CGColor(gray: 1, alpha: 0.85), centeredAt: 338, in: ctx)
        return ctx.makeImage()
    }

    /// The water, the ripples under each icon, lily pads, the arrow and the title, one art pixel each.
    private static func pixelArt() -> CGImage? {
        let w = Int(size.width) / unit, h = Int(size.height) / unit
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setShouldAntialias(false)
        let art = Art(ctx: ctx, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let d = hypot(Double(x) - Double(w) / 2, Double(y) - Double(h) * 0.45) / Double(w)
                art.dot(x, y, art.color(AppIcon.banded(0.12 + Double(y) / Double(h) * 0.45 + d * 0.5, palette, x, y)))
            }
        }
        let left = (Double(appIcon.x) / Double(unit), Double(appIcon.y) / Double(unit))
        let right = (Double(applications.x) / Double(unit), Double(applications.y) / Double(unit))
        for center in [left, right] {
            art.ring(center, 40, 1.4, art.color(AppIcon.streak, 0.16))
            art.ring(center, 48, 1.1, art.color(AppIcon.streak, 0.09))
        }
        for (x, y, r, notch) in [(6.0, 196.0, 13.0, 0.9), (312.0, 12.0, 13.0, 2.4), (316.0, 198.0, 9.0, 3.7), (14.0, 14.0, 9.0, -0.6)] {
            art.lilyPad((x, y), r, notch: notch)
        }
        drawArrow(art, from: Int(left.0) + 42, to: Int(right.0) - 42, y: Int(left.1))
        // The title in chunky pixel letters, with a drop shadow so it reads on any part of the water.
        let title = "Drag Koi Pond onto Applications"
        let font = NSFont.systemFont(ofSize: 13, weight: .bold) as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: font]))
        let x = (CGFloat(w) - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) / 2
        for (offset, color) in [(CGPoint(x: 1, y: -1), CGColor(srgbRed: 0.05, green: 0.16, blue: 0.17, alpha: 0.75)),
                                (CGPoint.zero, CGColor(gray: 1, alpha: 1))] {
            let colored = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
            ctx.textPosition = CGPoint(x: x.rounded() + offset.x, y: CGFloat(h - 34) + offset.y)
            CTLineDraw(colored, ctx)
        }
        return ctx.makeImage()
    }

    /// A fat pixel arrow pointing right: orange with a dark outline and a light top edge.
    private static func drawArrow(_ art: Art, from start: Int, to end: Int, y: Int) {
        let fill = art.color([0.98, 0.6, 0.26]), shine = art.color([1, 0.84, 0.6]), ink = art.color([0.36, 0.16, 0.07])
        let head = 18, half = 15, shaft = 5
        let neck = end - head
        func body(_ grow: Int, _ c: CGColor) {
            art.block(start - grow, y - shaft - grow, neck - start + grow + 1, 2 * (shaft + grow) + 1, c)
            for i in 0...(head + grow) {
                let reach = half + grow - Int((Double(i) * Double(half + grow) / Double(head + grow)).rounded())
                art.block(neck + i - grow, y - reach, 1, 2 * reach + 1, c)
            }
        }
        body(2, ink)
        body(0, fill)
        art.block(start, y - shaft, neck - start, 1, shine)
        for i in 0..<half where i < head { art.dot(neck + i, y - half + Int((Double(i) * Double(half) / Double(head)).rounded()), shine) }
    }

    private static func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centeredAt top: CGFloat, in ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
        let shadowed = [(CGPoint(x: 0, y: -1), CGColor(srgbRed: 0.04, green: 0.14, blue: 0.15, alpha: 0.6)), (CGPoint.zero, color)]
        for (offset, c) in shadowed {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (DMGArt.size.width - width) / 2 + offset.x, y: DMGArt.size.height - top + offset.y)
            CTLineDraw(line, ctx)
        }
    }

    /// Art pixels with top-left coordinates.
    private struct Art {
        let ctx: CGContext
        let height: Int

        func color(_ c: SIMD3<Float>, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
        }

        func dot(_ x: Int, _ y: Int, _ c: CGColor) { block(x, y, 1, 1, c) }

        func block(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ c: CGColor) {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: x, y: self.height - y - height, width: width, height: height))
        }

        func ring(_ center: (Double, Double), _ radius: Double, _ width: Double, _ c: CGColor) {
            let reach = Int(radius + width) + 1
            for y in (Int(center.1) - reach)...(Int(center.1) + reach) {
                for x in (Int(center.0) - reach)...(Int(center.0) + reach) {
                    let d = hypot(Double(x) + 0.5 - center.0, Double(y) + 0.5 - center.1)
                    if abs(d - radius) <= width / 2 { dot(x, y, c) }
                }
            }
        }

        func lilyPad(_ center: (Double, Double), _ radius: Double, notch: Double) {
            let rim = color([0.2, 0.42, 0.2]), leaf = color([0.38, 0.64, 0.3]), shine = color([0.62, 0.82, 0.48], 0.8)
            let reach = Int(radius) + 1
            for y in (Int(center.1) - reach)...(Int(center.1) + reach) {
                for x in (Int(center.0) - reach)...(Int(center.0) + reach) {
                    let dx = Double(x) + 0.5 - center.0, dy = Double(y) + 0.5 - center.1, d = hypot(dx, dy)
                    var off = abs(atan2(dy, dx) - notch).truncatingRemainder(dividingBy: 2 * .pi)
                    if off > .pi { off = 2 * .pi - off }
                    guard d <= radius, off > 0.32 || d < 1.5 else { continue }
                    dot(x, y, d > radius - 1.2 ? rim : leaf)
                }
            }
            dot(Int(center.0 - radius * 0.4), Int(center.1 - radius * 0.4), shine)
        }
    }
}

/// `KoiPond --dmg-background out.png [--scale 2]` draws the install disk's background.
enum DMGArtCommand {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--dmg-background"), index + 1 < args.count else { return false }
        let scale = args.firstIndex(of: "--scale").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1
        guard let image = DMGArt.image(scale: scale),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[index + 1]) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        // Tagged 72 dpi per point of scale, so Finder treats the @2x image as Retina.
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
