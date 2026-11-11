import AppKit
import CoreText
import KoiPondCore

/// Synced lyrics as pixel art for the middle of the pond: only the line being sung, big in the middle. It enters
/// in its style, words slam in on their own timing, the line moves to the beat, and it leaves in its style as
/// the next one comes. Drawn into a small bitmap that the screen scales up with nearest-neighbour filtering,
/// like the player and the song card.
///
/// The canvas is in canvas pixels, `fine` to an art pixel, with y up. Latin letters come from an aliased font
/// one art pixel per font pixel, so they stay as chunky as the player's title; Chinese, Japanese and Korean
/// are drawn on the canvas's finer grid with edges in quarter steps, so dense characters stay readable.
struct RockLyricsArt {
    /// Canvas pixels per art pixel.
    static let fine = 2

    let style: RockStyle
    /// Reduce Motion: the type still changes and colours still come and go, but nothing moves.
    let still: Bool

    struct Landing {
        /// In canvas pixels from the bottom left.
        var point: CGPoint
        var strength: Float
    }

    struct Output {
        var image: CGImage?
        /// Words that landed since the last frame, for the pond to splash under.
        var landings: [Landing] = []
        /// A white flash over everything, 0...1, on the biggest hits.
        var flash: Double = 0
        /// How much the lyrics show, 0...1, for the layer they're drawn into (and the dimming behind them).
        var opacity: Double = 0
    }

    private var u: CGFloat { CGFloat(Self.fine) }

    /// How dark the pond goes behind the lyrics: all over, and in a wide oval behind the words.
    static let dimEdge: CGFloat = 0.2
    static let dimCenter: CGFloat = 0.45
    /// How white the screen goes on an impact frame.
    static let flashStrength: CGFloat = 0.3

