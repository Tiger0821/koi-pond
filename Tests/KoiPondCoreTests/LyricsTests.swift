import Foundation
import XCTest
@testable import KoiPondCore

// All lyric text below is made up for testing.

final class LyricsParsingTests: XCTestCase {
    func testStandardLRCGetsEstimatedWords() throws {
        let lyrics = try XCTUnwrap(LRCParser.parse("""
        [ar:Someone]
        [00:01.00]Paper boats on the river
        [00:04.50]紙船順流
        """, source: "test"))
        XCTAssertEqual(lyrics.timing, .line)
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(lyrics.lines[0].words.map(\.text).joined(), "Paper boats on the river")
        // One unit per Chinese character.
        XCTAssertEqual(lyrics.lines[1].words.count, 4)
    }

    func testEnhancedLRCKeepsWordTiming() throws {
        let lyrics = try XCTUnwrap(LRCParser.parse("[00:10.00]<00:10.00>Walking <00:10.50>on <00:11.00>clouds<00:12.00>",
                                                   source: "test"))
        XCTAssertEqual(lyrics.timing, .word)
        let words = lyrics.lines[0].words
        XCTAssertEqual(words.map(\.text), ["Walking ", "on ", "clouds"])
        XCTAssertEqual(words[1].start, 10.5, accuracy: 1e-9)
        XCTAssertEqual(words[2].end, 12, accuracy: 1e-9)
    }

    func testYRCKeepsWordTiming() throws {
        let lyrics = try XCTUnwrap(YRCParser.parse("[1000,2000](1000,500,0)今(1500,500,0)晚(2000,1000,0)好", source: "test"))
        XCTAssertEqual(lyrics.timing, .word)
        XCTAssertEqual(lyrics.lines[0].words.map(\.text), ["今", "晚", "好"])
        XCTAssertEqual(lyrics.lines[0].words[2].start, 2, accuracy: 1e-9)
    }

    func testCreditLinesAreDropped() throws {
        let lyrics = try XCTUnwrap(LRCParser.parse("[00:00.00]作词 : 某人\n[00:02.00]Hello lanterns", source: "test"))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Hello lanterns"])
    }

    func testLineLookup() throws {
        let lyrics = try XCTUnwrap(LRCParser.parse("[00:01.00]one\n[00:03.00]two\n[00:05.00]three", source: "test"))
        XCTAssertNil(lyrics.lineIndex(at: 0.5))
        XCTAssertEqual(lyrics.lineIndex(at: 3.2), 1)
        XCTAssertEqual(lyrics.lineIndex(at: 9), 2)
    }

    func testMatchingIgnoresScriptAndDecorations() {
        XCTAssertTrue(TextNormalize.looselyMatches("夜空中最亮的星 (Live)", "夜空中最亮的星"))
        XCTAssertTrue(TextNormalize.looselyMatches("後來", "后来"))
        XCTAssertEqual(TextNormalize.primaryArtist("Someone feat. Another"), "Someone")
        XCTAssertEqual(TextNormalize.toTraditional("后来"), "後來")
    }
}

final class BeatTrackerTests: XCTestCase {
    func testGridCountsBeatsBothWays() {
        let grid = BeatGrid(anchor: 10, period: 0.5, confidence: 1)
        XCTAssertEqual(grid.index(at: 10), 0)
        XCTAssertEqual(grid.index(at: 10.74), 1)
        XCTAssertEqual(grid.index(at: 9.9), -1)
        XCTAssertEqual(grid.sinceBeat(at: 10.6), 0.1, accuracy: 1e-9)
        XCTAssertEqual(grid.sinceBeat(at: 9.9), 0.4, accuracy: 1e-9)
        XCTAssertEqual(grid.untilBeat(at: 10.6), 0.4, accuracy: 1e-9)
        XCTAssertEqual(grid.beatsPerMinute, 120, accuracy: 1e-9)
    }

