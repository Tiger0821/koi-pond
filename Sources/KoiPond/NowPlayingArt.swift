import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// What the desktop player shows; filled in from Music by `MusicPlayer`.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    /// Seconds; nil for radio streams.
    var duration: Double?
    /// Seconds into the song at `positionDate`, once Music has said.
    var position: Double?
    var positionDate = Date()
    /// Names the song, for caching its cover.
    var trackKey: String

    func elapsed(at date: Date) -> Double? {
        guard let position else { return nil }
        let elapsed = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return duration.map { min(elapsed, $0) } ?? elapsed
    }
}

enum NowPlayingButton {
    case previous, playPause, next
}

/// A song as the player draws it.
struct SongFace {
    var title: String
    var artist: String
    var cover: CGImage?
}

/// How the player changes songs. Each runs for `duration`: the title comes first, then the cover slides in
/// pixelated and sharpens, then the artist. A style is picked at random for every change.
enum SongTransition: CaseIterable {
    /// The title types itself in; the cover glides in as blocks and sharpens, like a Super Nintendo mosaic.
    case mosaic
    /// The old cover sinks, and the new one surfaces through the water, rippling, and clears.
    case koi
    /// Letters rattle and lock left to right like a departure board; the cover drops in and bounces.
    case flap
    /// Everything fades through an ordered dither; the cover is scanned in line by line.
    case dither

    static let duration: CFTimeInterval = 1.65
}

/// One song change in progress: what was showing before, the style, and when it began.
struct SongChange {
    var from: SongFace?
    var style: SongTransition
    var start: CFTimeInterval

    func milliseconds(at now: CFTimeInterval) -> Double { (now - start) * 1000 }
    func isOver(at now: CFTimeInterval) -> Bool { now - start >= SongTransition.duration }
}

/// Where things sit on a player-like panel, in art pixels from the top left.
struct ArtLayout {
    var panel: CGSize
    var cover: CGRect
    var textX: CGFloat
    var textWidth: CGFloat
    var titleBaseline: CGFloat
    var artistBaseline: CGFloat
    /// A small caption above the title, in the 3×5 pixel font.
    var caption: String?

    /// The panel, plus one pixel each way for its hard shadow.
    var size: CGSize { CGSize(width: panel.width + 1, height: panel.height + 1) }

    static let player = ArtLayout(panel: CGSize(width: 164, height: 48), cover: CGRect(x: 4, y: 4, width: 40, height: 40),
                                  textX: 50, textWidth: 109, titleBaseline: 14, artistBaseline: 27, caption: nil)
    /// The big card a koi throws into the pond when the song changes.
    static let card = ArtLayout(panel: CGSize(width: 200, height: 60), cover: CGRect(x: 5, y: 5, width: 50, height: 50),
                                textX: 62, textWidth: 132, titleBaseline: 33, artistBaseline: 47, caption: "NOW PLAYING")
}

/// The player as pixel art: a small bitmap that the view scales up with nearest-neighbour filtering.
/// Everything here is in art pixels from the top left.
enum NowPlayingArt {
    static var size: CGSize { ArtLayout.player.size }
    /// Image pixels per art pixel. The frame, text and buttons stay chunky; covers use the extra detail,
    /// twice as sharp as the art around them.
    static let detail = 2
    private static let buttons: [(NowPlayingButton, CGRect)] = [
        (.previous, CGRect(x: 48, y: 31, width: 11, height: 15)),
        (.playPause, CGRect(x: 59, y: 31, width: 11, height: 15)),
        (.next, CGRect(x: 70, y: 31, width: 11, height: 15)),
    ]
    private static let bar = CGRect(x: 85, y: 37, width: 54, height: 2)
    private static let timeRight: CGFloat = 159

    static func isCover(at point: CGPoint) -> Bool {
        ArtLayout.player.cover.contains(point)
    }

    /// The button at `point`; `slack` widens each one, for a press that drifts a little before release.
    static func button(at point: CGPoint, slack: CGFloat = 0) -> NowPlayingButton? {
        buttons.first { $0.1.insetBy(dx: -slack, dy: -slack).contains(point) }?.0
    }

