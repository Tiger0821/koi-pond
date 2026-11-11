import Foundation

public struct TrackQuery: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; 0 when unknown (e.g. radio streams).
    public var duration: TimeInterval

    public init(title: String, artist: String, album: String, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Where synced lyrics are fetched from (the same sources as NotchLyrics, minus its local files).
public enum LyricsSourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// NetEase Cloud Music: real per-word timing for most Chinese songs and many others.
    case netease
    /// LRCLIB: an open database of line-synced lyrics.
    case lrclib

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .netease: "NetEase Cloud Music"
        case .lrclib: "LRCLIB"
        }
    }

    /// What this source stamps on the lyrics it returns, which is how a `Lyrics` says where it came from.
    public var sourceName: String {
        switch self {
        case .netease: "NetEase"
        case .lrclib: "LRCLIB"
        }
    }
}

public enum LyricsFormat: String, Codable, Sendable {
    case lrc
    case yrc
}

/// Unparsed lyrics as fetched, which is what gets cached.
public struct RawLyrics: Codable, Equatable, Sendable {
    public var format: LyricsFormat
    public var text: String
    public var source: String

    public func parse() -> Lyrics? {
        switch format {
        case .lrc: LRCParser.parse(text, source: source)
        case .yrc: YRCParser.parse(text, source: source)
        }
    }
}

enum HTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    static func json(_ url: URL, headers: [String: String]) async -> Any? {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }
}

/// https://lrclib.net — open database of line-synced lyrics.
/// Whether fetched lyrics will do for the song: timing someone could sing to, in the song's language.
private func usable(_ raw: RawLyrics, for query: TrackQuery) -> (ok: Bool, why: String?) {
    guard let lyrics = raw.parse() else { return (false, "unreadable") }
    if !TimingCheck.isPlausible(lyrics) { return (false, "impossible timing") }
    if !TimingCheck.fitsLanguage(lyrics, of: query) { return (false, "Japanese lyrics") }
    return (true, nil)
}

struct LRCLibProvider {
    private static let headers = ["User-Agent": "KoiPond/1.0 (macOS desktop wallpaper; https://github.com/Tiger0821/koi-pond)"]

    /// The lyrics LRCLIB has for this exact release: same title, artist, album and length (to the second).
    func fetchExact(_ query: TrackQuery) async -> (raw: RawLyrics?, note: String) {
        guard !query.album.isEmpty, query.duration > 0 else { return (nil, "LRCLIB release: no album or length to ask for") }
        guard let exact = await HTTP.json(HTTP.url("https://lrclib.net/api/get", [
            ("track_name", query.title),
            ("artist_name", query.artist),
            ("album_name", query.album),
            ("duration", String(Int(query.duration.rounded()))),
        ]), headers: Self.headers) as? [String: Any],
            let synced = exact["syncedLyrics"] as? String, !synced.isEmpty else { return (nil, "LRCLIB release: not listed") }
        let raw = RawLyrics(format: .lrc, text: synced, source: LyricsSourceKind.lrclib.sourceName)
        let check = usable(raw, for: query)
        return check.ok ? (raw, "LRCLIB release: found") : (nil, "LRCLIB release: \(check.why ?? "")")
    }

    /// The closest in length of LRCLIB's search results, within `within` seconds, that will do. Asked in
    /// Traditional and Simplified both when the names have Chinese characters, since LRCLIB files them as uploaded.
    func search(_ query: TrackQuery, within: Double = 3) async -> (raw: RawLyrics?, note: String) {
        var looked = 0, rejected: [String] = []
        let titles = TextNormalize.scriptVariants(TextNormalize.cleanTitle(query.title))
        let artists = TextNormalize.scriptVariants(TextNormalize.primaryArtist(query.artist))
        for (title, artist) in zip(titles, artists + Array(repeating: artists[0], count: max(0, titles.count - artists.count))) {
            guard let results = await HTTP.json(HTTP.url("https://lrclib.net/api/search", [
                ("track_name", title), ("artist_name", artist),
            ]), headers: Self.headers) as? [[String: Any]] else { continue }
            looked += results.count
            let best = results.compactMap { result -> (diff: Double, raw: RawLyrics)? in
                let name = result["trackName"] as? String ?? ""
                guard let synced = result["syncedLyrics"] as? String, !synced.isEmpty,
                      TextNormalize.looselyMatches(name, query.title), !TextNormalize.isOtherVersion(name, of: query.title)
                else { return nil }
                let duration = result["duration"] as? Double ?? 0
                let diff = query.duration > 0 && duration > 0 ? abs(duration - query.duration) : 0
                guard diff <= within else { return nil }
                let raw = RawLyrics(format: .lrc, text: synced, source: LyricsSourceKind.lrclib.sourceName)
                let check = usable(raw, for: query)
                if let why = check.why { rejected.append(why) }
                return check.ok ? (diff, raw) : nil
            }.min { $0.diff < $1.diff }
            if let best { return (best.raw, "LRCLIB search: found") }
        }
        let skipped = rejected.isEmpty ? "" : " (skipped: \(Set(rejected).sorted().joined(separator: ", ")))"
        return (nil, "LRCLIB search: nothing within \(Int(within)) s of the length among \(looked) results\(skipped)")
    }
}

