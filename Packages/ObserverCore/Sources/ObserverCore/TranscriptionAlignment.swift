import Foundation

public struct AlignedWord: Codable, Equatable, Sendable {
    public let original: String?
    public let alternative: String?
    public var differs: Bool { WordAlignment.normalized(original ?? "") != WordAlignment.normalized(alternative ?? "") }

    public init(original: String? = nil, alternative: String? = nil) { self.original = original; self.alternative = alternative }
}

public enum WordAlignment {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    /// Bounded edit-distance alignment. A 512×512 matrix is under 1 MiB; longer turns retain
    /// their full original text in the comparison but explicitly omit word highlighting.
    public static func align(original: String, alternative: String) -> [AlignedWord]? {
        let a = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = alternative.split(whereSeparator: \.isWhitespace).map(String.init)
        guard a.count <= 512, b.count <= 512 else { return nil }
        let n = b.count + 1
        var distance = [UInt16](repeating: 0, count: (a.count + 1) * n)
        for i in 0...a.count { distance[i * n] = UInt16(i) }
        for j in 0...b.count { distance[j] = UInt16(j) }
        let aa = a.map(normalized), bb = b.map(normalized)
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    distance[i * n + j] = min(distance[(i - 1) * n + j] + 1, distance[i * n + j - 1] + 1,
                                               distance[(i - 1) * n + j - 1] + (aa[i - 1] == bb[j - 1] ? 0 : 1))
                }
            }
        }
        var i = a.count, j = b.count, result: [AlignedWord] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0, distance[i * n + j] == distance[(i - 1) * n + j - 1] + (aa[i - 1] == bb[j - 1] ? 0 : 1) {
                result.append(AlignedWord(original: a[i - 1], alternative: b[j - 1])); i -= 1; j -= 1
            } else if i > 0, distance[i * n + j] == distance[(i - 1) * n + j] + 1 {
                result.append(AlignedWord(original: a[i - 1], alternative: nil)); i -= 1
            } else { result.append(AlignedWord(original: nil, alternative: b[j - 1])); j -= 1 }
        }
        return result.reversed()
    }
}

public extension TranscriptionComparison {
    static func aligned(segments: [STTSegment], transcript: [TranscriptItem], origin: Date, clipStart: Double, clipDuration: Double, model: String) -> [Self] {
        let clipOrigin = origin.addingTimeInterval(clipStart), clipEnd = clipOrigin.addingTimeInterval(clipDuration)
        let turns = transcript.filter { $0.role == .user && ($0.start ?? .distantFuture) < clipEnd && ($0.stoppedSpeakingAt ?? $0.start ?? .distantPast) >= clipOrigin }
        let words = segments.flatMap { $0.words ?? [] }
        if !words.isEmpty {
            var used = Set<Int>(), values: [Self] = []
            for turn in turns {
                guard let start = turn.start else { continue }
                let end = turn.stoppedSpeakingAt ?? start.addingTimeInterval(1)
                // Do not call a clipped turn a disagreement with its full transcript.
                guard start >= clipOrigin, end <= clipEnd else { continue }
                let indices = words.indices.filter {
                    let midpoint = clipOrigin.addingTimeInterval((words[$0].start + words[$0].end) / 2)
                    return !used.contains($0) && midpoint >= start && midpoint <= end
                }
                used.formUnion(indices)
                let alternative = indices.map { words[$0].text }.joined(separator: " ")
                guard !alternative.isEmpty else { continue }
                let confidences = indices.compactMap { words[$0].confidence }
                values.append(Self(date: start, duration: end.timeIntervalSince(start), original: turn.text, alternative: alternative, model: model,
                                   words: WordAlignment.align(original: turn.text, alternative: alternative),
                                   confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count), timing: "Word timestamps"))
            }
            return values
        }
        return segments.map { segment in
            let date = clipOrigin.addingTimeInterval(segment.start), end = clipOrigin.addingTimeInterval(segment.start + segment.duration)
            let matching = turns.filter { ($0.start ?? .distantFuture) >= date.addingTimeInterval(-0.5) && ($0.stoppedSpeakingAt ?? .distantFuture) <= end.addingTimeInterval(0.5) }
            let original = matching.map(\.text).joined(separator: " ")
            return Self(date: date, duration: segment.duration, original: original, alternative: segment.text, model: model,
                        words: WordAlignment.align(original: original, alternative: segment.text), confidence: segment.confidence,
                        timing: "Segment timing only; no measured word timestamps")
        }
    }
}