    /// The desktop player. While `change` runs, the song arrives through its transition.
    static func image(info: NowPlayingInfo, cover: CGImage?, hovered: NowPlayingButton?, pressed: NowPlayingButton?,
                      controllable: Bool, change: SongChange? = nil, now: Date = Date()) -> CGImage? {
        let layout = ArtLayout.player
        guard let canvas = Canvas(size: layout.size) else { return nil }
        drawPanel(canvas, layout)
        drawSong(canvas, layout, SongFace(title: info.title, artist: info.artist, cover: cover), change: change)

        for (button, _) in buttons {
            let color: CGColor
            if !controllable {
                color = Palette.disabled
            } else if pressed == button {
                color = Palette.pressed
            } else if hovered == button {
                color = Palette.accent
            } else {
                color = Palette.icon
            }
            switch button {
            case .previous: canvas.bitmap(Glyphs.previous, at: CGPoint(x: 50, y: 36), color)
            case .playPause: canvas.bitmap(info.isPlaying ? Glyphs.pause : Glyphs.play, at: CGPoint(x: 61, y: 35), color)
            case .next: canvas.bitmap(Glyphs.next, at: CGPoint(x: 72, y: 36), color)
            }
        }

        if let duration = info.duration, duration > 0, let elapsed = info.elapsed(at: now) {
            let filled = (bar.width * CGFloat(min(max(elapsed / duration, 0), 1))).rounded()
            canvas.fill(bar, Palette.track)
            canvas.fill(CGRect(x: bar.minX, y: bar.minY, width: filled, height: bar.height), Palette.accent)
            canvas.fill(CGRect(x: bar.minX + min(filled, bar.width - 2), y: bar.minY - 1, width: 2, height: 4), Palette.title)
            canvas.tiny(Glyphs.time(elapsed), right: timeRight, top: 36, Palette.artist)
        }
        return canvas.ctx.makeImage()
    }

    /// The song card a koi throws into the pond: the same art at a larger layout, with no controls.
    static func card(song: SongFace, change: SongChange?) -> CGImage? {
        let layout = ArtLayout.card
        guard let canvas = Canvas(size: layout.size) else { return nil }
        drawPanel(canvas, layout)
        if let caption = layout.caption { canvas.tiny(caption, left: layout.textX, top: 12, Palette.accent) }
        drawSong(canvas, layout, song, change: change)
        return canvas.ctx.makeImage()
    }

    private static func drawSong(_ canvas: Canvas, _ layout: ArtLayout, _ song: SongFace, change: SongChange?) {
        canvas.fill(layout.cover.insetBy(dx: -1, dy: -1), Palette.coverFrame)
        canvas.fill(layout.cover, Palette.coverEmpty)
        let now = CACurrentMediaTime()
        let to = Face(song, layout)
        if let change, !change.isOver(at: now) {
            Transitions.draw(change.style, canvas, layout, from: change.from.map { Face($0, layout) }, to: to,
                             t: change.milliseconds(at: now))
        } else {
            Transitions.rest(canvas, layout, to)
        }
    }

    /// A rounded-off rectangle in whole pixels, with a light rim and a hard shadow.
    private static func drawPanel(_ canvas: Canvas, _ layout: ArtLayout) {
        let outer = CGRect(origin: .zero, size: layout.panel)
        canvas.chamfered(outer.offsetBy(dx: 1, dy: 1), corner: 2, Palette.shadow)
        canvas.chamfered(outer, corner: 2, nil)
        canvas.chamfered(outer, corner: 2, Palette.rim)
        canvas.chamfered(outer.insetBy(dx: 1, dy: 1), corner: 1, nil)
        canvas.chamfered(outer.insetBy(dx: 1, dy: 1), corner: 1, Palette.background)
    }
}

// MARK: - Transitions

/// The four song changes, timed in milliseconds from the change. Effects work on whole art pixels:
/// mosaic blocks copy their top-left pixel (as the Super Nintendo's mosaic does, so the pattern holds still
/// while it sharpens), and fades go through a 4×4 ordered (Bayer) dither.
private enum Transitions {
    private static let matrix: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    private static let flapGlyphs = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#*+")