    func testFindsTempoAndPhaseThroughSlopAndAMissedBeat() throws {
        var tracker = BeatTracker()
        // 150 BPM with a beat at 0.13 s.
        let jitter = [0.006, -0.004, 0.01, -0.008, 0.0, 0.004, -0.006, 0.008, -0.002, 0.003, -0.007, 0.005]
        for (beat, slop) in jitter.enumerated() where beat != 6 {
            tracker.add(onset: 0.13 + Double(beat) * 0.4 + slop)
        }
        let grid = try XCTUnwrap(tracker.grid(at: 4.6))
        XCTAssertEqual(grid.period, 0.4, accuracy: 0.01)
        XCTAssertLessThan(abs(BeatTracker.wrapped((grid.anchor - 0.13) / 0.4)), 0.05)
        XCTAssertGreaterThan(grid.confidence, 0.7)
    }

    func testHalfTimeKicksStayInRange() throws {
        var tracker = BeatTracker()
        for beat in 0..<10 { tracker.add(onset: Double(beat) * 0.75) }
        let grid = try XCTUnwrap(tracker.grid(at: 7))
        XCTAssertTrue(BeatTracker.periods.contains(grid.period))
    }

    func testGoesQuietWhenTheDrumsStop() {
        var tracker = BeatTracker()
        for beat in 0..<12 { tracker.add(onset: Double(beat) * 0.5) }
        XCTAssertNotNil(tracker.grid(at: 6))
        XCTAssertNil(tracker.grid(at: 12))
    }

    func testScatteredOnsetsAreNotTrusted() {
        var tracker = BeatTracker()
        for time in [0.0, 0.31, 1.07, 1.29, 2.2, 2.41, 3.37, 3.5, 4.66] { tracker.add(onset: time) }
        XCTAssertLessThan(tracker.grid(at: 4.7)?.confidence ?? 0, 0.6)
    }
}

final class LyricsTimelineTests: XCTestCase {
    /// Lines at 2, 4 and 6 s, then a long break, then one at 20 s.
    private let lyrics = Lyrics(lines: [
        LyricLine(start: 2, end: 3.6, words: [LyricWord(text: "one", start: 2, end: 3.6)]),
        LyricLine(start: 4, end: 5.6, words: [LyricWord(text: "two", start: 4, end: 5.6)]),
        LyricLine(start: 5.8, end: 5.8, words: [LyricWord(text: " ", start: 5.8, end: 5.8)]),
        LyricLine(start: 6, end: 7.5, words: [LyricWord(text: "three", start: 6, end: 7.5)]),
        LyricLine(start: 20, end: 22, words: [LyricWord(text: "four", start: 20, end: 22)]),
    ], timing: .word, source: "test")

    func testFadesInWithTheFirstLineWaiting() {
        let early = LyricsTimeline.scene(lyrics, at: 0)
        XCTAssertNil(early.current)
        XCTAssertEqual(early.presence, 0)
        let soon = LyricsTimeline.scene(lyrics, at: 1.5)
        XCTAssertNil(soon.current)
        XCTAssertEqual(soon.next, 0)
        XCTAssertGreaterThan(soon.presence, 0)
    }

    func testALineMovesInBeforeItStartsAndSkipsBlankLines() {
        let moving = LyricsTimeline.scene(lyrics, at: 3.8)
        XCTAssertEqual(moving.current, 1)
        XCTAssertEqual(moving.previous, 0)
        XCTAssertEqual(moving.arrival, (3.8 - 3.65) / 0.35, accuracy: 1e-9)
        let settled = LyricsTimeline.scene(lyrics, at: 5.75)
        XCTAssertEqual(settled.current, 3, "the blank line is skipped, so three is already on its way")
        XCTAssertEqual(LyricsTimeline.scene(lyrics, at: 4.5).next, 3)
        XCTAssertNil(LyricsTimeline.scene(lyrics, at: 4.5).previous)
    }

    func testALongBreakLetsThePondBack() {
        XCTAssertEqual(LyricsTimeline.scene(lyrics, at: 8).presence, 1, "the line stays a moment after it's sung")
        let quiet = LyricsTimeline.scene(lyrics, at: 12)
        XCTAssertEqual(quiet.presence, 0)
        XCTAssertNil(quiet.current)
        XCTAssertNil(quiet.next)
        let returning = LyricsTimeline.scene(lyrics, at: 19.4)
        XCTAssertNil(returning.current)
        XCTAssertEqual(returning.next, 4)
        XCTAssertGreaterThan(returning.presence, 0)
        XCTAssertEqual(LyricsTimeline.scene(lyrics, at: 20.5).current, 4)
        XCTAssertEqual(LyricsTimeline.scene(lyrics, at: 30).presence, 0, "and fades out after the last line")
    }
}

