import Foundation

/// A stretch of a session marked while reviewing it, such as a word that came out as static.
/// Flags are highlighted in every view and saved per session on this Mac.
public struct Flag: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var start: Date
    public var end: Date
    public var note: String
    /// Set for flags read from the session itself (the lesson page's flag button), which are not saved here.
    public var fromLesson: Bool? = nil
    public var aiModel: String? = nil
    public var aiRequestID: String? = nil

    public var isFromLesson: Bool { fromLesson == true }

    /// The session tag and log message the agent writes when the lesson page's flag button is pressed.
    public static let lessonTag = "flagged:learner"
    public static let lessonLogPrefix = "Learner flagged this moment"

    /// Leeway around a flag for things LiveKit reports at a single instant, such as log lines.
    public static let slack: TimeInterval = 0.5

    /// Whether something that happened at `date` belongs to this flag.
    public func covers(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date >= start.addingTimeInterval(-Self.slack) && date <= end.addingTimeInterval(Self.slack)
    }

    /// Whether something that ran from `from` to `to` overlaps this flag.
    public func overlaps(from: Date?, to: Date?) -> Bool {
        guard let from else { return false }
        let to = max(to ?? from, from)
        return from <= end.addingTimeInterval(Self.slack) && to >= start.addingTimeInterval(-Self.slack)
    }

    /// A span belongs to a flag when it starts inside it or lies mostly inside it, so the session's
    /// long-running spans, which overlap every flag, are not highlighted.
    public func marks(_ span: Span) -> Bool {
        guard let s = span.start else { return false }
        if covers(s) { return true }
        guard let e = span.end, e > s else { return false }
        return min(e, end).timeIntervalSince(max(s, start)) >= e.timeIntervalSince(s) * 0.5
    }

    public init(id: UUID = UUID(), start: Date, end: Date, note: String, fromLesson: Bool? = nil, aiModel: String? = nil, aiRequestID: String? = nil) { self.id = id; self.start = start; self.end = end; self.note = note; self.fromLesson = fromLesson; self.aiModel = aiModel; self.aiRequestID = aiRequestID }
}

