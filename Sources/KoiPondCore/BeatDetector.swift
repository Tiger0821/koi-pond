import Foundation

/// The music playing, for the fish to move to; fed into the pond from outside each frame.
public struct PondMusic: Equatable, Sendable {
    /// 0 when silent, about 1 at the song's loudest lately.
    public var level: Float
    /// Counts beats since listening started; each change is a new beat.
    public var beats: Int

    public init(level: Float = 0, beats: Int = 0) {
        self.level = level
        self.beats = beats
    }
}

/// Finds the beat in a stream of mono samples: the bass's energy jumping well above its average over the
/// last second. Also follows loudness against the song's own recent peak, so quiet songs dance too.
public struct BeatDetector: Sendable {
    public private(set) var music = PondMusic()

    private let sampleRate: Float
    private let blockSize: Int
    /// One-pole low-pass coefficient for a ~150 Hz bass band (applied twice for a steeper slope).
    private let alpha: Float
    private var low1: Float = 0
    private var low2: Float = 0
    private var bassSum: Float = 0
    private var fullSum: Float = 0
    private var count = 0
    /// Bass energy of the last second of ~23 ms blocks.
    private var history: [Float]
    private var next = 0
    private var filled = 0
    private var sinceBeat: Float = 1
    private var loudest: Float = 0.02

    public init(sampleRate: Float) {
        self.sampleRate = max(sampleRate, 8000)
        blockSize = max(64, Int(self.sampleRate / 43))
        alpha = 1 - exp(-2 * .pi * 150 / self.sampleRate)
        history = Array(repeating: 0, count: 43)
    }

    public mutating func add(_ sample: Float) {
        low1 += alpha * (sample - low1)
        low2 += alpha * (low1 - low2)
        bassSum += low2 * low2
        fullSum += sample * sample
        count += 1
        if count >= blockSize { endBlock() }
    }

    private mutating func endBlock() {
        let bass = bassSum / Float(count)
        let rms = (fullSum / Float(count)).squareRoot()
        let seconds = Float(count) / sampleRate
        bassSum = 0
        fullSum = 0
        count = 0

        loudest = max(rms, loudest * (1 - seconds / 8), 0.02)
        let target: Float = rms < 0.002 ? 0 : min(1, rms / loudest)
        music.level += (target - music.level) * (target > music.level ? 0.6 : 0.08)

        let average = history.prefix(filled).reduce(0, +) / Float(max(filled, 1))
        sinceBeat += seconds
        if filled >= 8, bass > average * 1.45, bass > 1e-6, sinceBeat > 0.28 {
            music.beats &+= 1
            sinceBeat = 0
        }
        history[next] = bass
        next = (next + 1) % history.count
        filled = min(filled + 1, history.count)
    }
}
