import Foundation

/// A stretch of a session marked while reviewing it, such as a word that came out as static.
/// Flags are highlighted in every view and saved per session on this Mac.
struct Flag: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date
    var note: String

    /// Leeway around a flag for things LiveKit reports at a single instant, such as log lines.
    static let slack: TimeInterval = 0.5

    /// Whether something that happened at `date` belongs to this flag.
    func covers(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date >= start.addingTimeInterval(-Self.slack) && date <= end.addingTimeInterval(Self.slack)
    }

    /// Whether something that ran from `from` to `to` overlaps this flag.
    func overlaps(from: Date?, to: Date?) -> Bool {
        guard let from else { return false }
        let to = max(to ?? from, from)
        return from <= end.addingTimeInterval(Self.slack) && to >= start.addingTimeInterval(-Self.slack)
    }

    /// A span belongs to a flag when it starts inside it or lies mostly inside it, so the session's
    /// long-running spans, which overlap every flag, are not highlighted.
    func marks(_ span: Span) -> Bool {
        guard let s = span.start else { return false }
        if covers(s) { return true }
        guard let e = span.end, e > s else { return false }
        return min(e, end).timeIntervalSince(max(s, start)) >= e.timeIntervalSince(s) * 0.5
    }
}

extension SessionDetail {
    func flag(for item: TranscriptItem) -> Flag? { flags.first { $0.overlaps(from: item.start, to: item.stoppedSpeakingAt) } }
    func flag(for log: LogRecord) -> Flag? { flags.first { $0.covers(log.timestamp) } }
    func flag(for span: Span) -> Flag? { flags.first { $0.marks(span) } }
    func flag(at date: Date?) -> Flag? { flags.first { $0.covers(date) } }

    /// The spoken turn under `date`, if any.
    func turn(at date: Date) -> TranscriptItem? {
        transcript.last { item in
            item.kind == "message" && (item.role == .agent || item.role == .user)
                && (item.start ?? .distantFuture) <= date && (item.stoppedSpeakingAt ?? item.start ?? .distantPast) >= date
        }
    }

    /// Spans that are flagged, and the spans that contain one, for marking collapsed rows in the trace tree.
    func flaggedSpans() -> (flagged: Set<Span.ID>, ancestors: Set<Span.ID>) {
        let flagged = Set(spans.filter { flag(for: $0) != nil }.map(\.id))
        let parents = Dictionary(spans.map { ($0.id, $0.parentId) }, uniquingKeysWith: { a, _ in a })
        var ancestors: Set<Span.ID> = []
        for id in flagged {
            var next = parents[id] ?? nil
            while let parent = next, ancestors.insert(parent).inserted { next = parents[parent] ?? nil }
        }
        return (flagged, ancestors)
    }

    static func flagsKey(_ sessionId: String) -> String { "flags." + sessionId }

    static func loadFlags(_ sessionId: String) -> [Flag] {
        guard let data = UserDefaults.standard.data(forKey: flagsKey(sessionId)) else { return [] }
        return (try? JSONDecoder().decode([Flag].self, from: data)) ?? []
    }

    func saveFlags() {
        flags.sort { $0.start < $1.start }
        let key = Self.flagsKey(row.id)
        if flags.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(flags) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Flags the spoken turn under `date`, or a second and a half around it when nobody was speaking.
    @discardableResult
    func addFlag(at date: Date, wholeTurn: Bool = true) -> Flag {
        if wholeTurn, let item = turn(at: date), let start = item.start {
            return addFlag(from: start, to: item.stoppedSpeakingAt ?? start.addingTimeInterval(1), note: Self.label(for: item))
        }
        return addFlag(from: date.addingTimeInterval(-0.75), to: date.addingTimeInterval(0.75), note: "")
    }

    @discardableResult
    func addFlag(from start: Date, to end: Date, note: String) -> Flag {
        let flag = Flag(start: min(start, end), end: max(start, end), note: note)
        flags.append(flag)
        saveFlags()
        return flag
    }

    func removeFlag(_ id: Flag.ID) {
        flags.removeAll { $0.id == id }
        saveFlags()
    }

    func renameFlag(_ id: Flag.ID, to note: String) {
        guard let index = flags.firstIndex(where: { $0.id == id }) else { return }
        flags[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        saveFlags()
    }

    /// A starting note for a flagged turn: who spoke and what was said.
    static func label(for item: TranscriptItem) -> String {
        let text = item.text.count > 60 ? item.text.prefix(59) + "…" : Substring(item.text)
        return "\(item.role == .agent ? "Agent" : "User"): \(text)"
    }
}
