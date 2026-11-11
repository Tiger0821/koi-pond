import Foundation

/// How intense a song is, 0 (a slow ballad) to 1 (fast and hard-hitting), which decides how wild its Rock and
/// Roll lyrics get. Judged first from the lyrics, by how fast the words come, then from the beat once there is
/// one to go by: a strong, steady beat at a quick tempo makes a song wilder.
public enum SongIntensity {
    /// From the lyrics alone: the typical line's syllables a second (one per Chinese, Japanese or Korean
    /// character, about one per three Latin letters). Ballads sing about 1 to 1.5 a second, most songs 2 to 3,
    /// fast songs and rap 4 or more.
    public static func fromLyrics(_ lyrics: Lyrics) -> Double {
        let rates = TimingCheck.singingRates(lyrics).sorted()
        guard !rates.isEmpty else { return 0.5 }
        return clamp((rates[rates.count / 2] - 1.4) / 2.6)
    }

    /// From the beat: how steady it is (the beat grid's confidence, averaged over the song so far) and how fast.
    /// Soft or loose drums, as in most ballads, give a weak grid.
    public static func fromBeat(strength: Double, beatsPerMinute: Double) -> Double {
        let steady = clamp((strength - 0.25) / 0.5)
        let quick = clamp((beatsPerMinute - 85) / 60)
        return steady * (0.55 + 0.45 * quick)
    }

    /// Both together, once `heard` seconds of beat have come in; the lyrics alone until then.
    public static func combined(lyrics: Double, beat: Double?, heard: TimeInterval) -> Double {
        guard let beat else { return lyrics }
        let trust = clamp(heard / 20) * 0.6
        return lyrics * (1 - trust) + beat * trust
    }

    /// What the mix aims for at a moment: the song's intensity, nudged up in its loud parts and down in quiet
    /// ones (`section`, 0 to 1, against the song's own loudest), not so far that a ballad turns wild.
    public static func energy(song: Double, section: Double) -> Double {
        clamp(song + (section - 0.5) * 0.4)
    }

    /// A word for the log and Settings.
    public static func describe(_ intensity: Double) -> String {
        intensity < 0.35 ? "calm" : intensity < 0.65 ? "lively" : "wild"
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
