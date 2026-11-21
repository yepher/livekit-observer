import Foundation

/// A LiveKit Cloud session (one room). The session ID is the room SID, `RM_…`.
public struct LiveKitSession: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let roomName: String
    public let status: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let participants: Int?
    public let hasDetailData: Bool
    /// Tags the agent added to the session, such as `flagged:learner`.
    public let tags: [String]

    /// Whether someone flagged a moment from the lesson page; the agent tags such sessions when they end.
    public var flaggedInLesson: Bool { tags.contains(Flag.lessonTag) }

    public init?(json: JSONValue) {
        guard let id = json["sessionId"]?.string ?? json["session_id"]?.string ?? json["id"]?.string else { return nil }
        self.id = id
        roomName = json["roomName"]?.string ?? json["room_name"]?.string ?? ""
        status = (json["status"]?.string ?? "").replacingOccurrences(of: "SESSION_STATUS_", with: "").lowercased()
        startedAt = json["startedAt"]?.date ?? json["started_at"]?.date
        endedAt = json["endedAt"]?.date ?? json["ended_at"]?.date ?? json["lastActive"]?.date
        participants = (json["numParticipants"]?.double ?? json["num_participants"]?.double).map { Int($0) }
        hasDetailData = json["hasDetailData"]?.bool ?? json["has_detail_data"]?.bool ?? false
        tags = (json["tags"]?.array ?? []).compactMap { $0.string ?? $0["name"]?.string }
    }
}

/// One egress recording in Spaces, described by the manifest LiveKit writes next to it.
public struct EgressRecording: Hashable, Codable, Sendable {
    public let egressId: String
    public let roomId: String
    public let roomName: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let audioKey: String
    public var size: Int64 = 0

    public init?(manifest: JSONValue) {
        guard let roomId = manifest["room_id"]?.string,
              let key = manifest["files"]?.array?.compactMap({ $0["filename"]?.string }).first(where: { $0.hasSuffix(".ogg") })
        else { return nil }
        egressId = manifest["egress_id"]?.string ?? ""
        self.roomId = roomId
        roomName = manifest["room_name"]?.string ?? ""
        // Manifest times are Unix nanoseconds.
        let ns = { (v: JSONValue?) in v?.double.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1e9) : nil } }
        startedAt = ns(manifest["started_at"])
        endedAt = ns(manifest["ended_at"])
        audioKey = key
    }
}

/// A row in the session list: what LiveKit knows, the recording, or both.
public struct SessionRow: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var session: LiveKitSession?
    public var recording: EgressRecording?
    /// Minimal durable context for a session with manually imported captures.
    public var localCaptureSession: CaptureSession?

    public var roomName: String { session?.roomName ?? recording?.roomName ?? localCaptureSession?.roomName ?? "" }
    public var startedAt: Date? { session?.startedAt ?? recording?.startedAt ?? localCaptureSession?.startedAt }
    public var endedAt: Date? { session?.endedAt ?? recording?.endedAt ?? localCaptureSession?.endedAt }
    public var duration: TimeInterval? {
        guard let s = startedAt, let e = endedAt, e > s else { return nil }
        return e.timeIntervalSince(s)
    }
    /// What to call the session in lists and titles: its room name, or its ID when the room is unknown.
    public var title: String { roomName.isEmpty ? id : roomName }

    public static func merge(sessions: [LiveKitSession], recordings: [EgressRecording]) -> [SessionRow] {
        var rows: [String: SessionRow] = [:]
        for s in sessions { rows[s.id] = SessionRow(id: s.id, session: s) }
        for r in recordings {
            // A room can have more than one egress if a session reconnected; keep the longest.
            if let existing = rows[r.roomId]?.recording, existing.size >= r.size { continue }
            rows[r.roomId, default: SessionRow(id: r.roomId)].recording = r
        }
        return rows.values.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    public init(id: String, session: LiveKitSession? = nil, recording: EgressRecording? = nil, localCaptureSession: CaptureSession? = nil) { self.id = id; self.session = session; self.recording = recording; self.localCaptureSession = localCaptureSession }
}

public enum Role: String, Sendable { case user, agent, system, other }

