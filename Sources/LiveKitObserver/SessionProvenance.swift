import ObserverCore
import Foundation

extension SessionDetail {
    var suggestions: [AISuggestionRange] {
        var result = transcriptionComparisons.filter { $0.differs && $0.decision == nil }.map {
            AISuggestionRange(id: $0.id, start: $0.date, end: $0.date.addingTimeInterval(max(0.1, $0.duration)), text: "AI transcription difference: " + $0.alternative)
        }
        if let aiReview {
            for finding in aiReview.findings where finding.decision == nil {
                let dates = aiReview.evidence.filter { finding.evidenceIDs.contains($0.id) }.compactMap(\.date).sorted()
                if let start = dates.first, let end = dates.last {
                    result.append(AISuggestionRange(id: finding.id, start: start, end: max(start.addingTimeInterval(1), end), text: finding.explanation))
                }
            }
        }
        return result
    }
}