/// NetEase Cloud Music (unofficial API). Its YRC lyrics have real per-word timing, mostly for Chinese songs.
struct NetEaseProvider {
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        "Referer": "https://music.163.com",
    ]

    /// The best match's word-timed lyrics, or failing that line-timed ones. Lyrics that won't do (timing
    /// nobody could sing, as when the words were just spread over a few seconds, or the wrong language) are
    /// passed over for the next match.
    func fetch(_ query: TrackQuery) async -> (raw: RawLyrics?, note: String) {
        var (ids, found) = await candidates(for: query)
        var searchedAs = ""
        if ids.isEmpty, let title = TextNormalize.romajiAsKana(query.title) {
            // A Japanese song Music names in romaji ("Wakatteruyo." by "Sanhi") may be filed in kana
            // (わかってるよ。 by さんひ): the same search again, in hiragana.
            let artist = TextNormalize.romajiAsKana(query.artist) ?? query.artist
            (ids, found) = await candidates(for: TrackQuery(title: title, artist: artist, album: query.album, duration: query.duration))
            searchedAs = " (searched as \(title) \(artist))"
        }
        guard !ids.isEmpty else {
            return (nil, "NetEase: no song with this title, artist and length among \(found) results\(searchedAs)")
        }
        var lineFallback: RawLyrics?
        var rejected: [String] = []
        for id in ids.prefix(5) {
            guard let json = await HTTP.json(
                URL(string: "https://music.163.com/api/song/lyric/v1?id=\(id)&lv=0&kv=0&tv=0&rv=0&yv=0&ytv=0&yrv=0")!,
                headers: Self.headers) as? [String: Any] else { continue }
            if let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String, YRCParser.parse(yrc, source: "") != nil {
                let raw = RawLyrics(format: .yrc, text: yrc, source: LyricsSourceKind.netease.sourceName)
                let check = usable(raw, for: query)
                if check.ok { return (raw, "NetEase: word timing from song \(id)\(searchedAs)") }
                rejected.append("\(id) \(check.why ?? "")")
            }
            if lineFallback == nil, let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String,
               LRCParser.parse(lrc, source: "") != nil {
                let raw = RawLyrics(format: .lrc, text: lrc, source: LyricsSourceKind.netease.sourceName)
                let check = usable(raw, for: query)
                if check.ok { lineFallback = raw } else { rejected.append("\(id) \(check.why ?? "")") }
            }
        }
        let skipped = rejected.isEmpty ? "" : " (skipped \(rejected.joined(separator: ", ")))"
        return (lineFallback, (lineFallback == nil ? "NetEase: no usable lyrics" : "NetEase: line timing only") + searchedAs + skipped)
    }

    /// Song ids whose title and length match, best first: the same artist (by any of NetEase's names for them,
    /// so Teresa Teng finds 邓丽君), then the same album (another release of a song can have a longer or shorter
    /// intro), then the nearest length; and how many songs the search found.
    private func candidates(for query: TrackQuery) async -> (ids: [Int], found: Int) {
        let term = "\(TextNormalize.cleanTitle(query.title)) \(TextNormalize.primaryArtist(query.artist))"
        let url = HTTP.url("https://music.163.com/api/cloudsearch/pc", [
            ("s", TextNormalize.toSimplified(term)), ("type", "1"), ("limit", "15"),
        ])
        guard let json = await HTTP.json(url, headers: Self.headers) as? [String: Any],
              let songs = (json["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return ([], 0) }

        let scored = songs.compactMap { song -> (score: Double, id: Int)? in
            guard let id = song["id"] as? Int, let name = song["name"] as? String else { return nil }
            // The song's own name, or one of its aliases or translated names.
            let names = [name] + (song["alia"] as? [String] ?? []) + (song["tns"] as? [String] ?? [])
            let titleMatches = names.contains { TextNormalize.looselyMatches($0, query.title) }
            // Music may give a Chinese song its English title ("The Moon Represents My Heart"), which NetEase
            // finds but doesn't list. Taken only for the same artist at the same length, below real matches.
            let translated = !titleMatches && !query.title.contains(where: \.isCJK) && name.contains(where: \.isCJK)
            guard titleMatches || translated, !TextNormalize.isOtherVersion(name, of: query.title) else { return nil }
            var durationDiff = 0.0
            if query.duration > 0, let ms = song["dt"] as? Double {
                durationDiff = abs(ms / 1000 - query.duration)
            }
            guard durationDiff <= (translated ? 1 : 3) else { return nil }
            let artistNames = (song["ar"] as? [[String: Any]] ?? []).flatMap { artist -> [String] in
                [artist["name"] as? String ?? ""] + (artist["alia"] as? [String] ?? []) + (artist["alias"] as? [String] ?? [])
                    + (artist["tns"] as? [String] ?? [])
            }
            let artistMatches = TextNormalize.artistMatches(query.artist, names: artistNames)
            // A name NetEase doesn't know for the artist: accept only a near-exact length then.
            guard artistMatches || durationDiff <= 1, artistMatches || !translated else { return nil }
            let album = (song["al"] as? [String: Any])?["name"] as? String ?? ""
            let albumMatches = !query.album.isEmpty && TextNormalize.looselyMatches(album, query.album)
            return ((artistMatches ? 0 : 5) + (albumMatches ? 0 : 2) + (translated ? 10 : 0) + durationDiff, id)
        }
        return (scored.sorted { $0.score < $1.score }.map(\.id), songs.count)
    }
}