final class RockMixTests: XCTestCase {
    /// Verse, a break, a chorus, another verse line, then the chorus again. Each line lasts 2.5 s of a 3 s slot.
    private func song(_ texts: [String?]) -> Lyrics {
        var lines: [LyricLine] = []
        for (slot, text) in texts.enumerated() {
            guard let text else { continue }
            let start = Double(slot) * 3
            lines.append(LyricLine(start: start, end: start + 2.5, words: [LyricWord(text: text, start: start, end: start + 2.5)]))
        }
        return Lyrics(lines: lines, timing: .word, source: "test")
    }

    func testSwitchesAtSectionsAndChorusesButNotTooOften() {
        let lyrics = song(["paper boats", "on the river", "lanterns drift", nil,
                           "hold the light", "hold it high", "one more time", "the river sings",
                           "hold the light", "hold it high"])
        let boundaries = RockMix.boundaries(in: lyrics)
        // The break before "hold the light" (index 3), and the chorus coming back (index 7).
        XCTAssertTrue(boundaries.contains(3))
        XCTAssertTrue(boundaries.contains(7))
        XCTAssertFalse(boundaries.contains(0), "the song's first line already has its style")
        // Never two switches within two lines.
        let sorted = boundaries.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, RockMix.shortest) }
    }

    func testAtLeastEveryFewLinesWithoutAnyCorner() {
        let lyrics = song((0..<12).map { "line number \($0)" })
        let sorted = RockMix.boundaries(in: lyrics).sorted()
        XCTAssertEqual(sorted, [4, 8])
    }

    func testNeverTheSameStyleTwiceInARow() {
        let lyrics = song((0..<40).map { "line number \($0)" })
        var mix = RockMix(lyrics: lyrics, fixed: nil, energy: 0.5, roll: 0.3)
        var styles = [mix.current]
        for line in lyrics.lines.indices {
            if mix.update(line: line, energy: Double(line % 5) / 4, roll: Double((line * 37) % 100) / 100) {
                styles.append(mix.current)
            }
        }
        XCTAssertGreaterThan(styles.count, 5)
        for (a, b) in zip(styles, styles.dropFirst()) { XCTAssertNotEqual(a, b) }
    }

    func testACalmSongKeepsToCalmStylesAndAWildOneToWildOnes() {
        let lyrics = song((0..<60).map { "line number \($0)" })
        func styles(energy: Double) -> [RockStyle] {
            var mix = RockMix(lyrics: lyrics, fixed: nil, energy: energy, roll: 0.4)
            var picked = [mix.current]
            for line in lyrics.lines.indices where mix.update(line: line, energy: energy, roll: Double((line * 53) % 100) / 100) {
                picked.append(mix.current)
            }
            return picked
        }
        let ballad = styles(energy: 0.1), anthem = styles(energy: 0.95)
        XCTAssertGreaterThanOrEqual(Double(ballad.filter { $0.motion == .standard }.count) / Double(ballad.count), 0.9)
        XCTAssertGreaterThanOrEqual(Double(anthem.filter { $0.motion == .exaggerated }.count) / Double(anthem.count), 0.9)
    }

    func testTheLineBeforeLeavesInItsOwnStyle() {
        let lyrics = song((0..<8).map { "line number \($0)" })
        var mix = RockMix(lyrics: lyrics, fixed: nil, energy: 0.5, roll: 0.5)
        for line in 0..<4 { mix.update(line: line, energy: 0.5, roll: 0.5) }
        let before = mix.current
        XCTAssertTrue(mix.update(line: 4, energy: 0.5, roll: 0.5))
        XCTAssertEqual(mix.previous, before)
        XCTAssertNotEqual(mix.current, before)
    }

    func testLeansToWildStylesWhenLoud() {
        func count(_ style: RockStyle, energy: Double) -> Int {
            (0..<100).filter { RockMix.pick(after: nil, energy: energy, roll: Double($0) / 100) == style }.count
        }
        XCTAssertGreaterThan(count(.moshPit, energy: 1), count(.glitch, energy: 1) * 2)
        XCTAssertGreaterThan(count(.posterStomp, energy: 0), count(.moshPit, energy: 0) * 10)
        XCTAssertGreaterThan(count(.headbang, energy: 0.45), count(.posterStomp, energy: 0.45))
    }

    func testAChosenStyleStaysPut() {
        let lyrics = song((0..<12).map { "line number \($0)" })
        var mix = RockMix(lyrics: lyrics, fixed: .glitch, energy: 1, roll: 0.9)
        for line in lyrics.lines.indices { XCTAssertFalse(mix.update(line: line, energy: 1, roll: 0.9)) }
        XCTAssertEqual(mix.current, .glitch)
    }
}

