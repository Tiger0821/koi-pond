import AppKit
import ImageIO
import KoiPondCore
import UniformTypeIdentifiers

/// The koi seen head-on, charging up out of the water at the viewer: 64 × 64 pixel art in its variety's
/// colors, drawn fresh each frame so its fins and tail can beat and its face can change on the glass.
/// The tail and pectoral fins sit behind the head, so the overlap carries the depth.
enum KoiFace {
    enum Pose {
        /// Mouth gaping, eyes wide, fins and tail beating.
        case charging
        /// Pressed flat on the glass: X eyes, squashed lips, fins splayed out, a pale contact patch.
        case splat
        /// Sliding down the glass, still seeing stars, fins hanging.
        case dazed
    }

    static let size = 64

    /// The pond shader's `lightRamp` for light below 1: shadows on warm colours lean red-orange (gold goes
    /// amber, not olive), on whites and blues they lean cool.
    static func shade(_ c: SIMD3<Float>, _ light: Float) -> SIMD3<Float> {
        let warm = min(max((c.x - c.z) * 1.6, 0), 1)
        let tint = SIMD3<Float>(0.84, 0.92, 1.0) + (SIMD3<Float>(1.0, 0.8, 0.6) - SIMD3<Float>(0.84, 0.92, 1.0)) * warm
        let k = (1 - light) * 2
        return c * light * SIMD3(pow(tint.x, k), pow(tint.y, k), pow(tint.z, k))
    }

    /// `beat` advances the fins and tail; `flash` draws the white impact frame.
    static func image(look: KoiVariety.Look, pose: Pose, beat: Double, flash: Bool = false) -> CGImage? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setShouldAntialias(false)