    /// The dimming, `amount` of the way in, over a screen of `size`.
    static func drawDim(in ctx: CGContext, size: CGSize, amount: Double) {
        guard amount > 0 else { return }
        let a = CGFloat(amount)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: dimEdge * a))
        ctx.fill(CGRect(origin: .zero, size: size))
        let colors = [CGColor(gray: 0, alpha: (dimCenter - dimEdge) * a), CGColor(gray: 0, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: 1, y: 0.5)
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                   endRadius: size.width * 0.5, options: [])
        }
        ctx.restoreGState()
    }

    /// Draws the lyrics at `time`, `since` being the time of the previous frame (for landings). The line before,
    /// while it leaves, is drawn in `leavingStyle` (the style it was sung in) when that differs.
    func render(lyrics: Lyrics, scene: LyricsScene, time: TimeInterval, since: TimeInterval, beat: BeatGrid?,
                size: CGSize, leavingStyle: RockStyle? = nil) -> Output {
        var output = Output()
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, scene.presence > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return output }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        output.opacity = scene.presence

        let maxWidth = size.width * 0.84
        let center = CGPoint(x: size.width / 2, y: size.height * 0.5)
        let current = scene.current.map { layout(lyrics.lines[$0], maxWidth: maxWidth) }

        // The camera: the whole picture reacting to beats and to words landing.
        let camera = cameraFrame(lyrics: lyrics, scene: scene, time: time, beat: beat)
        output.flash = camera.flash
        ctx.translateBy(x: camera.dx, y: camera.dy)
        if camera.rotation != 0 || camera.scale != 1 {
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: camera.rotation)
            ctx.scaleBy(x: camera.scale, y: camera.scale)
            ctx.translateBy(x: -center.x, y: -center.y)
        }

        // The line on its way out, in the style it was sung in, as the new one comes in.
        if let index = scene.previous, scene.arrival < 1 {
            let art = leavingStyle.map { RockLyricsArt(style: $0, still: still) } ?? self
            let leaving = art.layout(lyrics.lines[index], maxWidth: maxWidth)
            art.drawLeaving(leaving, line: lyrics.lines[index], in: ctx, center: center, progress: scene.arrival)
        }

        if let index = scene.current, let current {
            let line = lyrics.lines[index]
            drawCurrent(current, line: line, in: ctx, center: center, scene: scene, time: time, beat: beat)
            if !still, scene.presence > 0.5 {
                output.landings = landings(current, line: line, center: center, time: time, since: since, beat: beat)
            }
        }
        output.image = ctx.makeImage()
        return output
    }

    // MARK: Sizes and type

    /// The main line's size in art pixels, before it's shrunk to fit.
    private var mainSize: Int { 17 }


    private var uppercase: Bool {
        switch style {
        case .headbang, .stageDive, .moshPit: true
        case .glitch: true
        default: false
        }
    }

    private func displayText(_ text: String, word: Int) -> String {
        // The glitch mixes shouty capitals with a lowercase serif, word by word.
        if style == .glitch { return word % 2 == 1 ? text.lowercased() : text.uppercased() }
        return uppercase ? text.uppercased() : text
    }

    private func latinFont(word: Int, size: Int) -> CTFont {
        let size = CGFloat(size)
        switch style {
        case .headbang:
            return NSFont.systemFont(ofSize: size, weight: .black, width: .condensed) as CTFont
        case .rockingBoat:
            return CTFontCreateWithName("Futura-CondensedExtraBold" as CFString, size, nil)
        case .posterStomp:
            return NSFont.systemFont(ofSize: size + 1, weight: .black, width: .compressed) as CTFont
        case .stageDive:
            return CTFontCreateWithName("AvenirNextCondensed-Heavy" as CFString, size, nil)
        case .glitch:
            return word % 2 == 1 ? CTFontCreateWithName("Didot-Bold" as CFString, size - 1, nil)
                : NSFont.systemFont(ofSize: size + 1, weight: .black, width: .compressed) as CTFont
        case .moshPit:
            switch hash(word, 3) % 4 {
            case 0: return CTFontCreateWithName("Rockwell-Bold" as CFString, size - 2, nil)
            case 1: return CTFontCreateWithName("Phosphate-Solid" as CFString, size, nil)
            case 2: return CTFontCreateWithName("AmericanTypewriter-Bold" as CFString, size - 2, nil)
            default: return NSFont.systemFont(ofSize: size, weight: .black, width: .condensed) as CTFont
            }
        }
    }

    /// Chinese, Japanese and Korean, at the canvas's finer grid.
    private func cjkFont(word: Int, size: Int) -> CTFont {
        let size = CGFloat(size * Self.fine)
        switch style {
        case .glitch where word % 2 == 1:
            return CTFontCreateWithName("HiraMinProN-W6" as CFString, size, nil)
        case .moshPit where hash(word, 3) % 2 == 0:
            return CTFontCreateWithName("HiraMinProN-W6" as CFString, size, nil)
        case .rockingBoat, .posterStomp:
            return NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
        default:
            return CTFontCreateWithName("HiraginoSans-W7" as CFString, size, nil)
        }
    }

    /// Words sung longer are set bigger, as a poster sets the word you'd shout. Only Poster Stomp does this.
    private func wordSizes(_ line: LyricLine, base: Int) -> [Int] {
        guard style == .posterStomp, !line.words.isEmpty else { return Array(repeating: base, count: line.words.count) }
        let durations = line.words.map { max($0.end - $0.start, 0.05) }
        let median = durations.sorted()[durations.count / 2]
        return durations.map { duration in
            let factor = min(max(0.82 + 0.32 * log2(duration / median), 0.75), 1.4)
            return max(Int((Double(base) * factor).rounded()), 8)
        }
    }

    // MARK: Layout

    private struct Placed {
        var glyph: PixelGlyph
        /// The pen's start, in canvas pixels from the row's left edge.
        var x: CGFloat
        var row: Int
        var word: Int
        /// Index among the word's letters, and how many it has.
        var letter: Int
        var letters: Int
        /// Index among the line's letters.
        var index: Int
    }

    private struct LineLayout {
        var glyphs: [Placed]
        var rowWidths: [CGFloat]
        var rowHeight: CGFloat
        var size: Int
        var rows: Int { rowWidths.count }

        /// The baseline of `row` for a block centred on `center`.
        func baseline(_ row: Int, center: CGPoint) -> CGFloat {
            let top = center.y + CGFloat(rows) * rowHeight / 2
            return (top - rowHeight * (CGFloat(row) + 0.5) - CGFloat(size * RockLyricsArt.fine) * 0.36).rounded()
        }

        func left(_ row: Int, center: CGPoint) -> CGFloat {
            (center.x - rowWidths[row] / 2).rounded()
        }
    }

    private static var layouts: [String: LineLayout] = [:]

    private func layout(_ line: LyricLine, maxWidth: CGFloat) -> LineLayout {
        let key = "\(style.rawValue)|\(Int(maxWidth))|\(line.start)|\(line.text)"
        if let known = Self.layouts[key] { return known }
        let base = mainSize
        var result: LineLayout?
        // The biggest size that fits on one row, then two rows a little smaller.
        for size in [base, base - 2, base - 4] where size >= 8 {
            let candidate = arrange(line, size: size, breakAt: nil)
            if candidate.rowWidths[0] <= maxWidth { result = candidate; break }
        }
        if result == nil {
            let size = base - 2
            let whole = arrange(line, size: size, breakAt: nil)
            // Break at the word boundary nearest the middle.
            var best = 1, bestDistance = CGFloat.infinity, running: CGFloat = 0
            for word in 0..<line.words.count {
                let widths = whole.glyphs.filter { $0.word == word }
                running = widths.last.map { $0.x + $0.glyph.advance } ?? running
                let distance = abs(running - whole.rowWidths[0] / 2)
                if word + 1 < line.words.count, distance < bestDistance { bestDistance = distance; best = word + 1 }
            }
            result = arrange(line, size: size, breakAt: best)
        }
        let layout = result!
        if Self.layouts.count > 200 { Self.layouts.removeAll() }
        Self.layouts[key] = layout
        return layout
    }

    private func arrange(_ line: LyricLine, size: Int, breakAt: Int?) -> LineLayout {
        let sizes = wordSizes(line, base: size)
        var glyphs: [Placed] = []
        var widths: [CGFloat] = [0]
        var x: CGFloat = 0, row = 0, visible = 0
        let tracking: CGFloat = style == .moshPit ? u : 0
        for (wordIndex, word) in line.words.enumerated() {
            if let breakAt, wordIndex == breakAt {
                widths[row] = trimmedWidth(glyphs.filter { $0.row == row })
                row += 1
                widths.append(0)
                x = 0
            }
            let characters = Array(displayText(word.text, word: wordIndex))
            let letters = characters.filter { !$0.isWhitespace }.count
            var letter = 0
            for character in characters {
                let cjk = character.needsFineGrid
                let font = cjk ? cjkFont(word: wordIndex, size: sizes[wordIndex])
                    : latinFont(word: wordIndex, size: sizes[wordIndex])
                let glyph = PixelGlyph.make(character, font: font, fine: cjk ? 1 : Self.fine)
                if row == 0, x == 0, character.isWhitespace { continue }
                glyphs.append(Placed(glyph: glyph, x: x, row: row, word: wordIndex, letter: letter,
                                     letters: max(letters, 1), index: visible))
                x += glyph.advance + (character.isWhitespace ? (style == .moshPit ? 2 * u : 0) : tracking)
                if !character.isWhitespace {
                    letter += 1
                    visible += 1
                }
            }
        }
        widths[row] = trimmedWidth(glyphs.filter { $0.row == row })
        let tallest = sizes.max() ?? size
        return LineLayout(glyphs: glyphs, rowWidths: widths, rowHeight: CGFloat(tallest * Self.fine) * 1.3, size: size)
    }

    /// A row's width without the spaces at its end.
    private func trimmedWidth(_ glyphs: [Placed]) -> CGFloat {
        guard let last = glyphs.last(where: { !$0.glyph.isBlank }) else { return 0 }
        return (last.x + last.glyph.advance).rounded(.up)
    }

    // MARK: Colours

    private enum Ink {
        static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }

        static let white = rgb(242, 248, 246)
        static let waiting = rgb(150, 188, 182)
        static let shadow = rgb(6, 16, 20, 0.85)
        static let hollow = rgb(10, 24, 28, 0.92)
        static let koi = rgb(246, 146, 66)
        static let gold = rgb(255, 200, 90)
        static let cream = rgb(255, 240, 205)
        static let volt = rgb(255, 222, 60)
        static let cyan = rgb(70, 238, 255)
        static let magenta = rgb(255, 56, 160)
        static let red = rgb(255, 72, 72)
        static let ink = rgb(28, 8, 36)

        static func mix(_ a: CGColor, _ b: CGColor, _ t: Double) -> CGColor {
            let t = CGFloat(min(max(t, 0), 1))
            let ca = a.components ?? [1, 1, 1, 1], cb = b.components ?? [1, 1, 1, 1]
            return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t,
                           blue: ca[2] + (cb[2] - ca[2]) * t, alpha: ca[3] + (cb[3] - ca[3]) * t)
        }
    }

    // MARK: Drawing lines

    private func drawCurrent(_ layout: LineLayout, line: LyricLine, in ctx: CGContext, center: CGPoint,
                             scene: LyricsScene, time: TimeInterval, beat: BeatGrid?) {
        let p = scene.arrival
        let fadeIn = still ? p : min(1, p * 2.5)

        if style == .glitch {
            drawTape(layout, line: line, in: ctx, center: center, time: time)
        }

        for placed in layout.glyphs where !placed.glyph.isBlank {
            var anchor = CGPoint(x: layout.left(placed.row, center: center) + placed.x + placed.glyph.advance / 2,
                                 y: layout.baseline(placed.row, center: center))
            var pose = pose(for: placed, layout: layout, line: line, time: time, beat: beat)
            if p < 1, !still {
                let entry = entrance(for: placed, progress: p, center: center, anchor: anchor, line: line)
                anchor.x = center.x + (anchor.x - center.x) * entry.sx + entry.dx
                anchor.y = center.y + (anchor.y - center.y) * entry.sy + entry.dy
                pose.rotation += entry.rotation
                pose.sx *= entry.sx
                pose.sy *= entry.sy
                pose.split = max(pose.split, entry.split)
            }
            let alpha = pose.opacity * fadeIn
            for ghost in pose.ghosts {
                stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: pose.color,
                      offset: CGPoint(x: ghost.dx, y: ghost.dy), alpha: alpha * ghost.alpha)
            }
            if pose.outline {
                for (ox, oy) in [(-u, 0), (u, 0), (0, -u), (0, u), (-u, -u), (u, -u), (-u, u), (u, u)] {
                    stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: pose.color, offset: CGPoint(x: ox, y: oy),
                          alpha: alpha)
                }
                stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.hollow, alpha: alpha)
                continue
            }
            stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.shadow, offset: CGPoint(x: u, y: -u),
                  alpha: alpha)
            if pose.split > 0.5 {
                stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.cyan, offset: CGPoint(x: -pose.split, y: 0),
                      alpha: alpha * 0.9, blend: .screen)
                stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.magenta, offset: CGPoint(x: pose.split, y: 0),
                      alpha: alpha * 0.9, blend: .screen)
            }
            stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: pose.color, alpha: alpha)
            if style == .stageDive, !still {
                drawDust(placed, line: line, in: ctx, anchor: anchor, time: time)
            }
            if style == .moshPit, alpha > 0.9 {
                drawSpecks(placed, in: ctx, anchor: anchor, pose: pose)
            }
        }
    }

    /// How a letter comes in over the `lead` before its line starts: each style has its own entrance, the way
    /// it has its own exit, so a change of style reads as a hand-over. Scale is about the line's centre.
    private func entrance(for placed: Placed, progress p: Double, center: CGPoint, anchor: CGPoint, line: LyricLine) -> Pose {
        var entry = Pose()
        // Lines take turns coming in from the left and the right.
        let side: CGFloat = Int(line.start * 10).isMultiple(of: 2) ? 1 : -1
        switch style {
        case .headbang:
            // Drops in from above, falling faster as it goes, and lands as the first word does.
            entry.dy = CGFloat(1 - p * p) * 16 * u
        case .rockingBoat:
            // Drifts in from the side, rolling, and settles level.
            let eased = easeOut(p)
            entry.dx = -side * CGFloat(1 - eased) * 40 * u
            entry.rotation = Double(side) * 0.25 * (1 - eased)
            entry.dy = CGFloat(sin(p * .pi)) * 3 * u
        case .posterStomp:
            // Stamped on: big and close, pressed down to size.
            let press = CGFloat((1 - p) * (1 - p))
            entry.sx = 1 + 0.7 * press
            entry.sy = entry.sx
        case .stageDive:
            // The faint slots rise into place; the letters drop in on their own words.
            entry.dy = -CGFloat(1 - easeOut(p)) * 6 * u
        case .glitch:
            // Jumps in sideways in hard steps, the colours torn apart, as a bad signal does.
            let steps = (CGFloat(1 - p) * 5).rounded(.up)
            entry.dx = side * steps * 9 * u * (placed.row.isMultiple(of: 2) ? 1 : -0.6)
            entry.split = 4 * u * CGFloat(1 - p)
        case .moshPit:
            // Every letter flies in from its own direction, spinning, and crashes into place.
            let angle = Double(hash(placed.index, 41) % 628) / 100
            let back = easeOutBack(p)
            entry.dx = CGFloat(cos(angle) * (1 - back)) * 45 * u
            entry.dy = CGFloat(sin(angle) * (1 - back)) * 30 * u
            entry.rotation = (1 - back) * 2.5 * (placed.index.isMultiple(of: 2) ? 1 : -1)
        }
        return entry
    }

    private func drawLeaving(_ layout: LineLayout, line: LyricLine, in ctx: CGContext, center: CGPoint, progress q: Double) {
        for placed in layout.glyphs where !placed.glyph.isBlank {
            let anchor = CGPoint(x: layout.left(placed.row, center: center) + placed.x + placed.glyph.advance / 2,
                                 y: layout.baseline(placed.row, center: center))
            var pose = Pose()
            pose.color = Ink.white
            var alpha = 1 - q
            if !still {
                let side: CGFloat = placed.index.isMultiple(of: 2) ? 1 : -1
                switch style {
                case .headbang:
                    pose.dy = -CGFloat(q * q) * 14 * u
                    alpha = 1 - q * q
                case .rockingBoat:
                    pose.dy = -CGFloat(q) * 10 * u
                    pose.rotation = 0.25 * q * Double(side)
                case .posterStomp:
                    pose.sx = 1 + CGFloat(q) * 0.25
                    pose.sy = pose.sx
                case .stageDive:
                    let late = max(0, q - Double(placed.index % 6) * 0.04)
                    pose.dy = -CGFloat(late * late) * CGFloat(ctx.height)
                    pose.rotation = late * 0.6 * Double(side)
                    alpha = 1
                case .glitch:
                    pose.dx = CGFloat(q) * 40 * u * (placed.word.isMultiple(of: 2) ? 1 : -1)
                    pose.split = 4 * u * CGFloat(1 - q)
                case .moshPit:
                    let angle = Double(hash(placed.index, 31) % 628) / 100
                    pose.dx = CGFloat(cos(angle) * q) * 40 * u
                    pose.dy = CGFloat(sin(angle) * q) * 30 * u
                    pose.rotation = q * 3 * Double(side)
                    alpha = 1 - q * q
                }
            }
            stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.shadow, offset: CGPoint(x: u, y: -u),
                  alpha: alpha)
            if pose.split > 0.5 {
                stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.cyan, offset: CGPoint(x: -pose.split, y: 0),
                      alpha: alpha, blend: .screen)
                stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: Ink.magenta, offset: CGPoint(x: pose.split, y: 0),
                      alpha: alpha, blend: .screen)
            }
            stamp(placed.glyph, in: ctx, at: anchor, pose: pose, color: pose.color, alpha: alpha)
        }
    }

    // MARK: Camera

    private struct Camera {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var rotation: CGFloat = 0
        var scale: CGFloat = 1
        var flash: Double = 0
    }

    private func cameraFrame(lyrics: Lyrics, scene: LyricsScene, time: TimeInterval, beat: BeatGrid?) -> Camera {
        var camera = Camera()
        guard !still, let index = scene.current else { return camera }
        let line = lyrics.lines[index]
        let strength = beat?.confidence ?? 0
        let since = beat?.sinceBeat(at: time) ?? 1
        let until = beat?.untilBeat(at: time) ?? 1
        let beatIndex = beat?.index(at: time) ?? 0
        let kick = strength * exp(-since / 0.1)
        let windup = until < 0.09 ? strength * (1 - until / 0.09) : 0
        let impact = lastImpact(line, time: time)
        let side: Double = beatIndex.isMultiple(of: 2) ? 1 : -1

        switch style {
        case .headbang:
            // Lift on the wind-up, slam down on the beat, tipping toward alternate sides.
            camera.dy = CGFloat(windup * 1.5 - kick * 3) * u
            camera.rotation = CGFloat(side * 0.03 * strength * (1 - exp(-since / 0.05)) * exp(-since / 0.35))
            camera.scale = 1 + CGFloat(0.025 * kick)
        case .rockingBoat:
            // A boat on the water: at the far end of its roll on every beat, swinging through level between.
            guard let beat else { break }
            let phase = since / beat.period
            let swing = cos(.pi * (Double(beatIndex) + phase * phase))
            let recoil = exp(-since / 0.09) * sin(since * 2 * .pi * 7) * side
            camera.rotation = CGFloat(strength * (0.06 * swing + 0.015 * recoil))
            camera.dy = CGFloat(strength * abs(swing) * 1.5) * u
        case .posterStomp:
            camera.scale = 1 + CGFloat(0.04 * kick)
            camera.dy = -CGFloat(kick * 1.5) * u
        case .stageDive:
            let shake = 3 * impact.weight * exp(-impact.since / 0.11)
            camera.dx = CGFloat(shake * sin(impact.since * 2 * .pi * 21 + impact.seed)) * u
            camera.dy = CGFloat(shake * 0.7 * sin(impact.since * 2 * .pi * 17 + impact.seed * 2) - kick * 1.2) * u
        case .glitch:
            // A sideways jolt for a frame or two on each beat.
            camera.dx = since < 0.05 ? CGFloat(strength * side * 4) * u : 0
            camera.scale = 1 + CGFloat(0.03 * kick)
        case .moshPit:
            let shake = 4 * impact.weight * exp(-impact.since / 0.12) + 1.8 * kick
            camera.dx = CGFloat(shake * sin(time * 2 * .pi * 23 + impact.seed)) * u
            camera.dy = CGFloat(shake * 0.8 * sin(time * 2 * .pi * 19 + impact.seed * 3) - kick * 1.5) * u
            camera.rotation = CGFloat(0.035 * kick * side)
            // An impact frame as a line's first word lands.
            if impact.first, impact.since >= 0, impact.since < 0.05 { camera.flash = 1 - impact.since / 0.05 }
        }
        return camera
    }

    /// The word that landed most recently, how long ago, and how hard.
    private func lastImpact(_ line: LyricLine, time: TimeInterval) -> (since: Double, weight: Double, seed: Double, first: Bool) {
        guard let index = line.words.lastIndex(where: { $0.start <= time }) else { return (1, 0, 0, false) }
        let word = line.words[index]
        let weight = index == 0 ? 1.4 : min(1, 0.55 + (word.end - word.start))
        return (time - word.start, weight, Double(hash(index, 11) % 100) / 15, index == 0)
    }

    // MARK: Letters

    private struct Pose {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var rotation: Double = 0
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        var color = Ink.white
        var opacity: Double = 1
        /// Drawn hollow: the letter's edge only.
        var outline = false
        /// Cyan and magenta copies pulled apart by this many canvas pixels.
        var split: CGFloat = 0
        /// Earlier positions left behind by fast motion.
        var ghosts: [(dx: CGFloat, dy: CGFloat, alpha: Double)] = []
    }

    private func pose(for placed: Placed, layout: LineLayout, line: LyricLine, time: TimeInterval, beat: BeatGrid?) -> Pose {
        var pose = Pose()
        let word = line.words[placed.word]
        let stagger: TimeInterval = switch style {
        case .rockingBoat: 0.035
        case .stageDive: 0.02
        case .moshPit: 0.012
        default: 0.015
        }
        let t = time - (word.start + Double(placed.letter) * stagger)
        let sung = t >= 0
        let holding = sung && time < word.end && time - word.start > 0.28
        let since = beat?.sinceBeat(at: time) ?? 1
        let kick = (beat?.confidence ?? 0) * exp(-since / 0.1)
        pose.color = sung ? Ink.white : Ink.waiting
        pose.opacity = sung ? 1 : 0.9

        switch style {
        case .headbang:
            if sung { pose.color = Ink.mix(Ink.koi, Ink.white, 1 - exp(-t / 0.18)) }
            guard !still else { break }
            if t > -0.07, t < 0 {
                // Anticipation: up and a little taller before the slam.
                let a = 1 + t / 0.07
                pose.dy = CGFloat(a * 2) * u
                pose.sy = 1 + 0.1 * CGFloat(a)
                pose.sx = 1 - 0.06 * CGFloat(a)
            } else if sung {
                let pop = 0.35 * spring(t, frequency: 5, decay: 0.12)
                let squash = 0.16 * exp(-t / 0.05)
                pose.sx = CGFloat((1 + pop) * (1 + squash))
                pose.sy = CGFloat((1 + pop) * (1 - squash))
            }
            if holding { pose.dy += CGFloat(0.5 * sin(time * 2 * .pi * 11 + Double(placed.letter))) * u }

        case .rockingBoat:
            if sung { pose.color = Ink.mix(Ink.gold, Ink.cream, 1 - exp(-t / 0.3)) }
            guard !still else { break }
            if t > -0.12, t < 0.2 {
                // Each letter rolls in from the left like a wheel and lands with a little overshoot.
                let p = min(max((t + 0.12) / 0.32, 0), 1)
                let back = easeOutBack(p)
                pose.rotation = .pi * (1 - back)
                pose.dx = -CGFloat(1 - back) * 9 * u
                pose.dy = CGFloat(sin(.pi * p)) * 4 * u
            }
            if holding { pose.dy += CGFloat(1.5 * sin(time * 2 * .pi * 2.2 - Double(placed.letter) * 0.7)) * u }

        case .posterStomp:
            pose.outline = !sung
            if sung { pose.color = Ink.mix(Ink.volt, Ink.white, 1 - exp(-t / 0.25)) }
            guard !still else { break }
            if t > -0.06, t < 0 {
                pose.dy = CGFloat(1 + t / 0.06) * 2 * u
            } else if sung {
                let stomp = exp(-t / 0.07)
                pose.dy = -CGFloat(stomp * cos(t * 2 * .pi * 4)) * 2.5 * u
                pose.sx = 1 + 0.14 * CGFloat(stomp)
                pose.sy = 1 - 0.12 * CGFloat(stomp)
            }

        case .stageDive:
            if sung { pose.color = Ink.mix(Ink.volt, Ink.white, 1 - exp(-t / 0.15)) }
            guard !still else { break }
            let fall = 0.16, hold = 0.04
            if t > -fall, t < 0 {
                // Falling from the top of the screen, stretched by the speed, leaving a smear behind.
                let p = 1 + t / fall
                let drop = CGFloat(layout.size * Self.fine) * 7
                pose.dy = drop * CGFloat((1 - p) * (1 - p))
                pose.sy = 1 + 1.1 * CGFloat(p)
                pose.sx = 1 - 0.35 * CGFloat(p)
                pose.color = Ink.white
                for (lag, alpha) in [(0.02, 0.4), (0.04, 0.2)] {
                    let q = max(1 + (t - lag) / fall, 0)
                    pose.ghosts.append((0, drop * CGFloat((1 - q) * (1 - q)) - pose.dy, alpha))
                }
            } else if sung {
                // Hit-stop: the flattest frame held a moment, then a spring back up past full height.
                let bounce = spring(max(t - hold, 0), frequency: 6, decay: 0.1)
                pose.sx = 1 + 0.45 * CGFloat(bounce)
                pose.sy = 1 - 0.38 * CGFloat(bounce)
            } else {
                // Not sung yet: a faint slot where the letter will land.
                pose.opacity = 0.45
            }

        case .glitch:
            let onTape = isCurrent(placed.word, line: line, time: time)
                ? min(max((time - word.start - 0.05) / 0.04, 0), 1) : 0
            if sung { pose.color = Ink.mix(Ink.white, Ink.ink, still ? (onTape > 0 ? 1 : 0) : onTape) }
            guard !still else { break }
            if sung, t < 0.14 {
                // A giant slam that snaps back to size, the colours torn apart for a moment.
                let snap = 2.2 * exp(-t / 0.035) - 0.08 * sin(t / 0.14 * .pi)
                pose.sx = 1 + CGFloat(snap)
                pose.sy = 1 + CGFloat(snap)
            }
            pose.split = sung ? (4 * CGFloat(exp(-t / 0.09)) + 2 * CGFloat(kick)) * u : CGFloat(kick) * u

        case .moshPit:
            if sung {
                let palette = [Ink.white, Ink.white, Ink.red, Ink.white, Ink.volt]
                pose.color = palette[hash(placed.index, 5) % palette.count]
            }
            guard !still else { break }
            // A ransom-note jumble: every letter keeps its own tilt and height.
            pose.rotation = (Double(hash(placed.index, 7) % 17) - 8) / 180 * .pi
            pose.dy = CGFloat(hash(placed.index, 13) % 3 - 1) * u
            // Every beat kicks the crowd in a wave across the line.
            let delay = Double(placed.x / max(layout.rowWidths[placed.row], 1)) * 0.1
            let wave = since >= delay ? (beat?.confidence ?? 0) * exp(-(since - delay) / 0.09) : 0
            pose.dy += CGFloat(wave) * 4 * u
            pose.rotation += wave * 0.15 * (placed.index.isMultiple(of: 2) ? 1 : -1)
            if t > -0.05, t < 0 {
                let a = 1 + t / 0.05
                pose.sx = 1 - 0.25 * CGFloat(a)
                pose.sy = pose.sx
            } else if sung, t < 0.45 {
                let pop = t < 0.03 ? 0.9 : 0.9 * spring(t - 0.03, frequency: 4.5, decay: 0.09)
                pose.sx = 1 + CGFloat(pop)
                pose.sy = pose.sx
                if t < 0.1 { pose.ghosts = [(-3 * u, 0, 0.3), (3 * u, 0, 0.2)] }
            }
            if holding { pose.dx += CGFloat(0.8 * sin(time * 2 * .pi * 13 + Double(placed.index))) * u }
        }
        return pose
    }

    /// The word being sung: from its start until the next word starts.
    private func isCurrent(_ index: Int, line: LyricLine, time: TimeInterval) -> Bool {
        let word = line.words[index]
        guard time >= word.start else { return false }
        let next = line.words.indices.contains(index + 1) ? line.words[index + 1].start : word.end + 0.3
        return time < max(next, word.start + 0.12)
    }

    // MARK: Pond reactions

    private func landings(_ layout: LineLayout, line: LyricLine, center: CGPoint, time: TimeInterval, since: TimeInterval,
                          beat: BeatGrid?) -> [Landing] {
        guard time > since, time - since < 0.5 else { return [] }
        var result: [Landing] = []
        func wordCenter(_ index: Int) -> CGPoint? {
            let letters = layout.glyphs.filter { $0.word == index && !$0.glyph.isBlank }
            guard let first = letters.first, let last = letters.last else { return nil }
            let left = layout.left(first.row, center: center) + first.x
            let right = layout.left(last.row, center: center) + last.x + last.glyph.advance
            return CGPoint(x: (left + right) / 2, y: layout.baseline(first.row, center: center))
        }
        for (index, word) in line.words.enumerated() where word.start > since && word.start <= time {
            let held = word.end - word.start
            switch style {
            case .stageDive:
                if let point = wordCenter(index) { result.append(Landing(point: point, strength: index == 0 ? 1.1 : Float(0.5 + min(held, 1) * 0.4))) }
            case .moshPit:
                if index == 0 || held > 0.5, let point = wordCenter(index) {
                    result.append(Landing(point: point, strength: index == 0 ? 1.3 : 0.8))
                }
            case .headbang:
                if index == 0, let point = wordCenter(index) { result.append(Landing(point: point, strength: 0.6)) }
            default:
                break
            }
        }
        if style == .rockingBoat, let beat, beat.confidence > 0.4 {
            // The boat's roll sends a ring across the water every other beat.
            let now = beat.index(at: time), before = beat.index(at: since)
            if now != before, now.isMultiple(of: 2) {
                result.append(Landing(point: CGPoint(x: center.x, y: center.y - CGFloat(layout.size * Self.fine)),
                                      strength: 0.45))
            }
        }
        return result
    }

    // MARK: Drawing helpers

    /// Draws one glyph through its mask, posed about its baseline centre.
    private func stamp(_ glyph: PixelGlyph, in ctx: CGContext, at anchor: CGPoint, pose: Pose, color: CGColor,
                       offset: CGPoint = .zero, alpha: Double = 1, blend: CGBlendMode = .normal) {
        guard alpha > 0.01, let mask = glyph.mask else { return }
        ctx.saveGState()
        let x = anchor.x + pose.dx + offset.x, y = anchor.y + pose.dy + offset.y
        if pose.rotation == 0, abs(pose.sx - 1) < 0.01, abs(pose.sy - 1) < 0.01 {
            ctx.translateBy(x: x.rounded(), y: y.rounded())
        } else {
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: CGFloat(pose.rotation))
            ctx.scaleBy(x: pose.sx, y: pose.sy)
        }
        let rect = CGRect(x: (-glyph.advance / 2).rounded() + glyph.originX, y: -CGFloat(glyph.descent),
                          width: CGFloat(mask.width), height: CGFloat(mask.height))
        ctx.clip(to: rect, mask: mask)
        ctx.setBlendMode(blend)
        ctx.setAlpha(CGFloat(alpha))
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// The cyan tape under the word being sung, swiped on.
    private func drawTape(_ layout: LineLayout, line: LyricLine, in ctx: CGContext, center: CGPoint, time: TimeInterval) {
        guard let index = line.words.indices.first(where: { isCurrent($0, line: line, time: time) }) else { return }
        let letters = layout.glyphs.filter { $0.word == index && !$0.glyph.isBlank }
        guard let first = letters.first, let last = letters.last else { return }
        let t = time - line.words[index].start
        let wipe = still ? 1 : min(max(t / 0.07, 0), 1)
        let left = layout.left(first.row, center: center) + first.x - 3 * u
        let right = layout.left(last.row, center: center) + last.x + last.glyph.advance + 3 * u
        let baseline = layout.baseline(first.row, center: center)
        let rect = CGRect(x: left, y: baseline - CGFloat(layout.size * Self.fine) * 0.32,
                          width: (right - left) * CGFloat(wipe), height: CGFloat(layout.size * Self.fine) * 1.15)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: 0.07)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        let skew = 3 * u
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX - skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + skew, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + skew, y: rect.maxY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(Ink.magenta)
        ctx.translateBy(x: 2 * u, y: -2 * u)
        ctx.fillPath()
        ctx.translateBy(x: -2 * u, y: 2 * u)
        ctx.addPath(path)
        ctx.setFillColor(Ink.cyan)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Pixel dust kicked out sideways where a word's outer letters land.
    private func drawDust(_ placed: Placed, line: LyricLine, in ctx: CGContext, anchor: CGPoint, time: TimeInterval) {
        guard placed.letter == 0 || placed.letter == placed.letters - 1 else { return }
        let word = line.words[placed.word]
        let t = time - (word.start + Double(placed.letter) * 0.02) - 0.04
        guard t > 0, t < 0.4 else { return }
        let side: CGFloat = placed.letter == 0 && placed.letters > 1 ? -1 : 1
        let foot = anchor.x + side * placed.glyph.advance / 2
        for puff in 0..<4 {
            let speed = CGFloat(60 + hash(placed.index * 4 + puff, 23) % 80) * u
            let lift = CGFloat(40 + hash(placed.index * 4 + puff, 29) % 60) * u
            let x = foot + side * speed * CGFloat(t)
            let y = anchor.y + u + lift * CGFloat(t) - 220 * u * CGFloat(t * t)
            ctx.setFillColor(Ink.mix(Ink.volt, Ink.white, Double(puff) / 3).copy(alpha: CGFloat(1 - t / 0.4))!)
            ctx.fill(CGRect(x: (x / u).rounded() * u, y: (y / u).rounded() * u, width: u, height: u))
        }
    }

    /// Worn print: a few art pixels knocked out of each letter, the same ones every frame.
    private func drawSpecks(_ placed: Placed, in ctx: CGContext, anchor: CGPoint, pose: Pose) {
        ctx.saveGState()
        ctx.translateBy(x: anchor.x + pose.dx, y: anchor.y + pose.dy)
        ctx.rotate(by: CGFloat(pose.rotation))
        ctx.scaleBy(x: pose.sx, y: pose.sy)
        ctx.setBlendMode(.clear)
        let height = CGFloat(placed.glyph.mask?.height ?? 0) - CGFloat(placed.glyph.descent)
        for speck in 0..<3 {
            let x = (CGFloat(hash(placed.index * 7 + speck, 17) % 100) / 100 - 0.5) * placed.glyph.advance * 0.7
            let y = CGFloat(hash(placed.index * 5 + speck, 19) % 100) / 100 * height * 0.8
            ctx.fill(CGRect(x: (x / u).rounded() * u, y: (y / u).rounded() * u, width: u, height: u))
        }
        ctx.restoreGState()
    }

    // MARK: Math

    /// A damped spring let go from 1: starts at 1, swings past 0, settles at 0.
    private func spring(_ t: Double, frequency: Double, decay: Double) -> Double {
        guard t >= 0 else { return 1 }
        return exp(-t / decay) * cos(t * 2 * .pi * frequency)
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }

    private func easeOutBack(_ x: Double) -> Double {
        let x = min(max(x, 0), 1), c1 = 1.9, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// A stable small number for a letter or word, so its jumble is the same every frame.
    private func hash(_ value: Int, _ salt: Int) -> Int {
        var h = UInt64(truncatingIfNeeded: value &* 73_856_093 ^ salt &* 19_349_663)
        h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
        h ^= h >> 33
        return Int(h % 10_000)
    }
}

