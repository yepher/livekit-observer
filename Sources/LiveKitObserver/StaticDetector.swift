import Foundation

/// Per-column measures of one channel, for finding static. Filled in by `Spectrogram.compute`.
struct NoiseTrack: Sendable {
    /// Energy below this counts toward `lowShare`.
    static let lowShareHz: Float = 2_500

    /// Loudness in dBFS.
    var level: [Float] = []
    /// Cepstral peak prominence: high for a voice's harmonics, low for noise.
    var harmonicity: [Float] = []
    /// Share of the energy below `lowShareHz`.
    var lowShare: [Float] = []
}

/// One line the agent asked TTS to speak, and when its audio should be playing.
struct TTSLine: Hashable, Sendable {
    let start: Date
    let end: Date
    let text: String
}

/// A stretch of a TTS line's audio that sounds like static rather than speech.
struct TTSStatic: Identifiable, Hashable, Sendable {
    var id: Date { start }
    let start: Date
    let end: Date
    /// The line being spoken.
    let text: String
    /// Average loudness of the stretch, in dBFS.
    let level: Float
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Finds static in the agent's TTS audio: stretches at least `minimumRun` long where the sound is audible,
/// holds a steady level, has no voice harmonics, and keeps most of its energy low. Speech fails at least one of
/// these within a fraction of a second: its level swings between syllables, vowels have harmonics, and hiss-like
/// consonants are short and high-pitched. Only each TTS line's own audio is checked, so other sounds in the
/// recording (the learner, played-back clips) don't count.
///
/// Tuned on LiveKit Cloud recordings of `cartesia/sonic-3` producing static for short lines.
enum StaticDetector {
    static let minimumLevel: Float = -55
    /// A column with harmonics below this may be static…
    static let maximumHarmonicity: Float = 0.08
    /// …and a stretch counts only when its median is below this. Static sits near 0.04; speech, even where single
    /// columns dip under `maximumHarmonicity`, has a median well above.
    static let maximumMedianHarmonicity: Float = 0.06
    static let minimumLowShare: Float = 0.6
    /// Largest standard deviation of the level, in dB, over `steadyWindow`.
    static let maximumLevelSpread: Float = 3
    static let steadyWindow: TimeInterval = 0.4
    /// Gaps this short inside static, where a column happens to look otherwise, are bridged.
    static let bridgedGap: TimeInterval = 0.2
    static let minimumRun: TimeInterval = 0.4

    /// - Parameters:
    ///   - track: the agent channel's measures, one per `hop` seconds from `origin`.
    ///   - lines: TTS lines; each is checked only between its start and end.
    static func find(in track: NoiseTrack, hop: TimeInterval, origin: Date, lines: [TTSLine]) -> [TTSStatic] {
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
