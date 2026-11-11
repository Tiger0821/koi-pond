import Foundation

extension RockStyle {
    /// How wild the style is, 0 to 1, in `calmToWild` order: the mix reaches for the styles whose wildness is
    /// near how intense the song is.
    public var wildness: Double {
        switch self {
        case .posterStomp: 0
        case .rockingBoat: 0.2
        case .headbang: 0.45
        case .glitch: 0.6
        case .stageDive: 0.8
        case .moshPit: 1
        }
    }
}

/// Mixes the styles through one song, so it doesn't settle into one look after the first minute. How wild they
/// get follows the song: a ballad keeps to the calm ones (Poster Stomp, Rocking Boat), a hard-hitting song to
/// the wild ones (Stage Dive, Mosh Pit), and a song in between mixes the middle. A new style only takes over as
/// a line starts, and only where the song turns a corner: after a break in the singing, where a repeated chorus
/// begins, or every few lines at the most. Never twice in a row.
public struct RockMix: Sendable {
    /// The style of the line being sung.
    public private(set) var current: RockStyle
    /// The style the line before was drawn in, for it to leave in.
    public private(set) var previous: RockStyle
    public let boundaries: Set<Int>
    private let fixed: RockStyle?
    private var line: Int?

    /// A style holds for at least this many lines, and at most `longest`.
    public static let shortest = 2
    public static let longest = 4
    /// A pause in the singing this long starts a new section.
    public static let sectionGap: TimeInterval = 2

    /// `fixed` keeps one style for the whole song; nil mixes them. `roll` is a random number in 0..<1, and
    /// `energy` how intense the song is now, 0 (a hush) to 1 (all out).
    public init(lyrics: Lyrics?, fixed: RockStyle?, energy: Double, roll: Double) {
        self.fixed = fixed
        boundaries = fixed == nil ? lyrics.map(Self.boundaries) ?? [] : []
        current = fixed ?? Self.pick(after: nil, energy: energy, roll: roll)
        previous = current
    }

    /// Follows the line being sung; returns true when a new style takes over with it.
    @discardableResult
    public mutating func update(line next: Int?, energy: Double, roll: Double) -> Bool {
        guard next != line else { return false }
        defer { line = next }
        guard let next else { return false }
        previous = current
        guard fixed == nil else { return false }
        // A jump (a seek, or a song starting over) may change style too: nothing carries over from the line before.
        let jumped = line.map { next < $0 || next > $0 + 6 } ?? false
        guard boundaries.contains(next) || jumped else { return false }
        current = Self.pick(after: current, energy: energy, roll: roll)
        return true
    }

    /// Lines (indices into `lyrics.lines`) where a new style may come in.
    public static func boundaries(in lyrics: Lyrics) -> Set<Int> {
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].isBlank }
        let keys = sung.map { TextNormalize.key(lyrics.lines[$0].text) }
        var result: Set<Int> = []
        var since = 0
        for k in sung.indices.dropFirst() {
            since += 1
            let line = lyrics.lines[sung[k]], before = lyrics.lines[sung[k - 1]]
            let section = line.start - before.end >= sectionGap
            // A chorus coming back: this line was sung before, and the line before it wasn't the one that
            // led into it then, so the repeat starts here.
            var chorus = false
            if !keys[k].isEmpty, let earlier = keys[..<k].firstIndex(of: keys[k]), earlier < k - 1 {
                chorus = earlier == 0 || keys[earlier - 1] != keys[k - 1]
            }
            if since >= shortest && (section || chorus) || since >= longest {
                result.insert(sung[k])
                since = 0
            }
        }
        return result
    }

    /// A style other than `current`, weighted toward those whose wildness is near `energy`, so a calm song
    /// almost never gets a wild one and the other way round.
    public static func pick(after current: RockStyle?, energy: Double, roll: Double) -> RockStyle {
        let choices = RockStyle.calmToWild.filter { $0 != current }
        let weights = choices.map { style -> Double in
            let distance = (style.wildness - min(max(energy, 0), 1)) / 0.16
            return exp(-distance * distance / 2) + 0.002
        }
        var target = min(max(roll, 0), 0.999_999) * weights.reduce(0, +)
        for (style, weight) in zip(choices, weights) {
            if target < weight { return style }
            target -= weight
        }
        return choices.last ?? current ?? .headbang
    }
}