// MARK: - Glyphs

/// One character as an on/off pixel mask, ready to be posed and coloured.
struct PixelGlyph {
    /// White where the letter is, in canvas pixels; nil for spaces.
    let mask: CGImage?
    /// Canvas pixels from the image's bottom up to the baseline.
    let descent: Int
    /// From the pen's start to the image's left edge, in canvas pixels.
    let originX: CGFloat
    /// The pen's advance, in canvas pixels.
    let advance: CGFloat
    var isBlank: Bool { mask == nil }

    private static var cache: [String: PixelGlyph] = [:]

    /// `fine` > 1 draws the font at its size, one canvas pixel per font pixel, then blows each pixel up into
    /// a `fine` × `fine` block: chunky Latin. At 1 the font is drawn straight onto the canvas grid, with edges
    /// in quarter steps: readable CJK.
    static func make(_ character: Character, font: CTFont, fine: Int) -> PixelGlyph {
        let key = "\(character)|\(CTFontCopyPostScriptName(font))|\(CTFontGetSize(font))|\(fine)"
        if let known = cache[key] { return known }
        let string = String(character)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        var ascent: CGFloat = 0, descentValue: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descentValue, nil))
        var glyph = PixelGlyph(mask: nil, descent: 0, originX: 0, advance: (advance * CGFloat(fine)).rounded())
        if !character.isWhitespace {
            let pad = 2
            let width = Int(advance.rounded(.up)) + pad * 2
            let below = Int(descentValue.rounded(.up)) + 1
            let height = Int(ascent.rounded(.up)) + below + 1
            var bytes = [UInt8](repeating: 0, count: width * height)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.setShouldAntialias(fine == 1)
                ctx.setAllowsFontSmoothing(false)
                ctx.setShouldSubpixelPositionFonts(false)
                ctx.textPosition = CGPoint(x: pad, y: below)
                CTLineDraw(line, ctx)
                return true
            }
            if drawn, bytes.contains(where: { $0 > 60 }) {
                // Quarter steps on the fine grid; on or off on the chunky one.
                let levels = bytes.map { value -> UInt8 in
                    if fine > 1 { return value > 100 ? 255 : 0 }
                    let quarters = (Int(value) * 4 + 160) / 255
                    return UInt8(min(quarters, 4) * 255 / 4)
                }
                let scaledWidth = width * fine, scaledHeight = height * fine
                var scaled = [UInt8](repeating: 0, count: scaledWidth * scaledHeight)
                for row in 0..<height {
                    for column in 0..<width where levels[row * width + column] > 0 {
                        for dy in 0..<fine {
                            for dx in 0..<fine {
                                scaled[(row * fine + dy) * scaledWidth + column * fine + dx] = levels[row * width + column]
                            }
                        }
                    }
                }
                if let provider = CGDataProvider(data: Data(scaled) as CFData) {
                    let image = CGImage(width: scaledWidth, height: scaledHeight, bitsPerComponent: 8, bitsPerPixel: 8,
                                        bytesPerRow: scaledWidth, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                    glyph = PixelGlyph(mask: image, descent: below * fine, originX: -CGFloat(pad * fine),
                                       advance: (advance * CGFloat(fine)).rounded())
                }
            }
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = glyph
        return glyph
    }
}

extension Character {
    /// Characters too intricate for the chunky grid: anything from Hebrew on, except punctuation and symbols
    /// (the same rule as the player's text).
    var needsFineGrid: Bool {
        unicodeScalars.contains { $0.value >= 0x0590 && !(0x2000...0x2BFF).contains($0.value) }
    }
}