        // Top-left coordinates, like the rest of the pixel art.
        func color(_ c: SIMD3<Float>, _ alpha: CGFloat = 1) -> CGColor {
            flash ? CGColor(gray: 1, alpha: alpha > 0.5 ? 1 : alpha)
                : CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
        }
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ c: CGColor) {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: x - rx, y: s - y - ry, width: rx * 2, height: ry * 2))
        }
        func polygon(_ points: [CGPoint], _ c: CGColor) {
            ctx.setFillColor(c)
            ctx.beginPath()
            ctx.addLines(between: points.map { CGPoint(x: $0.x, y: s - $0.y) })
            ctx.closePath()
            ctx.fillPath()
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ c: CGColor) {
            ctx.setFillColor(c)
            let steps = Int(max(abs(b.x - a.x), abs(b.y - a.y)).rounded(.up))
            for i in 0...max(steps, 1) {
                let t = CGFloat(i) / CGFloat(max(steps, 1))
                ctx.fill(CGRect(x: (a.x + (b.x - a.x) * t).rounded(.down), y: s - 1 - (a.y + (b.y - a.y) * t).rounded(.down),
                                width: 1, height: 1))
            }
        }

        let white = SIMD3<Float>(1, 1, 1)
        let base = look.base
        let dark = shade(base, 0.62)
        // Black koi have white fins, as in the pond.
        let finBase = base.sum() / 3 < 0.25 ? SIMD3<Float>(0.95, 0.94, 0.9) : base
        let fin = color(finBase + (white - finBase) * 0.6, 0.82)
        let finRay = color(finBase * 0.75 + (white - finBase) * 0.2, 0.9)
        let lip = color(look.lips ? look.patch : [0.96, 0.7, 0.66])   // kuchibeni: red lips
        let inside = color([0.16, 0.05, 0.08])
        let ring = color([0.9, 0.74, 0.34])
        let ink = color([0.06, 0.06, 0.08])
        let pupil = look.redEyes ? color([0.72, 0.12, 0.1]) : ink

        // Tail, peeking over the head and beating side to side.
        let swing: CGFloat = switch pose {
        case .charging: CGFloat(sin(beat)) * 7
        case .splat: 2
        case .dazed: CGFloat(sin(beat * 0.3)) * 2
        }
        polygon([CGPoint(x: 32 + swing * 0.4, y: 19), CGPoint(x: 15 + swing, y: 3), CGPoint(x: 32 + swing, y: 9),
                 CGPoint(x: 49 + swing, y: 3)], fin)
        for end in [CGPoint(x: 19 + swing, y: 5), CGPoint(x: 32 + swing, y: 9), CGPoint(x: 45 + swing, y: 5)] {
            line(CGPoint(x: 32 + swing * 0.4, y: 18), end, finRay)
        }
        // The body behind the head, foreshortened almost away.
        ellipse(32, 24, 13, 11, color(dark))

        // Pectoral fins, from folded down to splayed flat out on the glass.
        let spread: CGFloat = switch pose {
        case .charging: 0.35 + 0.3 * CGFloat(sin(beat * 2))
        case .splat: 1
        case .dazed: 0.08
        }
        for side: CGFloat in [-1, 1] {
            let root = CGPoint(x: 32 + side * 14, y: 46)
            let angle = spread * .pi / 2 * 1.05
            let along = CGPoint(x: side * sin(angle), y: cos(angle))
            let across = CGPoint(x: -along.y * side, y: along.x * side)
            let tip = CGPoint(x: root.x + along.x * 17, y: root.y + along.y * 17)
            polygon([root, CGPoint(x: tip.x + across.x * 6, y: tip.y + across.y * 6),
                     CGPoint(x: tip.x - across.x * 6, y: tip.y - across.y * 6)], fin)
            line(root, tip, finRay)
            // Fin markings: black or red at the root, or a black stripe through the rays.
            let near = CGPoint(x: root.x + along.x * 10, y: root.y + along.y * 10)
            switch look.fins {
            case .blackRoots, .redRoots:
                polygon([root, CGPoint(x: near.x + across.x * 3.5, y: near.y + across.y * 3.5),
                         CGPoint(x: near.x - across.x * 3.5, y: near.y - across.y * 3.5)],
                        look.fins == .blackRoots ? ink : color(look.patch))
            case .blackStripes:
                line(near, CGPoint(x: tip.x + across.x * 2, y: tip.y + across.y * 2), ink)
            case .plain:
                break
            }
        }

        // The head, darker underneath, with a sheen up top.
        ellipse(32, 38, 20, 18, color(dark))
        ellipse(32, 36.5, 19.5, 16.5, color(base))
        let sheen: Float = 0.4 + 0.25 * look.metallic
        ellipse(24, 28, 6, 3.5, color(base + (white - base) * sheen))
        if look.metallic > 0 { ellipse(22, 27, 1.5, 1, color(white)) }   // a glint on a metallic head
        if look.special == 1 {
            ellipse(32, 26, 7, 6, color(look.patch))
        } else if look.patchThreshold < 1 {
            ellipse(37, 27, 11, 6, color(look.patch))
            ellipse(20, 41, 5, 6, color(look.patch))
        }
        if look.accentThreshold < 1 {
            ellipse(45, 32, 3, 3, color(look.accent))
            ellipse(26, 45, 2, 2, color(look.accent))
        }
        for side: CGFloat in [-1, 1] {
            line(CGPoint(x: 32 + side * 12, y: 37), CGPoint(x: 32 + side * 14, y: 47), color(dark))
        }

        // Where the face meets the glass it flattens and goes pale.
        if pose == .splat { ellipse(32, 42, 13, 9, color(white, 0.25)) }

        // Eyes bulging at the sides: wide while charging, crossed out once it hits.
        for side: CGFloat in [-1, 1] {
            let eye = CGPoint(x: 32 + side * 17, y: 34)
            ellipse(eye.x, eye.y, 3.5, 3.5, ring)
            if pose == .charging {
                ellipse(eye.x + side * 0.5, eye.y, 2, 2, pupil)
                ctx.setFillColor(color(white))
                ctx.fill(CGRect(x: eye.x - 1, y: s - eye.y - 2, width: 1, height: 1))
            } else {
                line(CGPoint(x: eye.x - 2, y: eye.y - 2), CGPoint(x: eye.x + 2, y: eye.y + 2), ink)
                line(CGPoint(x: eye.x - 2, y: eye.y + 2), CGPoint(x: eye.x + 2, y: eye.y - 2), ink)
            }
        }

        // The mouth: a gaping O, then lips squashed flat on the glass.
        switch pose {
        case .charging:
            ellipse(32, 49, 7, 6, lip)
            ellipse(32, 49, 4.5, 4, inside)
        case .splat:
            ellipse(32, 49, 11, 3, lip)
            line(CGPoint(x: 23, y: 49), CGPoint(x: 41, y: 49), color([0.78, 0.48, 0.46]))
        case .dazed:
            ellipse(32, 49, 6, 3, lip)
            ellipse(32, 49, 3, 1.5, inside)
        }
        let whisker = CGFloat(sin(beat * 1.5)) * (pose == .charging ? 2 : 0.5)
        line(CGPoint(x: 25, y: 51), CGPoint(x: 19 + whisker, y: 58), lip)
        line(CGPoint(x: 39, y: 51), CGPoint(x: 45 - whisker, y: 58), lip)
        return ctx.makeImage()
    }
}

/// `KoiPond --koi-face out.png [--pose charging|splat|dazed] [--variety kohaku] [--design 0] [--flash]` draws the head-on
/// koi to a PNG at 8 screen pixels per art pixel.
enum KoiFacePreview {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--koi-face"), index + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let pose: KoiFace.Pose = switch value("--pose") {
        case "splat": .splat
        case "dazed": .dazed
        default: .charging
        }
        let variety = value("--variety").flatMap { name in KoiVariety.allCases.first { "\($0)" == name } } ?? .kohaku
        let designs = variety.designs
        let look = designs[(value("--design").flatMap(Int.init) ?? 0) % designs.count]
        guard let face = KoiFace.image(look: look, pose: pose, beat: 1, flash: args.contains("--flash")) else { exit(1) }
        let scale = 8, side = KoiFace.size * scale
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[index + 1]) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.43, blue: 0.41, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        ctx.draw(face, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage() else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