    static func bayer(_ x: Int, _ y: Int) -> Double { (matrix[(y & 3) << 2 | (x & 3)] + 0.5) / 16 }
    static func phase(_ t: Double, _ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
    static func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    static func easeIn(_ p: Double) -> Double { p * p * p }
    static func steps(_ p: Double, _ sizes: [Int]) -> Int { sizes[min(sizes.count - 1, Int(p * Double(sizes.count)))] }

    static func bounce(_ p: Double) -> Double {
        let n = 7.5625, d = 2.75
        if p < 1 / d { return n * p * p }
        if p < 2 / d { let q = p - 1.5 / d; return n * q * q + 0.75 }
        if p < 2.5 / d { let q = p - 2.25 / d; return n * q * q + 0.9375 }
        let q = p - 2.625 / d
        return n * q * q + 0.984375
    }

    static func rest(_ c: Canvas, _ l: ArtLayout, _ to: Face) {
        c.cover(to.pixels, in: l.cover)
        c.text(to.title, x: l.textX, baseline: l.titleBaseline, color: Palette.title)
        c.text(to.artist, x: l.textX, baseline: l.artistBaseline, color: Palette.artist)
    }

    static func draw(_ style: SongTransition, _ c: Canvas, _ l: ArtLayout, from: Face?, to: Face, t: Double) {
        switch style {
        case .mosaic: mosaic(c, l, from, to, t)
        case .koi: koi(c, l, from, to, t)
        case .flap: flap(c, l, from, to, t)
        case .dither: dither(c, l, from, to, t)
        }
    }

    private static func fadeOut(_ c: Canvas, _ l: ArtLayout, _ from: Face, _ out: Double) {
        c.text(from.title, x: l.textX, baseline: l.titleBaseline, color: Palette.title) { bayer($0, $1) > out }
        c.text(from.artist, x: l.textX, baseline: l.artistBaseline, color: Palette.artist) { bayer($0, $1) > out }
    }

    private static func mosaic(_ c: Canvas, _ l: ArtLayout, _ from: Face?, _ to: Face, _ t: Double) {
        let out = phase(t, 0, 220)
        if out < 1, let from {
            let block = steps(out, [1, 2, 4, 8])
            c.cover(from.pixels, in: l.cover, block: block) { bx, by, b in bayer(bx / b, by / b) > out }
            fadeOut(c, l, from, out)
        }
        let typed = phase(t, 200, 640)
        if typed > 0 {
            let shown = String(to.titleString.prefix(Int((Double(to.titleString.count) * typed).rounded())))
            let text = PixelText.make(shown, font: Fonts.title)
            c.text(text, x: l.textX, baseline: l.titleBaseline, color: Palette.title)
            if typed < 1, Int(t / 80) % 2 == 0 {
                c.fill(CGRect(x: l.textX + CGFloat(text.width) + 1, y: l.titleBaseline - 10, width: 2, height: 9), Palette.accent)
            }
        }
        let slide = phase(t, 560, 900), sharpen = phase(t, 900, 1220)
        if slide > 0 {
            c.cover(to.pixels, in: l.cover, dx: Int(((1 - easeOut(slide)) * -Double(l.cover.width + 4)).rounded()),
                    block: sharpen > 0 ? steps(sharpen, [8, 4, 2, 1]) : 8)
        }
        let artist = phase(t, 1120, 1500)
        if artist > 0 {
            c.clipped(CGRect(x: l.textX, y: l.artistBaseline - 11, width: l.textWidth + 4, height: 14)) {
                c.text(to.artist, x: l.textX, baseline: l.artistBaseline + CGFloat(((1 - easeOut(artist)) * 6).rounded()),
                       color: Palette.artist) { bayer($0, $1) < artist * 1.2 }
            }
        }
    }

    private static func koi(_ c: Canvas, _ l: ArtLayout, _ from: Face?, _ to: Face, _ t: Double) {
        let out = phase(t, 0, 320)
        if out < 1, let from {
            c.cover(from.pixels, in: l.cover, dy: Int((easeIn(out) * 22).rounded()), block: out > 0.5 ? 2 : 1,
                    wave: out * 2.5, waveT: t * 0.012, tint: out * 0.85)
            fadeOut(c, l, from, out)
        }
        let ripple = phase(t, 420, 1300)
        if ripple > 0, ripple < 1 {
            let reach = Double(l.panel.width) * 0.6
            c.clipped(CGRect(x: 1, y: 1, width: l.panel.width - 2, height: l.panel.height - 2)) {
                var dots: [CGPoint] = []
                for r in [6 + ripple * reach, ripple * reach - 4] where r >= 2 {
                    let n = Int((r * 6).rounded(.up))
                    for i in 0..<n {
                        let a = Double(i) / Double(n) * 2 * .pi
                        dots.append(CGPoint(x: (Double(l.cover.midX) + cos(a) * r).rounded(),
                                            y: (Double(l.cover.midY) + sin(a) * r * 0.82).rounded()))
                    }
                }
                c.dots(dots, Palette.rgb(205, 236, 240, 0.55 * (1 - ripple)))
            }
        }
        let swim = phase(t, 160, 640)
        if swim > 0 {
            let dx = ((1 - easeOut(swim)) * 34).rounded(), dy = (sin(swim * 11) * (1 - swim) * 2.2).rounded()
            c.clipped(CGRect(x: l.textX, y: l.titleBaseline - 13, width: l.textWidth + 4, height: 15)) {
                c.text(to.title, x: l.textX + dx, baseline: l.titleBaseline + dy, color: Palette.title) { bayer($0, $1) < swim * 1.4 }
            }
        }
        let rise = phase(t, 480, 1250)
        if rise > 0 {
            let settle = 1 - rise
            c.cover(to.pixels, in: l.cover, dy: Int(((1 - easeOut(min(1, rise * 1.7))) * 32).rounded()),
                    block: steps(rise, [6, 4, 2, 1]), wave: 3 * settle * settle, waveT: t * 0.012, tint: 0.7 * settle)
        }
        let artist = phase(t, 1100, 1550)
        if artist > 0 {
            c.text(to.artist, x: l.textX + (sin(t * 0.03) * (1 - artist) * 1.5).rounded(), baseline: l.artistBaseline,
                   color: Palette.artist) { bayer($0, $1) < artist * 1.15 }
        }
    }

    private static func flap(_ c: Canvas, _ l: ArtLayout, _ from: Face?, _ to: Face, _ t: Double) {
        let out = phase(t, 0, 200)
        if out < 1, let from {
            c.cover(from.pixels, in: l.cover, dy: -Int((easeIn(out) * Double(l.cover.height + 4)).rounded()))
            if t < 150 { flapText(c, from.titleString, Fonts.title, l.textX, l.titleBaseline, Palette.title, 0, 0, t, locks: false) }
            c.text(from.artist, x: l.textX, baseline: l.artistBaseline, color: Palette.artist) { bayer($0, $1) > out }
        }
        flapText(c, to.titleString, Fonts.title, l.textX, l.titleBaseline, Palette.title, 150, 35, t)
        let drop = phase(t, 560, 1060)
        if drop > 0 {
            c.cover(to.pixels, in: l.cover, dy: Int(((1 - bounce(drop)) * -Double(l.cover.height + 4)).rounded()),
                    block: drop < 0.6 ? 6 : drop < 0.8 ? 3 : 1)
        }
        flapText(c, to.artistString, Fonts.artist, l.textX, l.artistBaseline, Palette.artist, 1050, 22, t)
    }

    /// Letters rattle through glyphs and lock left to right, each with a flap seam until it does; with
    /// `locks` off they only rattle.
    private static func flapText(_ c: Canvas, _ text: String, _ font: CTFont, _ x: CGFloat, _ baseline: CGFloat,
                                 _ color: CGColor, _ start: Double, _ step: Double, _ t: Double, locks: Bool = true) {
        guard t >= start else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let characters = Array(text)
        var index = 0
        for (i, character) in characters.enumerated() {
            let offset = CGFloat(CTLineGetOffsetForStringIndex(line, index, nil))
            index += character.utf16.count
            let next = CGFloat(CTLineGetOffsetForStringIndex(line, index, nil))
            let lock = locks ? start + Double(i) * step + 110 : .infinity
            let shown = t >= lock ? character : flapGlyphs[(Int(t / 45) * 7 + i * 13) % flapGlyphs.count]
            guard shown != " " else { continue }
            c.text(PixelText.make(String(shown), font: font), x: x + offset.rounded(), baseline: baseline, color: color)
            if t < lock {
                c.fill(CGRect(x: x + offset.rounded(), y: baseline - 4, width: max(next - offset, 5).rounded(), height: 1),
                       Palette.background)
            }
        }
    }

    private static func dither(_ c: Canvas, _ l: ArtLayout, _ from: Face?, _ to: Face, _ t: Double) {
        let out = phase(t, 0, 260)
        if out < 1, let from {
            c.cover(from.pixels, in: l.cover) { bx, by, _ in bayer(bx, by) > out }
            fadeOut(c, l, from, out)
        }
        let wipe = phase(t, 220, 680)
        if wipe > 0 {
            c.text(to.title, x: l.textX, baseline: l.titleBaseline, color: Palette.title) { bayer($0, $1) < wipe * 1.7 - Double($0) / 120 }
        }
        let slide = phase(t, 520, 820), scan = phase(t, 820, 1200)
        if slide > 0 {
            let dx = Int(((1 - easeOut(slide)) * Double(l.cover.width + 4)).rounded())
            if scan <= 0 {
                c.cover(to.pixels, in: l.cover, dx: dx, block: 4)
            } else {
                let line = Int((scan * Double(l.cover.height)).rounded())
                if line > 0 { c.cover(to.pixels, in: l.cover) { _, by, _ in by < line } }
                if line < Int(l.cover.height) { c.cover(to.pixels, in: l.cover, block: 4) { _, by, _ in by + 4 > line } }
                if scan < 1 {
                    c.clipped(l.cover) {
                        c.fill(CGRect(x: l.cover.minX, y: l.cover.minY + CGFloat(line), width: l.cover.width, height: 1),
                               Palette.rgb(255, 246, 228, 0.85))
                        c.fill(CGRect(x: l.cover.minX, y: l.cover.minY + CGFloat(line) - 1, width: l.cover.width, height: 1),
                               Palette.rgb(246, 146, 66, 0.45))
                    }
                }
            }
        }
        let artist = phase(t, 1150, 1550)
        if artist > 0 {
            c.text(to.artist, x: l.textX, baseline: l.artistBaseline, color: Palette.artist) { bayer($0, $1) < artist }
        }
    }
}

// MARK: - Drawing pieces

/// A song readied for one layout: its title and artist fitted to the space and turned into pixels, and its
/// cover as pixels at the cover's size.
private struct Face {
    let titleString: String
    let artistString: String
    let title: PixelText
    let artist: PixelText
    let pixels: CoverPixels

