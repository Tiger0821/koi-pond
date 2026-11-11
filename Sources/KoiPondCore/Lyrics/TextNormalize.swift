import Foundation

public enum TextNormalize {
    public static func toSimplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    public static func toTraditional(_ text: String) -> String {
        guard text.contains(where: \.isCJK) else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    /// Drops decorations such as "(feat. …)", "[Live]", "【…】" and "- Remastered 2011".
    public static func cleanTitle(_ title: String) -> String {
        var cleaned = title.replacingOccurrences(
            of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+-\s+.*(remaster|live|version|edit|mix|single|mono|stereo).*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    /// What `cleanTitle` takes off: the bracketed parts and a " - Remastered"-style ending, as a matching key.
    public static func decoration(of title: String) -> String {
        let pattern = #"[\(\[（【]([^\)\]）】]*)[\)\]）】]|\s+-\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let ns = title as NSString
        let parts = regex.matches(in: title, range: NSRange(location: 0, length: ns.length)).flatMap { match in
            (1..<match.numberOfRanges).compactMap { match.range(at: $0).location == NSNotFound ? nil : ns.substring(with: match.range(at: $0)) }
        }
        return key(parts.joined(separator: " "))
    }

    /// Words in a title's brackets that mean another recording of the song: another language, a live take, a
    /// cover, an instrumental or a remix. Their lyrics, or their timing, aren't the original's.
    private static let otherVersions = [
        "日", "日文", "日语", "粤", "粤语", "国语", "英文", "韩", "english", "japanese", "cantonese", "korean",
        "live", "现场", "演唱会", "伴奏", "instrumental", "karaoke", "offvocal", "纯音乐", "remix", "dj", "翻唱", "翻自",
        "cover", "原唱", "女声", "男声", "版", "ver", "version", "acoustic", "demo", "钢琴", "piano", "加速", "降调",
        "升调", "片段",
    ]

    /// Whether `candidate` names another version of the song than `title` does: its brackets say live, another
    /// language, a cover and so on, and `title`'s don't.
    public static func isOtherVersion(_ candidate: String, of title: String) -> Bool {
        let theirs = decoration(of: candidate), ours = decoration(of: title)
        guard !theirs.isEmpty, theirs != ours else { return false }
        return otherVersions.contains { theirs.contains($0) && !ours.contains($0) }
    }

    /// Whether any of a source's names for an artist (its name, aliases and translations: 邓丽君, Teresa Teng,
    /// テレサ·テン) is the artist Music names, which may be in either script or in English.
    public static func artistMatches(_ artist: String, names: [String]) -> Bool {
        let primary = primaryArtist(artist)
        return names.contains { name in
            !name.isEmpty && (looselyMatches(name, artist) || looselyMatches(name, primary)
                || looselyMatches(primaryArtist(name), primary))
        }
    }

    /// The text in the other Chinese script too, when it has Chinese characters that change: Music may name a
    /// song in Traditional where a source filed it in Simplified, or the other way round.
    public static func scriptVariants(_ text: String) -> [String] {
        var variants = [text]
        for other in [toSimplified(text), text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text]
        where !variants.contains(other) {
            variants.append(other)
        }
        return variants
    }

    /// Romaji in hiragana ("Wakatteruyo." → "わかってるよ."), for a Japanese song Music names in Latin letters
    /// that a source files in Japanese. Nil for text that isn't all Latin letters, digits and punctuation.
    public static func romajiAsKana(_ text: String) -> String? {
        guard text.contains(where: \.isLetter),
              text.unicodeScalars.allSatisfy({ $0.isASCII || CharacterSet.punctuationCharacters.contains($0) }),
              let kana = text.lowercased().applyingTransform(.latinToHiragana, reverse: false) else { return nil }
        return kana
    }

    /// Whether the text has Japanese kana.
    public static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    public static func primaryArtist(_ artist: String) -> String {
        var result = artist
        for separator in [" & ", ", ", " feat. ", " feat ", " ft. ", " x ", " with ", "/", "、", "＆", ";"] {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }

    /// Comparison key that ignores case, Traditional/Simplified script, width, accents, punctuation and spacing.
    public static func key(_ text: String) -> String {
        let folded = toSimplified(cleanTitle(text))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    public static func looselyMatches(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        return ka == kb || ka.contains(kb) || kb.contains(ka)
    }
}