final class TimingCheckTests: XCTestCase {
    /// Lines of `text` every `gap` seconds, each character timed one by one over `sung` seconds.
    private func wordTimed(_ texts: [String], gap: Double, sung: Double, from start: Double = 10) -> Lyrics {
        let lines = texts.enumerated().map { index, text -> LyricLine in
            let begin = start + Double(index) * gap
            let step = sung / Double(text.count)
            let words = text.enumerated().map { LyricWord(text: String($1), start: begin + Double($0) * step,
                                                          end: begin + Double($0 + 1) * step) }
            return LyricLine(start: begin, end: begin + sung, words: words)
        }
        return Lyrics(lines: lines, timing: .word, source: "test")
    }

    private let verse = ["月光落在河面上", "紙船慢慢漂遠了", "我們沿著岸邊走", "燈籠一盞一盞亮", "風把歌聲吹過橋", "夜色溫柔像從前"]

    func testBelievableSingingPasses() {
        // Seven characters over 3 seconds: an easy ballad pace.
        XCTAssertTrue(TimingCheck.isPlausible(wordTimed(verse, gap: 4, sung: 3)))
        // Fast rap, still possible: seven characters in a second.
        XCTAssertTrue(TimingCheck.isPlausible(wordTimed(verse, gap: 1.2, sung: 1)))
    }

    func testWordsCrammedIntoAFractionOfASecondAreRejected() {
        // The words spread over 0.6 s of each line: 12 characters a second, nobody sings that.
        XCTAssertFalse(TimingCheck.isPlausible(wordTimed(verse, gap: 4, sung: 0.6)))
    }

    func testLinesTooCloseTogetherAreRejected() throws {
        // Line timing only: seven characters every half second.
        let text = verse.enumerated().map { String(format: "[00:%05.2f]%@", 10 + Double($0) * 0.5, $1) }.joined(separator: "\n")
        let lyrics = try XCTUnwrap(LRCParser.parse(text, source: "test"))
        XCTAssertFalse(TimingCheck.isPlausible(lyrics))
    }

    func testFindsHowFarAnotherUploadIsOff() throws {
        let release = wordTimed(verse, gap: 4, sung: 3, from: 10)
        let upload = wordTimed(verse, gap: 4, sung: 3, from: 10.9)
        let match = try XCTUnwrap(TimingCheck.offset(of: upload, toMatch: release))
        XCTAssertEqual(match.offset, -0.9, accuracy: 1e-9)
        XCTAssertEqual(match.agreement, 1)
        XCTAssertEqual(match.matched, verse.count)
        let moved = upload.shifted(by: match.offset)
        XCTAssertEqual(moved.lines[2].words[3].start, release.lines[2].words[3].start, accuracy: 1e-9)
    }

    func testAnotherArrangementDoesNotAgree() throws {
        let release = wordTimed(verse, gap: 4, sung: 3)
        // The same lines, but sung at another pace: the gaps grow line by line.
        let other = wordTimed(verse, gap: 5.5, sung: 3)
        let match = try XCTUnwrap(TimingCheck.offset(of: other, toMatch: release))
        XCTAssertLessThan(match.agreement, 0.6)
    }