    init(_ song: SongFace, _ layout: ArtLayout) {
        titleString = PixelText.fit(song.title, font: Fonts.title, width: layout.textWidth)
        artistString = PixelText.fit(song.artist, font: Fonts.artist, width: layout.textWidth)
        title = PixelText.make(titleString, font: Fonts.title)
        artist = PixelText.make(artistString, font: Fonts.artist)
        pixels = CoverPixels.make(song.cover, size: Int(layout.cover.width) * NowPlayingArt.detail)
    }
}

/// Text as the pixels the system font lights at this size with antialiasing off, so effects can work
/// on it pixel by pixel. Points are relative to the pen's start on the baseline, in `fine` steps per art pixel.
///
/// Latin, Greek and Cyrillic stay chunky, one art pixel per pixel of an 11-pixel font, each pixel on or off.
/// Chinese, Japanese, Korean and other scripts whose characters need more strokes than 11 pixels can hold
/// are drawn on the bitmap's finer grid (`NowPlayingArt.detail` steps per art pixel), the one covers use, with
/// edge pixels lit in quarter steps: on or off alone, a 22-pixel 麗 or 輸 still melts into a blob.
private struct PixelText {
    /// `a` is how much of the pixel is lit, in quarters (4 is fully).
    let points: [(x: Int, y: Int, a: Int)]
    /// Steps per art pixel the points are in.
    let fine: Int
    /// In art pixels.
    let width: Int

