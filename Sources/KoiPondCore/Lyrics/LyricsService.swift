import CryptoKit
import Foundation

/// Finds synced lyrics for a song: NetEase first, for its word-by-word timing, lined up with LRCLIB's lyrics for
/// the release; then LRCLIB alone; then NetEase's line timing. Answers, including "none", are cached.
///
/// LRCLIB is the clock because it keeps to the audio: listening on this Mac (NotchLyrics' sync, by speech
/// recognition) found its lyrics within about 0.07 s of the singing, where NetEase's ran 0.25 s early as a
/// rule and up to 3 s off for some uploads.
public actor LyricsService {
    private let cacheDirectory: URL

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// How fetched lyrics were lined up with the release Music is playing.
    public enum Alignment: Equatable, Sendable {
        /// Used as fetched: nothing to line them up with, or they already agreed.
        case asFetched
        /// Moved this many seconds, every line the same.
        case shifted(TimeInterval)
        /// Each line moved onto the release's own line starts, the words inside it keeping their rhythm.
        case warped
        /// The release's own line-timed lyrics, because the word-timed ones were another arrangement.
        case replaced
    }

    /// The lyrics, and how they were lined up with the release. `traditional` turns Simplified Chinese lyrics
    /// into Traditional (Japanese lyrics are left alone).
    public func lookUp(_ query: TrackQuery, traditional: Bool) async -> (lyrics: Lyrics?, alignment: Alignment, notes: [String]) {
        let cacheURL = cacheFile(for: query)
        let entry: CacheEntry
        if let cached = loadCache(cacheURL) {
            entry = cached
        } else {
            entry = await find(query)
            saveCache(entry, to: cacheURL)
        }
        let notes = entry.notes ?? ["cached"]
        guard var lyrics = entry.raw?.parse() else { return (nil, .asFetched, notes) }
        var alignment = Alignment.asFetched
        if let shift = entry.shift, shift != 0 {
            lyrics = lyrics.shifted(by: shift)
            alignment = .shifted(shift)
        } else if let reference = entry.warpOnto?.parse(), let warped = TimingCheck.warp(lyrics, onto: reference) {
            lyrics = warped
            alignment = .warped
        } else if entry.replaced == true {
            alignment = .replaced
        }
        return (finish(lyrics, query: query, traditional: traditional), alignment, notes)
    }

    public func lyrics(for query: TrackQuery, traditional: Bool) async -> Lyrics? {
        await lookUp(query, traditional: traditional).lyrics
    }

    private func find(_ query: TrackQuery) async -> CacheEntry {
        // What each source said, kept with this lookup alone (another may run alongside it), for the log.
        var notes: [String] = []
        var entry = await choose(query, notes: &notes)
        entry.notes = notes
        return entry
    }

    private func choose(_ query: TrackQuery, notes: inout [String]) async -> CacheEntry {
        async let netease = NetEaseProvider().fetch(query)
        async let release = LRCLibProvider().fetchExact(query)
        let (neteaseResult, exactResult) = await (netease, release)
        notes = [neteaseResult.note, exactResult.note]
        let word = neteaseResult.raw
        let timed = word?.parse()
        var reference = exactResult.raw
        if reference == nil, timed?.timing == .word {
            // No lyrics for this exact release; LRCLIB's for the same song within a second of its length will do.
            let close = await LRCLibProvider().search(query, within: 1)
            notes.append(close.note + " (to line NetEase up with)")
            reference = close.raw
        }
        if let word, let timed, timed.timing == .word {
            // Another upload of the song can start its lines a second or so off this release (a longer intro,
            // another master). LRCLIB's lyrics for this exact release say where the lines really start.
            if let reference, let lines = reference.parse(),
               let match = TimingCheck.offset(of: timed, toMatch: lines), match.matched >= 4 {
                if match.agreement >= 0.6 {
                    // A fixed distance off: move everything by it.
                    return CacheEntry(raw: word, shift: abs(match.offset) >= 0.15 ? match.offset : 0)
                }
                // Drifting against the release: each line onto the release's own start.
                if TimingCheck.warp(timed, onto: lines) != nil { return CacheEntry(raw: word, warpOnto: reference) }
                // Another arrangement altogether: this release's own timing, line by line.
                return CacheEntry(raw: reference, replaced: true)
            }
            return CacheEntry(raw: word)
        }
        if let reference { return CacheEntry(raw: reference) }
        let searched = await LRCLibProvider().search(query)
        notes.append(searched.note)
        if let found = searched.raw { return CacheEntry(raw: found) }
        return CacheEntry(raw: word)
    }

    private func finish(_ lyrics: Lyrics, query: TrackQuery, traditional: Bool) -> Lyrics {
        let lyrics = TimingCheck.withoutTitleLines(lyrics, title: query.title, artist: query.artist)
        guard traditional, !lyrics.containsKana else { return lyrics }
        return lyrics.mapText(TextNormalize.toTraditional)
    }

    // MARK: - Cache

    private struct CacheEntry: Codable {
        var raw: RawLyrics?
        /// Seconds the lyrics are moved to line up with the release.
        var shift: TimeInterval?
        /// The release's own lyrics, whose line starts `raw` is moved onto.
        var warpOnto: RawLyrics?
        /// `raw` is the release's own lyrics, standing in for word-timed ones of another arrangement.
        var replaced: Bool?
        /// What each source said, for the log.
        var notes: [String]?
        var savedAt = Date()
    }

    private func cacheFile(for query: TrackQuery) -> URL {
        // v2: lookups since lyrics are checked for believable timing and lined up with the release.
        let identity = "v4|\(query.title)|\(query.artist)|\(query.album)|\(Int(query.duration.rounded()))"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(digest).json")
    }

    private func loadCache(_ url: URL) -> CacheEntry? {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        // "Not found" may just mean the Mac was offline, so ask again after 30 minutes.
        if entry.raw == nil, Date().timeIntervalSince(entry.savedAt) > 30 * 60 { return nil }
        return entry
    }

    private func saveCache(_ entry: CacheEntry, to url: URL) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