    func testAnUploadThatDriftsIsMovedLineByLine() throws {
        let release = wordTimed(verse, gap: 4, sung: 3, from: 10)
        // Starts on time but gets 0.2 s later every line, as a slightly slower master would.
        let upload = wordTimed(verse, gap: 4.2, sung: 3, from: 10)
        let warped = try XCTUnwrap(TimingCheck.warp(upload, onto: release))
        for (moved, line) in zip(warped.lines, release.lines) { XCTAssertEqual(moved.start, line.start, accuracy: 1e-6) }
        // The words keep their order and stay inside their line.
        let words = warped.lines[3].words
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.start < $1.start })
        XCTAssertGreaterThanOrEqual(words[0].start, warped.lines[3].start - 1e-9)
        // Another arrangement is not stretched to fit: twice as slow.
        XCTAssertNil(TimingCheck.warp(wordTimed(verse, gap: 8, sung: 3, from: 10), onto: release))
    }

    func testDropsTheSongsNameCardButKeepsLyricsThatStartLikeCredits() {
        var lines = wordTimed(["燈籠鄧小月", "词王小明", "曲 Some Body"] + verse, gap: 3, sung: 2).lines
        var lyrics = Lyrics(lines: lines, timing: .word, source: "test")
        let cleaned = TimingCheck.withoutTitleLines(lyrics, title: "燈籠", artist: "鄧小月")
        XCTAssertEqual(cleaned.lines.first?.text, verse[0])
        XCTAssertEqual(cleaned.lines.count, verse.count)
        // A single line that only starts like a credit is a lyric.
        lines = wordTimed(["曲終人散夜未央"] + verse, gap: 3, sung: 2).lines
        lyrics = Lyrics(lines: lines, timing: .word, source: "test")
        XCTAssertEqual(TimingCheck.withoutTitleLines(lyrics, title: "燈籠", artist: "鄧小月").lines.count, verse.count + 1)
    }

    func testOtherVersionsOfASongAreNotTheSong() {
        XCTAssertTrue(TextNormalize.isOtherVersion("紙船(日)", of: "紙船"))
        XCTAssertTrue(TextNormalize.isOtherVersion("紙船 (日語版)", of: "紙船"))
        XCTAssertTrue(TextNormalize.isOtherVersion("紙船 (Live)", of: "紙船"))
        XCTAssertTrue(TextNormalize.isOtherVersion("紙船 (原唱 某人 Cover)", of: "紙船"))
        XCTAssertTrue(TextNormalize.isOtherVersion("紙船 (伴奏)", of: "紙船"))
        XCTAssertFalse(TextNormalize.isOtherVersion("紙船 (Remastered 2019)", of: "紙船"))
        XCTAssertFalse(TextNormalize.isOtherVersion("紙船", of: "紙船"))
        XCTAssertFalse(TextNormalize.isOtherVersion("紙船 (Live)", of: "紙船 (Live)"), "the live take matches the live take")
    }

    func testTheSungLineWinsOverATranslationAtTheSameTime() throws {
        let lyrics = try XCTUnwrap(LRCParser.parse("""
        [00:10.00]紙船慢慢漂遠了
        [00:10.00]The paper boat drifts away
        [00:14.00]燈籠一盞一盞亮
        [00:14.00]Lanterns light one by one
        """, source: "test"))
        XCTAssertEqual(lyrics.lines.map(\.text), ["紙船慢慢漂遠了", "燈籠一盞一盞亮"])
        // With the translation gone, the line runs until the next one, not for no time at all.
        XCTAssertGreaterThan(lyrics.lines[0].end, 12)
    }
}

final class LyricsMatchingTests: XCTestCase {
    func testAnArtistIsFoundUnderAnyOfTheirNames() {
        // A source lists the Simplified name with its aliases; Music may give the English or Traditional one.
        let names = ["邓小月", "Moon Deng", "デン・コツキ"]
        XCTAssertTrue(TextNormalize.artistMatches("Moon Deng", names: names))
        XCTAssertTrue(TextNormalize.artistMatches("鄧小月", names: names))
        XCTAssertTrue(TextNormalize.artistMatches("Moon Deng & Friends", names: names))
        XCTAssertFalse(TextNormalize.artistMatches("Lantern Band", names: names))
    }

    func testTitlesMatchAcrossTraditionalAndSimplified() {
        XCTAssertTrue(TextNormalize.looselyMatches("紙船慢慢漂遠", "纸船慢慢漂远"))
        XCTAssertTrue(TextNormalize.looselyMatches("愛人（國語）", "爱人"))
        let variants = TextNormalize.scriptVariants("紙船漂遠")
        XCTAssertTrue(variants.contains("紙船漂遠"))
        XCTAssertTrue(variants.contains("纸船漂远"))
        XCTAssertEqual(TextNormalize.scriptVariants("Paper Boats"), ["Paper Boats"])
    }