    private static var cache: [String: PixelText] = [:]
    private static var fitted: [String: String] = [:]

    static func width(_ string: String, font: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Whether `string` has characters too intricate for the chunky 11-pixel grid: anything from Hebrew on
    /// (Arabic, Indic scripts, Thai, kana, hangul, Chinese characters, emoji), except punctuation and symbols.
    static func needsDetail(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0.value >= 0x0590 && !(0x2000...0x2BFF).contains($0.value) }
    }

    /// The font at `scale` times its size and a step lighter: at 22 pixels, bold strokes of dense
    /// characters such as 麗 or 間 still run together, so semibold becomes regular and bold becomes medium.
    private static func lighter(_ font: CTFont, scale: Int) -> CTFont {
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait] as? CGFloat) ?? 0
        let lighter: NSFont.Weight = weight >= NSFont.Weight.bold.rawValue - 0.01 ? .medium : .regular
        return NSFont.systemFont(ofSize: CTFontGetSize(font) * CGFloat(scale), weight: lighter) as CTFont
    }

    /// `string`, cut short with an ellipsis if it's wider than `width`.
    static func fit(_ string: String, font: CTFont, width: CGFloat) -> String {
        let key = "\(CTFontGetSize(font))|\(CTFontCopyPostScriptName(font))|\(width)|\(string)"
        if let known = fitted[key] { return known }
        var result = string
        if Self.width(string, font: font) > width {
            var characters = Array(string)
            while characters.count > 1, Self.width(String(characters) + "…", font: font) > width { characters.removeLast() }
            result = String(characters).trimmingCharacters(in: .whitespaces) + "…"
        }
        if fitted.count > 400 { fitted.removeAll() }
        fitted[key] = result
        return result
    }

    static func make(_ string: String, font: CTFont) -> PixelText {
        let key = "\(CTFontGetSize(font))|\(CTFontCopyPostScriptName(font))|\(string)"
        if let known = cache[key] { return known }
        let fine = needsDetail(string) ? NowPlayingArt.detail : 1
        let drawn = fine == 1 ? font : Self.lighter(font, scale: fine)
        let width = Int(Self.width(string, font: drawn).rounded(.up)) + 2 * fine
        let height = 20 * fine, baseline = 5 * fine
        var points: [(x: Int, y: Int, a: Int)] = []
        if let ctx = CGContext(data: nil, width: max(width, 1), height: height, bitsPerComponent: 8, bytesPerRow: max(width, 1),
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.setShouldAntialias(fine > 1)
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: drawn, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            ctx.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), ctx)
            if let data = ctx.data?.assumingMemoryBound(to: UInt8.self) {
                // Memory rows run top down; row r sits (height - 1 - r - baseline) pixels above the baseline.
                for row in 0..<height {
                    for column in 0..<width {
                        let value = Int(data[row * width + column])
                        let quarters = fine == 1 ? (value > 100 ? 4 : 0) : (value * 4 + 160) / 255
                        if quarters > 0 { points.append((column, row - (height - baseline), min(quarters, 4))) }
                    }
                }
            }
        }
        let right = points.map(\.x).max().map { $0 + 1 } ?? 0
        let text = PixelText(points: points, fine: fine, width: (right + fine - 1) / fine)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = text
        return text
    }
}

