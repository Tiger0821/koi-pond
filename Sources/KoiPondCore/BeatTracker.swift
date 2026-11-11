import Foundation

/// The song's beat as a steady grid: one beat at `anchor`, then one every `period` seconds either way.
/// Times are on whatever clock the beats were measured on; the lyrics' clock when it reaches the view.
public struct BeatGrid: Equatable, Sendable {
    public var anchor: TimeInterval
    public var period: TimeInterval
    /// 0 when there's no beat to speak of, 1 when the onsets land right on the grid.
    public var confidence: Double

    public init(anchor: TimeInterval, period: TimeInterval, confidence: Double) {
        self.anchor = anchor
        self.period = max(period, 0.05)
        self.confidence = min(max(confidence, 0), 1)
    }

    /// Which beat `time` falls in: 0 is the anchor's, counting up after it and down before it.
    public func index(at time: TimeInterval) -> Int {
        Int(((time - anchor) / period).rounded(.down))
    }

    /// Seconds since the last beat at or before `time`.
    public func sinceBeat(at time: TimeInterval) -> TimeInterval {
        let offset = (time - anchor).truncatingRemainder(dividingBy: period)
        return offset < 0 ? offset + period : offset
    }

    /// Seconds until the next beat after `time`.
    public func untilBeat(at time: TimeInterval) -> TimeInterval {
        period - sinceBeat(at: time)
    }

    /// The same grid on another clock, `shift` seconds later.
    public func shifted(by shift: TimeInterval) -> BeatGrid {
        BeatGrid(anchor: anchor + shift, period: period, confidence: confidence)
    }

    public var beatsPerMinute: Double { 60 / period }
}

/// Turns beats heard by `BeatDetector` into a grid that keeps going between them, so motion can wind up
/// before a beat lands instead of only reacting after it. Onsets vote for a tempo (their gaps, folded into
/// one octave), then for where in that tempo's cycle the beats fall.
public struct BeatTracker: Sendable {
    /// Tempos outside this range are folded into it: 80 to 180 BPM.
    public static let periods: ClosedRange<TimeInterval> = (60.0 / 180)...(60.0 / 80)
    /// Onsets older than this stop voting.
    private static let memory: TimeInterval = 8
    /// The grid fades out this long after the last onset, so a quiet bridge goes still.
    private static let fade: TimeInterval = 2.5

    private var onsets: [(time: TimeInterval, strength: Double)] = []
    private var current: BeatGrid?

    public init() {}

    public mutating func add(onset time: TimeInterval, strength: Double = 1.5) {
        onsets.append((time, max(strength, 0.1)))
        onsets.removeAll { $0.time < time - Self.memory }
        update(now: time)
    }

    public mutating func reset() {
        onsets.removeAll()
        current = nil
    }

    /// The grid as it stands at `time`, faded by how long ago the last onset was. Nil until there's a beat.
    public func grid(at time: TimeInterval) -> BeatGrid? {
        guard var grid = current, let last = onsets.last?.time else { return nil }
        let quiet = time - last - grid.period * 1.5
        if quiet > 0 { grid.confidence *= max(0, 1 - quiet / Self.fade) }
        return grid.confidence > 0.02 ? grid : nil
    }

    private mutating func update(now: TimeInterval) {
        guard onsets.count >= 5, let estimate = Self.tempo(of: onsets) else { return }
        let (phase, steadiness) = Self.phase(of: onsets, period: estimate, now: now)
        // Enough onsets on the grid, and enough of them, before it's trusted fully.
        let confidence = steadiness * min(1, Double(onsets.count) / 10)

        var anchor = now - ((now - phase).truncatingRemainder(dividingBy: estimate) + estimate)
            .truncatingRemainder(dividingBy: estimate)
        var period = estimate
        if let previous = current, abs(previous.period - period) / previous.period < 0.04 {
            // Same tempo: ease toward the new estimate instead of jumping, so the motion never stutters.
            period = previous.period + (period - previous.period) * 0.3
            let drift = Self.wrapped((anchor - previous.anchor) / previous.period) * previous.period
            anchor = previous.anchor + drift * 0.35
        }
        current = BeatGrid(anchor: anchor, period: period, confidence: confidence)
    }

    /// The period most onset gaps agree on, folded into `periods`.
    static func tempo(of onsets: [(time: TimeInterval, strength: Double)]) -> TimeInterval? {
        let low = periods.lowerBound, high = periods.upperBound
        let step = 0.002
        let bins = Int((high - low) / step) + 1
        var votes = [Double](repeating: 0, count: bins)
        for i in onsets.indices {
            for j in (i + 1)..<onsets.count {
                var gap = onsets[j].time - onsets[i].time
                guard gap >= 0.2, gap <= 3 else { continue }
                while gap > high { gap /= 2 }
                while gap < low { gap *= 2 }
                // Nearer pairs say more about the tempo than ones several beats apart.
                let weight = sqrt(onsets[i].strength * onsets[j].strength) / Double(j - i)
                let center = (gap - low) / step
                for bin in max(0, Int(center) - 6)...min(bins - 1, Int(center) + 6) {
                    let distance = (Double(bin) - center) * step / 0.006
                    votes[bin] += weight * exp(-distance * distance / 2)
                }
            }
        }
        guard let best = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[best] > 0 else { return nil }
        return low + Double(best) * step
    }

    /// Where in the cycle onsets fall (a time on the grid), and how tightly: 1 when they all agree.
    static func phase(of onsets: [(time: TimeInterval, strength: Double)], period: TimeInterval,
                      now: TimeInterval) -> (TimeInterval, Double) {
        var x = 0.0, y = 0.0, total = 0.0
        for onset in onsets {
            // Recent onsets count most, so the grid follows a song that drifts.
            let weight = onset.strength * exp(-(now - onset.time) / 4)
            let angle = 2 * .pi * onset.time / period
            x += cos(angle) * weight
            y += sin(angle) * weight
            total += weight
        }
        guard total > 0 else { return (now, 0) }
        let angle = atan2(y, x)
        return (angle / (2 * .pi) * period, (x * x + y * y).squareRoot() / total)
    }

    /// A fraction of a beat, wrapped into -0.5...0.5.
    static func wrapped(_ beats: Double) -> Double {
        beats - beats.rounded()
    }
}