/// A transcript item: a message, tool call, tool result, handoff, or config change.
public struct TranscriptItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let timestamp: Date?
    public let kind: String
    public let role: Role
    public let text: String
    public let interrupted: Bool
    public let startedSpeakingAt: Date?
    public let stoppedSpeakingAt: Date?
    public let confidence: Double?
    /// Agent turn timings and user turn delays, in milliseconds, as reported.
    public let e2eLatencyMs: Double?
    public let llmTtftMs: Double?
    public let ttsTtfbMs: Double?
    public let transcriptionDelayMs: Double?
    public let endOfTurnDelayMs: Double?

    public var start: Date? { startedSpeakingAt ?? timestamp }

    public init(json: JSONValue, index: Int) {
        id = json["id"]?.string ?? "item-\(index)"
        timestamp = json["timestamp"]?.date
        let payloadKey = json.object?.keys.sorted().first { !["id", "timestamp"].contains($0) } ?? "message"
        kind = payloadKey
        let m = json[payloadKey] ?? .null
        switch (m["role"]?.string ?? "").uppercased() {
        case let r where r.contains("USER"): role = .user
        case let r where r.contains("AGENT") || r.contains("ASSISTANT"): role = .agent
        case let r where r.contains("SYSTEM") || r.contains("DEVELOPER"): role = .system
        default: role = .other
        }
        if payloadKey == "message" {
            text = m["text"]?.string ?? m["content"]?.description ?? ""
        } else {
            text = m["name"].map { "\($0.description) \(m["arguments"]?.description ?? m["output"]?.description ?? "")" } ?? m.description
        }
        interrupted = m["interrupted"]?.bool ?? false
        startedSpeakingAt = m["startedSpeakingAt"]?.date
        stoppedSpeakingAt = m["stoppedSpeakingAt"]?.date
        confidence = m["transcriptConfidence"]?.double
        e2eLatencyMs = m["e2eLatencyMs"]?.double
        llmTtftMs = m["llmTtftMs"]?.double
        ttsTtfbMs = m["ttsTtfbMs"]?.double
        transcriptionDelayMs = m["transcriptionDelayMs"]?.double
        endOfTurnDelayMs = m["endOfTurnDelayMs"]?.double
    }
}

public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case trace, debug, info, warn, error, fatal
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Trace", "Debug", "Info", "Warn", "Error", "Fatal"][rawValue] }

    public init(text: String) {
        let t = text.uppercased()
        if t.contains("FATAL") || t.contains("CRITICAL") { self = .fatal }
        else if t.contains("ERROR") { self = .error }
        else if t.contains("WARN") { self = .warn }
        else if t.contains("DEBUG") { self = .debug }
        else if t.contains("TRACE") { self = .trace }
        else { self = .info }
    }
}

public struct LogRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let timestamp: Date?
    public let level: LogLevel
    public let logger: String
    public let message: String
    public let attributes: [String: JSONValue]

    public init(json: JSONValue, index: Int) {
        id = json["id"]?.string ?? "log-\(index)"
        timestamp = json["timestamp"]?.date
        level = LogLevel(text: json["level"]?.string ?? json["severityText"]?.string ?? "")
        logger = json["logger"]?.string ?? ""
        message = json["message"]?.string ?? json["body"]?.description ?? ""
        attributes = json["attributes"]?.object ?? [:]
    }
}

public struct Span: Identifiable, Hashable, Sendable {
    public let id: String
    public let parentId: String?
    public let name: String
    public let start: Date?
    public let end: Date?
    public let failed: Bool
    public let statusMessage: String
    public let attributes: [String: JSONValue]

    public var duration: TimeInterval? { start.flatMap { s in end.map { $0.timeIntervalSince(s) } } }

    public init(json: JSONValue, index: Int) {
        id = json["spanId"]?.string ?? "span-\(index)"
        let parent = json["parentSpanId"]?.string ?? ""
        parentId = parent.isEmpty ? nil : parent
        name = json["name"]?.string ?? "span"
        start = json["startTime"]?.date
        end = json["endTime"]?.date
        failed = (json["status"]?.string ?? "").uppercased().contains("ERROR")
        statusMessage = json["statusMessage"]?.string ?? ""
        attributes = json["attributes"]?.object ?? [:]
    }
}

public extension Span {
    /// Time allowed after a TTS line's audio should have finished, for playout delay.
    static let ttsPlayoutSlack: TimeInterval = 0.3

    /// The lines the agent sent to TTS, each from its request until its audio should have finished playing:
    /// the request's start, plus the time to its first audio, plus the audio's length (from `lk.tts_metrics`).
    static func ttsLines(_ spans: [Span]) -> [TTSLine] {
        var seen = Set<String>()
        return spans.compactMap { span in
            guard span.name == "tts_request", let start = span.start, let metrics = span.attributes["lk.tts_metrics"],
                  let audio = metrics["audio_duration"]?.double, audio > 0 else { return nil }
            if let id = metrics["request_id"]?.string, !seen.insert(id).inserted { return nil }
            let ttfb = max(metrics["ttfb"]?.double ?? 0, 0)
            return TTSLine(start: start, end: start.addingTimeInterval(ttfb + audio + ttsPlayoutSlack),
                           text: span.attributes["lk.pii.input_text"]?.string ?? "")
        }
    }
}

public struct MetricPoint: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let unit: String
    public let start: Date?
    public let end: Date?
    public let count: Double?
    public let sum: Double?
    public let min: Double?
    public let max: Double?
    public let value: Double?
    public let attributes: [String: JSONValue]

    public var mean: Double? { guard let c = count, c > 0, let s = sum else { return value }; return s / c }

    public init(json: JSONValue, index: Int) {
        id = "metric-\(index)"
        name = json["name"]?.string ?? "metric"
        unit = json["unit"]?.string ?? ""
        start = json["startTime"]?.date
        end = json["endTime"]?.date
        let h = json["histogram"]
        count = h?["count"]?.double
        sum = h?["sum"]?.double
        min = h?["min"]?.double
        max = h?["max"]?.double
        value = json["value"]?.double ?? json["gauge"]?["value"]?.double ?? json["sum"]?["value"]?.double
            ?? json["asDouble"]?.double ?? json["asInt"]?.double
        attributes = json["attributes"]?.object ?? [:]
    }
}
