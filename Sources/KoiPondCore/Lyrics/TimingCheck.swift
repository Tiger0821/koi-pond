import Foundation

/// Sanity checks on fetched lyrics' timing, and lining two sources up. Uploaded lyrics are sometimes timed by
/// nothing more than spreading the words evenly over a few seconds, or belong to another recording with a
/// longer or shorter intro; both make the words land off the singing.
public enum TimingCheck {
    /// Faster than this, in syllables a second (one per Chinese, Japanese or Korean character, about one per
    /// three Latin letters), nobody sings: real lyrics run at 1 to 4, and fast rap at about 7.
    static let fastestSinging = 9.0

    /// False for lyrics whose lines go by faster than anyone sings: a quarter of the lines or more over
    /// `fastestSinging`, or half of them faster than fast rap.
    public static func isPlausible(_ lyrics: Lyrics) -> Bool {
        let rates = singingRates(lyrics)
        guard rates.count >= 4 else { return true }
        let tooFast = Double(rates.filter { $0 > fastestSinging }.count) / Double(rates.count)
        let median = rates.sorted()[rates.count / 2]
        return tooFast < 0.25 && median < 8.5
    }

    /// False for Japanese lyrics standing in for a Chinese song: the song's names are in Chinese characters
    /// with no kana (愛人 is the name of both 鄧麗君's Chinese song and her Japanese one, and a Japanese release
    /// would say so). Names in Latin letters say nothing either way (a Japanese singer's song may be filed as
    /// "You Don't Understand"), so Japanese lyrics stand for those.
    public static func fitsLanguage(_ lyrics: Lyrics, of query: TrackQuery) -> Bool {
        let japaneseLines = lyrics.lines.filter { TextNormalize.hasKana($0.text) }.count
        let sung = max(lyrics.lines.filter { !$0.isBlank }.count, 1)
        guard Double(japaneseLines) / Double(sung) > 0.3 else { return true }
        let names = query.title + query.artist + query.album
        let chineseNames = names.contains { $0.isCJK } && !TextNormalize.hasKana(names)
        return !chineseNames
    }

    /// Syllables a second for each line with at least four: over its words' own times when they're timed one by
    /// one, otherwise over the time until the next line starts.
    static func singingRates(_ lyrics: Lyrics) -> [Double] {
        let lines = lyrics.lines.filter { !$0.isBlank }
        var rates: [Double] = []
        for (index, line) in lines.enumerated() {
            let syllables = WordTiming.tokenize(line.text).reduce(0) { $0 + $1.weight }
            guard syllables >= 4 else { continue }
            let span: TimeInterval
            if lyrics.timing == .word, let first = line.words.first, let last = line.words.last {
                span = last.end - first.start
            } else if index + 1 < lines.count {
                span = lines[index + 1].start - line.start
            } else {
                continue
            }
            if span > 0 { rates.append(syllables / span) }
        }
        return rates
    }

    /// How far `lyrics` would have to move to line up with `reference`: the median gap between the starts of
    /// lines with the same words, and how many of those lines agree with it to within half a second.
    public static func offset(of lyrics: Lyrics, toMatch reference: Lyrics) -> (offset: TimeInterval, agreement: Double, matched: Int)? {
        var starts: [String: [TimeInterval]] = [:]
        for line in lyrics.lines where !line.isBlank {
            let key = TextNormalize.key(line.text)
            if key.count >= 2 { starts[key, default: []].append(line.start) }
        }
        var used: [String: Int] = [:]
        var gaps: [TimeInterval] = []
        for line in reference.lines where !line.isBlank {
            let key = TextNormalize.key(line.text)
            // A line sung several times matches the same occurrence in each.
            guard let times = starts[key], used[key, default: 0] < times.count else { continue }
            gaps.append(line.start - times[used[key, default: 0]])
            used[key, default: 0] += 1
        }
        guard gaps.count >= 3 else { return nil }
        let median = gaps.sorted()[gaps.count / 2]
        let agreement = Double(gaps.filter { abs($0 - median) < 0.5 }.count) / Double(gaps.count)
        return (median, agreement, gaps.count)
    }