/// A cover as RGBA pixels at `size` × `size`, top row first, smoothly downsampled so it reads as pixel
/// art; the music note on dark water when there's no cover.
private struct CoverPixels {
    let size: Int
    let rgba: [UInt8]
    let image: CGImage

    private static var cache: [(source: CGImage?, size: Int, pixels: CoverPixels)] = []

    static func make(_ source: CGImage?, size: Int) -> CoverPixels {
        if let known = cache.first(where: { $0.source === source && $0.size == size }) { return known.pixels }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        var image: CGImage?
        rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(Palette.coverEmpty)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            if let source {
                ctx.interpolationQuality = .high
                ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
            } else {
                ctx.setFillColor(Palette.coverNote)
                let unit = NowPlayingArt.detail
                let origin = (size / unit - 9) / 2
                for (dy, row) in Glyphs.note.enumerated() {
                    for (dx, mark) in row.enumerated() where mark == "X" {
                        ctx.fill(CGRect(x: (origin + dx) * unit, y: size - (origin + dy + 1) * unit, width: unit, height: unit))
                    }
                }
            }
            image = ctx.makeImage()
        }
        let pixels = CoverPixels(size: size, rgba: rgba, image: image!)
        cache.append((source, size, pixels))
        if cache.count > 6 { cache.removeFirst() }
        return pixels
    }
}

private enum Palette {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let background = rgb(10, 24, 28, 0.84)
    static let rim = rgb(150, 205, 196, 0.55)
    static let shadow = rgb(0, 0, 0, 0.35)
    static let coverFrame = rgb(0, 0, 0, 0.6)
    static let coverEmpty = rgb(30, 64, 66)
    static let coverNote = rgb(120, 172, 165)
    static let title = rgb(242, 248, 246)
    static let artist = rgb(150, 188, 182)
    static let icon = rgb(226, 236, 233)
    static let disabled = rgb(96, 120, 118)
    static let accent = rgb(246, 146, 66)
    static let pressed = rgb(196, 104, 44)
    static let track = rgb(255, 255, 255, 0.18)
    /// What a cover fades towards as it sinks into the pond.
    static let water: (r: Double, g: Double, b: Double) = (26, 72, 76)
}

private enum Fonts {
    static let title = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil)!
    static let artist = NSFont.systemFont(ofSize: 11, weight: .semibold) as CTFont
}

