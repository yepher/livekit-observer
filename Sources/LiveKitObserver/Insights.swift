import Foundation

/// What to look at first in a session: slow turns, interruptions, warnings.
struct SessionInsights: Sendable {
    struct Stat: Sendable { let median: Double; let p95: Double; let max: Double; let count: Int }

    let agentTurns: Int
    let userTurns: Int
    let interruptions: Int
    let e2e: Stat?
    let llmTtft: Stat?
    let ttsTtfb: Stat?
    let endOfTurn: Stat?
    let transcription: Stat?
    let slowTurns: [TranscriptItem]
    let lowConfidence: [TranscriptItem]
    let problems: [LogRecord]
    let failedSpans: [Span]

    static let slowTurnMs = 2000.0
    static let lowConfidence = 0.6

    init(transcript: [TranscriptItem], logs: [LogRecord], spans: [Span]) {
        let agent = transcript.filter { $0.role == .agent && $0.kind == "message" }
        let user = transcript.filter { $0.role == .user && $0.kind == "message" }
        agentTurns = agent.count
        userTurns = user.count
        interruptions = transcript.filter(\.interrupted).count
        e2e = Self.stat(agent.compactMap(\.e2eLatencyMs))
        llmTtft = Self.stat(agent.compactMap(\.llmTtftMs))
        ttsTtfb = Self.stat(agent.compactMap(\.ttsTtfbMs))
        endOfTurn = Self.stat(user.compactMap(\.endOfTurnDelayMs))
        transcription = Self.stat(user.compactMap(\.transcriptionDelayMs))
        slowTurns = agent.filter { ($0.e2eLatencyMs ?? 0) >= Self.slowTurnMs }.sorted { ($0.e2eLatencyMs ?? 0) > ($1.e2eLatencyMs ?? 0) }
        lowConfidence = user.filter { ($0.confidence ?? 1) < Self.lowConfidence }
        problems = logs.filter { $0.level >= .warn }
        failedSpans = spans.filter(\.failed)
    }

    static func stat(_ values: [Double]) -> Stat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return Stat(median: pct(0.5), p95: pct(0.95), max: sorted.last!, count: sorted.count)
    }
}

/// A Markdown digest of a session to paste into a coding agent while improving the agent.
enum SessionReport {
    static func markdown(row: SessionRow, transcript: [TranscriptItem], insights: SessionInsights, origin: Date?,
                         flags: [Flag] = [], logs: [LogRecord] = [], spans: [Span] = []) -> String {
        func clock(_ d: Date?) -> String { Format.offset(d, from: origin) }
        func ms(_ s: SessionInsights.Stat?) -> String {
            s.map { "median \(Int($0.median)) ms, p95 \(Int($0.p95)) ms, max \(Int($0.max)) ms (n=\($0.count))" } ?? "n/a"
        }
        var out = """
        # LiveKit session \(row.id)
        Room: \(row.roomName)
        Started: \(row.startedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "unknown"); duration \(Format.duration(row.duration))
        Turns: \(insights.agentTurns) agent, \(insights.userTurns) user, \(insights.interruptions) interrupted

        ## Latency
        - End-to-end: \(ms(insights.e2e))
        - LLM time to first token: \(ms(insights.llmTtft))
        - TTS time to first byte: \(ms(insights.ttsTtfb))
        - User end-of-turn delay: \(ms(insights.endOfTurn))

        """
        if !flags.isEmpty {
            out += "## Flagged by the reviewer (\(flags.count))\n"
            for flag in flags {
                out += "\n### [\(clock(flag.start))–\(clock(flag.end))] \(flag.note.isEmpty ? "Flag" : flag.note)\n"
                for item in transcript where flag.overlaps(from: item.start, to: item.stoppedSpeakingAt) {
                    out += "- \(item.role == .agent ? "AGENT" : item.role == .user ? "USER" : item.kind.uppercased()) [\(clock(item.start))]: \(item.text)\n"
                }
                let flaggedLogs = logs.filter { flag.covers($0.timestamp) }
                for log in flaggedLogs.prefix(30) { out += "- log [\(clock(log.timestamp))] \(log.level.label.uppercased()) \(log.logger): \(log.message)\n" }
                if flaggedLogs.count > 30 { out += "- …and \(flaggedLogs.count - 30) more log lines\n" }
                for span in spans.filter(flag.marks).sorted(by: { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }).prefix(30) {
                    let duration = span.duration.map { String(format: "%.2f s", $0) } ?? "?"
                    out += "- span [\(clock(span.start))] \(span.name) \(duration)\(span.failed ? " FAILED \(span.statusMessage)" : "")\n"
                }
            }
            out += "\n"
        }
        if !insights.problems.isEmpty {
            out += "## Warnings and errors (\(insights.problems.count))\n"
            for log in insights.problems.prefix(40) { out += "- [\(clock(log.timestamp))] \(log.level.label.uppercased()) \(log.logger): \(log.message)\n" }
            out += "\n"
        }
        out += "## Transcript (times from recording start)\n"
        for item in transcript {
            let who = item.role == .agent ? "AGENT" : item.role == .user ? "USER" : item.kind.uppercased()
            var notes: [String] = []
            if let e = item.e2eLatencyMs { notes.append("e2e \(Int(e)) ms") }
            if let c = item.confidence { notes.append(String(format: "conf %.2f", c)) }
            if item.interrupted { notes.append("interrupted") }
            let flagged = flags.contains { $0.overlaps(from: item.start, to: item.stoppedSpeakingAt) } ? "⚑ " : ""
            out += "\(flagged)[\(clock(item.start))] \(who): \(item.text)\(notes.isEmpty ? "" : "  _(\(notes.joined(separator: ", ")))_")\n"
        }
        return out
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "–" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func offset(_ date: Date?, from origin: Date?) -> String {
        guard let date, let origin else { return date.map { $0.formatted(date: .omitted, time: .standard) } ?? "–" }
        let delta = date.timeIntervalSince(origin)
        return (delta < 0 ? "-" : "") + duration(abs(delta))
    }
    static func ms(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "–" }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