    /// Moves `lyrics` onto `reference`'s line starts, matching lines by their words in order, and stretches
    /// everything between two matched lines to fit, so the words keep their own rhythm inside each line. For
    /// another upload of a song that drifts against this release rather than sitting a fixed time off it.
    /// (From NotchLyrics' TimingTransfer.) Nil when too few lines match, or a stretch would be implausible.
    public static func warp(_ lyrics: Lyrics, onto reference: Lyrics) -> Lyrics? {
        let keys = lyrics.lines.map { TextNormalize.key($0.text) }
        var pairs: [(old: TimeInterval, new: TimeInterval)] = []
        var searchFrom = 0
        for line in reference.lines.sorted(by: { $0.start < $1.start }) where !line.isBlank {
            let key = TextNormalize.key(line.text)
            guard key.count >= 2, let index = (searchFrom..<keys.count).first(where: { keys[$0] == key }) else { continue }
            searchFrom = index + 1
            let old = lyrics.lines[index].start
            // Both sides must keep moving forwards, or the mapping would fold back on itself.
            if let last = pairs.last, old <= last.old || line.start <= last.new { continue }
            pairs.append((old, max(0, line.start)))
        }
        guard pairs.count >= 4 else { return nil }
        // Another arrangement, not a drifting upload: a stretch of the song twice as long or half as long.
        for (a, b) in zip(pairs, pairs.dropFirst()) {
            let factor = (b.new - a.new) / (b.old - a.old)
            if factor < 0.6 || factor > 1.6 { return nil }
        }
        func map(_ time: TimeInterval) -> TimeInterval {
            guard let first = pairs.first, let last = pairs.last else { return time }
            if time <= first.old { return max(0, time + first.new - first.old) }
            if time >= last.old { return max(0, time + last.new - last.old) }
            var low = 0, high = pairs.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if pairs[mid].old <= time { low = mid } else { high = mid }
            }
            let before = pairs[low], after = pairs[high]
            return before.new + (time - before.old) / (after.old - before.old) * (after.new - before.new)
        }
        let lines = lyrics.lines.map { line -> LyricLine in
            let start = map(line.start)
            return LyricLine(start: start, end: max(map(line.end), start), words: line.words.map { word in
                let wordStart = map(word.start)
                return LyricWord(text: word.text, start: wordStart, end: max(map(word.end), wordStart))
            })
        }
        return Lyrics(lines: lines, timing: lyrics.timing, source: lyrics.source)
    }

    /// Drops the opening lines that only name the song: "Title - Artist" or the two run together, and credits
    /// with no colon ("词 Somebody", "曲 Somebody"). A lone line that merely starts like a credit is kept (曲终人散
    /// is a lyric); it takes a title line, or two such lines together, to be the song's name card.
    public static func withoutTitleLines(_ lyrics: Lyrics, title: String, artist: String) -> Lyrics {
        let titleKey = TextNormalize.key(title), artistKey = TextNormalize.key(TextNormalize.primaryArtist(artist))
        func namesSong(_ text: String) -> Bool {
            let key = TextNormalize.key(text)
            return !titleKey.isEmpty && !artistKey.isEmpty && (key == titleKey + artistKey || key == artistKey + titleKey)
        }
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].isBlank }
        var run: [Int] = []
        var hasTitle = false
        for index in sung.prefix(5) {
            let text = lyrics.lines[index].text
            if namesSong(text) {
                hasTitle = true
            } else if !isBareCredit(text) {
                break
            }
            run.append(index)
        }
        guard hasTitle || run.count >= 2, run.count < sung.count else { return lyrics }
        let dropped = Set(run)
        return Lyrics(lines: lyrics.lines.indices.filter { !dropped.contains($0) }.map { lyrics.lines[$0] },
                      timing: lyrics.timing, source: lyrics.source)
    }

    private static let bareLabels = ["作词", "作詞", "作曲", "编曲", "編曲", "制作人", "製作人", "监制", "監製", "词", "詞", "曲"]

    /// "词杨某某" or "曲 Someone": a credit label and a short name, without the colon `CreditFilter` looks for.
    static func isBareCredit(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 24, let label = bareLabels.first(where: { trimmed.hasPrefix($0) }) else { return false }
        let rest = trimmed.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        return !rest.isEmpty
    }
}

extension Lyrics {
    /// The same lyrics, every line and word `seconds` later.
    public func shifted(by seconds: TimeInterval) -> Lyrics {
        guard seconds != 0 else { return self }
        let lines = self.lines.map { line in
            LyricLine(start: line.start + seconds, end: line.end + seconds,
                      words: line.words.map { LyricWord(text: $0.text, start: $0.start + seconds, end: $0.end + seconds) })
        }
        return Lyrics(lines: lines, timing: timing, source: source)
    }
}