private enum Glyphs {
    static let play = [
        ".X....",
        ".XX...",
        ".XXX..",
        ".XXXX.",
        ".XXX..",
        ".XX...",
        ".X....",
    ]
    static let pause = Array(repeating: ".XX..XX", count: 7)
    static let next = [
        "X..X..X",
        "XX.XX.X",
        "XXXXXXX",
        "XX.XX.X",
        "X..X..X",
    ]
    static let previous = next.map { String($0.reversed()) }
    static let note = [
        "...XXXXXX",
        "...XXXXXX",
        "...X....X",
        "...X....X",
        "...X....X",
        ".XXX..XXX",
        "XXXX.XXXX",
        "XXXX.XXXX",
        ".XX...XX.",
    ]
    /// A 3×5 font for the time and captions.
    static let tiny: [Character: [String]] = [
        "0": ["XXX", "X.X", "X.X", "X.X", "XXX"],
        "1": [".X.", "XX.", ".X.", ".X.", "XXX"],
        "2": ["XXX", "..X", "XXX", "X..", "XXX"],
        "3": ["XXX", "..X", ".XX", "..X", "XXX"],
        "4": ["X.X", "X.X", "XXX", "..X", "..X"],
        "5": ["XXX", "X..", "XXX", "..X", "XXX"],
        "6": ["XXX", "X..", "XXX", "X.X", "XXX"],
        "7": ["XXX", "..X", "..X", ".X.", ".X."],
        "8": ["XXX", "X.X", "XXX", "X.X", "XXX"],
        "9": ["XXX", "X.X", "XXX", "..X", "XXX"],
        ":": [".", "X", ".", "X", "."],
        " ": ["..", "..", "..", "..", ".."],
        "A": [".X.", "X.X", "XXX", "X.X", "X.X"],
        "G": [".XX", "X..", "X.X", "X.X", ".XX"],
        "I": ["XXX", ".X.", ".X.", ".X.", "XXX"],
        "L": ["X..", "X..", "X..", "X..", "XXX"],
        "N": ["X.X", "XXX", "XXX", "XXX", "X.X"],
        "O": [".X.", "X.X", "X.X", "X.X", ".X."],
        "P": ["XX.", "X.X", "XX.", "X..", "X.."],
        "W": ["X.X", "X.X", "XXX", "XXX", "X.X"],
        "Y": ["X.X", "X.X", ".X.", ".X.", ".X."],
    ]

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A bitmap drawn in art pixels from the top left, `NowPlayingArt.detail` image pixels to each, with
/// antialiasing off so every edge lands on whole pixels.
private struct Canvas {
    let ctx: CGContext
    let height: CGFloat

    init?(size: CGSize) {
        let detail = NowPlayingArt.detail
        guard let ctx = CGContext(data: nil, width: Int(size.width) * detail, height: Int(size.height) * detail,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: CGFloat(detail), y: CGFloat(detail))
        ctx.setShouldAntialias(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(false)
        self.ctx = ctx
        height = size.height
    }

    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    func fill(_ rect: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(flipped(rect))
    }

    func dots(_ points: [CGPoint], _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(points.map { flipped(CGRect(x: $0.x, y: $0.y, width: 1, height: 1)) })
    }

    func clipped(_ rect: CGRect, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.clip(to: flipped(rect))
        draw()
        ctx.restoreGState()
    }

    /// Fills (or with no color, clears) a rectangle with its corners cut off in steps.
    func chamfered(_ rect: CGRect, corner: Int, _ color: CGColor?) {
        for step in 0...corner {
            let part = flipped(rect.insetBy(dx: CGFloat(corner - step), dy: CGFloat(step)))
            if let color {
                ctx.setFillColor(color)
                ctx.fill(part)
            } else {
                ctx.clear(part)
            }
        }
    }

    func bitmap(_ rows: [String], at origin: CGPoint, _ color: CGColor) {
        ctx.setFillColor(color)
        for (dy, row) in rows.enumerated() {
            for (dx, mark) in row.enumerated() where mark == "X" {
                ctx.fill(flipped(CGRect(x: origin.x + CGFloat(dx), y: origin.y + CGFloat(dy), width: 1, height: 1)))
            }
        }
    }

    /// Text pixels from the pen at `x` on `baseline`; `keep` decides each pixel, given its place in the text in
    /// art pixels (so effects line up the same on fine text).
    func text(_ text: PixelText, x: CGFloat, baseline: CGFloat, color: CGColor, keep: ((Int, Int) -> Bool)? = nil) {
        let unit = 1 / CGFloat(text.fine)
        var rects: [[CGRect]] = Array(repeating: [], count: 5)
        for p in text.points {
            if let keep {
                let ax = p.x >= 0 ? p.x / text.fine : (p.x - text.fine + 1) / text.fine
                let ay = p.y >= 0 ? p.y / text.fine : (p.y - text.fine + 1) / text.fine
                guard keep(ax, ay + 20) else { continue }
            }
            rects[p.a].append(flipped(CGRect(x: x + CGFloat(p.x) * unit, y: baseline + CGFloat(p.y) * unit, width: unit, height: unit)))
        }
        for quarters in 1...4 where !rects[quarters].isEmpty {
            ctx.setFillColor(quarters == 4 ? color : color.copy(alpha: color.alpha * CGFloat(quarters) / 4) ?? color)
            ctx.fill(rects[quarters])
        }
    }

    /// A cover in its slot, optionally moved, as mosaic blocks, waved row by row, tinted towards the water,
    /// or with only the blocks `keep` allows (given the block's corner and size). Moves and block sizes are
    /// in art pixels; with no effect the cover shows at its full, finer detail.
    func cover(_ pixels: CoverPixels, in rect: CGRect, dx: Int = 0, dy: Int = 0, block: Int = 1, wave: Double = 0,
               waveT: Double = 0, tint: Double = 0, keep: ((Int, Int, Int) -> Bool)? = nil) {
        clipped(rect) {
            if block == 1, wave == 0, tint == 0, keep == nil {
                ctx.interpolationQuality = .none
                ctx.draw(pixels.image, in: flipped(rect.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))))
                return
            }
            let size = pixels.size
            let detail = max(1, size / max(Int(rect.width), 1))
            let step = block * detail
            let unit = 1 / CGFloat(detail)
            for py in stride(from: 0, to: size, by: step) {
                let row = py / detail
                let shift = wave == 0 ? 0 : Int((sin(Double(row) * 0.42 + waveT) * wave).rounded())
                for px in stride(from: 0, to: size, by: step) where keep?(px / detail, row, block) ?? true {
                    let i = (py * size + px) * 4
                    let r = Double(pixels.rgba[i]), g = Double(pixels.rgba[i + 1]), b = Double(pixels.rgba[i + 2])
                    ctx.setFillColor(red: (r + (Palette.water.r - r) * tint) / 255, green: (g + (Palette.water.g - g) * tint) / 255,
                                     blue: (b + (Palette.water.b - b) * tint) / 255, alpha: 1)
                    ctx.fill(flipped(CGRect(x: rect.minX + CGFloat(dx + shift) + CGFloat(px) * unit,
                                            y: rect.minY + CGFloat(dy) + CGFloat(py) * unit,
                                            width: CGFloat(step) * unit, height: CGFloat(step) * unit)))
                }
            }
        }
    }