    func testRomajiTurnsIntoKanaForAJapaneseSongNamedInLatinLetters() {
        XCTAssertEqual(TextNormalize.romajiAsKana("Kamifune"), "かみふね")
        XCTAssertTrue(TextNormalize.looselyMatches(TextNormalize.romajiAsKana("Kawa no Mukou.") ?? "", "かわのむこう。"))
        XCTAssertNil(TextNormalize.romajiAsKana("紙船"))
        XCTAssertNil(TextNormalize.romajiAsKana("1999"))
    }

    func testJapaneseLyricsDoNotStandInForAChineseSong() throws {
        let japanese = try XCTUnwrap(LRCParser.parse("""
        [00:10.00]かみのふねがながれてく
        [00:14.00]とうろうがひとつずつ
        [00:18.00]かわのむこうへ
        """, source: "test"))
        let chinese = TrackQuery(title: "紙船", artist: "鄧小月", album: "河邊", duration: 200)
        XCTAssertFalse(TimingCheck.fitsLanguage(japanese, of: chinese))
        // A release that says it's Japanese keeps its Japanese lyrics.
        let release = TrackQuery(title: "紙船", artist: "デン・コツキ", album: "ベスト", duration: 200)
        XCTAssertTrue(TimingCheck.fitsLanguage(japanese, of: release))
        // So does a song whose names are in Latin letters, as a Japanese singer's often are.
        let romanized = TrackQuery(title: "Paper Boat", artist: "Kotsuki", album: "River Side", duration: 200)
        XCTAssertTrue(TimingCheck.fitsLanguage(japanese, of: romanized))
    }
}

final class SongIntensityTests: XCTestCase {
    /// Lines of seven characters, `pace` characters a second, a line every `gap` seconds.
    private func lyrics(pace: Double, gap: Double) -> Lyrics {
        let texts = ["月光落在河面上", "紙船慢慢漂遠了", "我們沿著岸邊走", "燈籠一盞一盞亮", "風把歌聲吹過橋", "夜色溫柔像從前"]
        let lines = texts.enumerated().map { index, text -> LyricLine in
            let start = 10 + Double(index) * gap, step = 1 / pace
            let words = text.enumerated().map { LyricWord(text: String($1), start: start + Double($0) * step,
                                                          end: start + Double($0 + 1) * step) }
            return LyricLine(start: start, end: start + Double(text.count) * step, words: words)
        }
        return Lyrics(lines: lines, timing: .word, source: "test")
    }

    func testABalladIsCalmAndRapIsWild() {
        XCTAssertLessThan(SongIntensity.fromLyrics(lyrics(pace: 1.3, gap: 7)), 0.1)
        XCTAssertEqual(SongIntensity.fromLyrics(lyrics(pace: 2.6, gap: 4)), 0.46, accuracy: 0.05)
        XCTAssertGreaterThan(SongIntensity.fromLyrics(lyrics(pace: 4.5, gap: 2)), 0.95)
    }

    func testASteadyQuickBeatMakesASongWilder() {
        let soft = SongIntensity.fromBeat(strength: 0.2, beatsPerMinute: 90)
        let driving = SongIntensity.fromBeat(strength: 0.85, beatsPerMinute: 150)
        XCTAssertLessThan(soft, 0.1)
        XCTAssertGreaterThan(driving, 0.9)
        // The words count alone until the beat has been heard a while, then the beat takes part.
        XCTAssertEqual(SongIntensity.combined(lyrics: 0.3, beat: driving, heard: 0), 0.3, accuracy: 1e-9)
        XCTAssertGreaterThan(SongIntensity.combined(lyrics: 0.3, beat: driving, heard: 30), 0.6)
    }

    func testLoudPartsNudgeButDoNotTurnABalladWild() {
        XCTAssertLessThan(SongIntensity.energy(song: 0.1, section: 1), 0.35)
        XCTAssertGreaterThan(SongIntensity.energy(song: 0.85, section: 0), 0.6)
        XCTAssertEqual(SongIntensity.describe(0.1), "calm")
        XCTAssertEqual(SongIntensity.describe(0.5), "lively")
        XCTAssertEqual(SongIntensity.describe(0.9), "wild")
    }
}
