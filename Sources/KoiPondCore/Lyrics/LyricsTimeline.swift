import Foundation

/// Which lines the lyrics show at a moment, for the pond's middle: the line being sung, the one it took
/// over from on its way out, the next one waiting below, and how much of it all shows.
public struct LyricsScene: Equatable, Sendable {
    /// Indices into `Lyrics.lines`; blank lines never show.
    public var current: Int?
    public var previous: Int?
    public var next: Int?
    /// 0 → 1 as the current line moves into place, over `LyricsTimeline.lead` before it starts.
    public var arrival: Double
    /// 0 → 1: how much the lyrics, and the dimming behind them, show. Long instrumental breaks fade to 0.
    public var presence: Double

    public init(current: Int? = nil, previous: Int? = nil, next: Int? = nil, arrival: Double = 1, presence: Double = 0) {
        self.current = current
        self.previous = previous
        self.next = next
        self.arrival = arrival
        self.presence = presence
    }
}

public enum LyricsTimeline {
    /// A line moves into the middle this long before its first word, so it's in place when the word lands.
    public static let lead: TimeInterval = 0.35
    /// How long lyrics and the dimming take to come and go.
    public static let fade: TimeInterval = 0.6
    /// A gap with no singing longer than this lets the pond come back.
    public static let longGap: TimeInterval = 4
    /// How long a sung line stays before a long gap clears it.
    public static let linger: TimeInterval = 1.5

    public static func scene(_ lyrics: Lyrics, at time: TimeInterval) -> LyricsScene {
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].isBlank }
        guard let first = sung.first else { return LyricsScene() }
        // The last line that has started moving in.
        guard let position = sung.lastIndex(where: { lyrics.lines[$0].start - lead <= time }) else {
            let start = lyrics.lines[first].start - lead
            return LyricsScene(current: nil, previous: nil, next: first, arrival: 0,
                               presence: ramp(time, from: start - fade, to: start))
        }
        let index = sung[position]
        let line = lyrics.lines[index]
        let next = position + 1 < sung.count ? sung[position + 1] : nil
        let previous = position > 0 ? sung[position - 1] : nil
        var scene = LyricsScene(current: index, previous: previous, next: next,
                                arrival: ramp(time, from: line.start - lead, to: line.start), presence: 1)

        let nextStart = next.map { lyrics.lines[$0].start - lead } ?? .infinity
        let quiet = line.end + linger
        if nextStart - line.end > longGap, time > quiet {
            // A long break: the line fades out after it's sung, and the next one fades in, waiting below,
            // before it moves up into place.
            let leaving = 1 - ramp(time, from: quiet, to: quiet + fade)
            let coming = nextStart.isFinite ? ramp(time, from: nextStart - fade, to: nextStart) : 0
            scene.presence = max(leaving, coming)
            if leaving <= 0 { scene.current = nil }
            if coming <= 0 { scene.next = nil }
        }
        // The line before only shows while this one is taking its place.
        if scene.arrival >= 1 { scene.previous = nil }
        return scene
    }

    private static func ramp(_ time: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> Double {
        guard end > start else { return time >= end ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
    }
}