    /// 3×5 pixel text ending at `right`, or starting at `left`.
    func tiny(_ text: String, right: CGFloat? = nil, left: CGFloat? = nil, top: CGFloat, _ color: CGColor) {
        let glyphs = text.compactMap { Glyphs.tiny[$0] }
        let width = glyphs.reduce(0) { $0 + CGFloat($1[0].count) + 1 } - 1
        var x = left ?? ((right ?? 0) - width)
        for glyph in glyphs {
            bitmap(glyph, at: CGPoint(x: x, y: top), color)
            x += CGFloat(glyph[0].count) + 1
        }
    }
}

/// `KoiPond --now-playing-preview out.png [--title …] [--artist …] [--cover image] [--paused] [--scale 4]
///  [--card] [--style mosaic|koi|flap|dither --at 700]` draws the desktop player (or the song card) to a PNG,
/// scaled up the way the screen shows it, optionally partway through a song change.
enum NowPlayingPreview {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--now-playing-preview"), index + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let info = NowPlayingInfo(title: value("--title") ?? "Koi in the Moonlight", artist: value("--artist") ?? "Pond Sessions",
                                  isPlaying: !args.contains("--paused"), duration: 225, position: 83,
                                  positionDate: Date(), trackKey: "preview")
        let cover = value("--cover").flatMap { FileManager.default.contents(atPath: $0) }.flatMap(MusicPlayer.decodeCover)
        let hovered: NowPlayingButton? = args.contains("--hover") ? .playPause : nil
        let style = value("--style").flatMap { name in SongTransition.allCases.first { "\($0)" == name } }
        let change = style.map {
            SongChange(from: SongFace(title: "Moonlit Pond", artist: "Lumen Drift", cover: nil), style: $0,
                       start: CACurrentMediaTime() - (value("--at").flatMap(Double.init) ?? 700) / 1000)
        }
        let art = args.contains("--card")
            ? NowPlayingArt.card(song: SongFace(title: info.title, artist: info.artist, cover: cover), change: change)
            : NowPlayingArt.image(info: info, cover: cover, hovered: hovered, pressed: nil, controllable: true, change: change)
        guard let art, let scaled = scale(art, by: value("--scale").flatMap(Int.init) ?? 4),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[index + 1]) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Nearest-neighbour upscale over a dark pond-ish backdrop, as the panel sits on the water.
    private static func scale(_ image: CGImage, by factor: Int) -> CGImage? {
        let art = (width: image.width / NowPlayingArt.detail, height: image.height / NowPlayingArt.detail)
        let width = (art.width + 8) * factor, height = (art.height + 8) * factor
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.43, blue: 0.41, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 4 * factor, y: 4 * factor, width: art.width * factor, height: art.height * factor))
        return ctx.makeImage()
    }
}
