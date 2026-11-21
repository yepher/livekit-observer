import Foundation

/// Per-column measures of one channel, for finding static. Filled in by `Spectrogram.compute`.
public struct NoiseTrack: Sendable {
    /// Energy below this counts toward `lowShare`.
    public static let lowShareHz: Float = 2_500

    /// Loudness in dBFS.
    public var level: [Float] = []
    /// Cepstral peak prominence: high for a voice's harmonics, low for noise.
    public var harmonicity: [Float] = []
    /// Share of the energy below `lowShareHz`.
    public var lowShare: [Float] = []

    public init(level: [Float] = [], harmonicity: [Float] = [], lowShare: [Float] = []) { self.level = level; self.harmonicity = harmonicity; self.lowShare = lowShare }
}

/// One line the agent asked TTS to speak, and when its audio should be playing.
public struct TTSLine: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let text: String

    public init(start: Date, end: Date, text: String) { self.start = start; self.end = end; self.text = text }
}

/// A stretch of a TTS line's audio that sounds like static rather than speech.
public struct TTSStatic: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    /// The line being spoken.
    public let text: String
    /// Average loudness of the stretch, in dBFS.
    public let level: Float
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(start: Date, end: Date, text: String, level: Float) { self.start = start; self.end = end; self.text = text; self.level = level }
}

/// Finds static in the agent's TTS audio: stretches at least `minimumRun` long where the sound is audible,
/// holds a steady level, has no voice harmonics, and keeps most of its energy low. Speech fails at least one of
/// these within a fraction of a second: its level swings between syllables, vowels have harmonics, and hiss-like
/// consonants are short and high-pitched. Only each TTS line's own audio is checked, so other sounds in the
/// recording (the learner, played-back clips) don't count.
///
/// Tuned on LiveKit Cloud recordings of `cartesia/sonic-3` producing static for short lines.
public enum StaticDetector {
    public static let minimumLevel: Float = -55
    /// A column with harmonics below this may be static…
    public static let maximumHarmonicity: Float = 0.08
    /// …and a stretch counts only when its median is below this. Static sits near 0.04; speech, even where single
    /// columns dip under `maximumHarmonicity`, has a median well above.
    public static let maximumMedianHarmonicity: Float = 0.06
    public static let minimumLowShare: Float = 0.6
    /// Largest standard deviation of the level, in dB, over `steadyWindow`.
    public static let maximumLevelSpread: Float = 3
    public static let steadyWindow: TimeInterval = 0.4
    /// Gaps this short inside static, where a column happens to look otherwise, are bridged.
    public static let bridgedGap: TimeInterval = 0.2
    public static let minimumRun: TimeInterval = 0.4

    /// - Parameters:
    ///   - track: the agent channel's measures, one per `hop` seconds from `origin`.
    ///   - lines: TTS lines; each is checked only between its start and end.
    public static func find(in track: NoiseTrack, hop: TimeInterval, origin: Date, lines: [TTSLine]) -> [TTSStatic] {
        let count = min(track.level.count, track.harmonicity.count, track.lowShare.count)
        guard count > 0, hop > 0 else { return [] }
        let candidate = candidates(track, count: count, hop: hop)
        let bridge = Int((bridgedGap / hop).rounded()), minimum = Int((minimumRun / hop).rounded())
        let pad = Int((steadyWindow / 2 / hop).rounded())

        var found: [TTSStatic] = []
        for line in lines {
            let a = max(0, Int((line.start.timeIntervalSince(origin) / hop).rounded(.down)))
            let b = min(count, Int((line.end.timeIntervalSince(origin) / hop).rounded(.up)))
            guard b - a >= minimum else { continue }
            var marked = Array(candidate[a..<b])
            // Bridge short gaps between candidate columns.
            var last: Int?
            for i in marked.indices where marked[i] {
                if let l = last, i - l > 1, i - l <= bridge { for j in (l + 1)..<i { marked[j] = true } }
                last = i
            }
            var i = 0
            while i < marked.count {
                guard marked[i] else { i += 1; continue }
                var j = i
                while j < marked.count, marked[j] { j += 1 }
                if j - i >= minimum, median(track.harmonicity[(a + i)..<(a + j)]) < maximumMedianHarmonicity {
                    // The steadiness window trims a run's edges; give them back, within the line.
                    let from = max(0, i - pad), to = min(marked.count, j + pad)
                    let levels = track.level[(a + from)..<(a + to)]
                    found.append(TTSStatic(
                        start: origin.addingTimeInterval(Double(a + from) * hop),
                        end: origin.addingTimeInterval(Double(a + to) * hop),
                        text: line.text,
                        level: levels.reduce(0, +) / Float(levels.count)
                    ))
                }
                i = j
            }
        }
        return merged(found)
    }

    /// Columns that are audible, unvoiced, mostly low, and steady.
    private static func candidates(_ track: NoiseTrack, count: Int, hop: TimeInterval) -> [Bool] {
        let half = max(1, Int((steadyWindow / 2 / hop).rounded()))
        // Running sums for each column's level spread over the steadiness window.
        var sum = [Double](repeating: 0, count: count + 1), squares = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            let v = Double(track.level[i])
            sum[i + 1] = sum[i] + v
            squares[i + 1] = squares[i] + v * v
        }
        return (0..<count).map { i in
            guard track.level[i] > minimumLevel, track.harmonicity[i] < maximumHarmonicity, track.lowShare[i] > minimumLowShare else { return false }
            let lo = max(0, i - half), hi = min(count, i + half)
            let n = Double(hi - lo)
            let mean = (sum[hi] - sum[lo]) / n
            let spread = (max(0, (squares[hi] - squares[lo]) / n - mean * mean)).squareRoot()
            return spread < Double(maximumLevelSpread)
        }
    }

    private static func median(_ values: ArraySlice<Float>) -> Float {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Joins stretches that overlap, as when one request appears twice in the traces.
    private static func merged(_ items: [TTSStatic]) -> [TTSStatic] {
        var result: [TTSStatic] = []
        for item in items.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, item.start <= last.end {
                let total = last.duration + item.duration
                let level = total > 0 ? (last.level * Float(last.duration) + item.level * Float(item.duration)) / Float(total) : last.level
                result[result.count - 1] = TTSStatic(start: last.start, end: max(last.end, item.end), text: last.text, level: level)
            } else {
                result.append(item)
            }
        }
        return result
    }
}
