import Foundation

public struct TTSProvenance: Sendable {
    public var model: String?
    public var voice: String?
    public var evidenceID: String?
    public static func find(at date: Date, spans: [Span]) -> Self {
        let matching = spans.filter { span in
            guard span.name == "tts_request", let start = span.start, start <= date else { return false }
            let metrics = span.attributes["lk.tts_metrics"]
            let length = (metrics?["ttfb"]?.double ?? 0) + (metrics?["audio_duration"]?.double ?? 0) + Span.ttsPlayoutSlack
            return date <= max(span.end ?? start, start.addingTimeInterval(length))
        }.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
        guard let span = matching.first else { return Self() }
        // Standard SDK model fields; optional Observer-owned voice metadata is an explicit
        // agent instrumentation contract. Never infer a voice from its sound or current config.
        return Self(model: span.attributes["gen_ai.response.model"]?.string ?? span.attributes["gen_ai.request.model"]?.string ?? span.attributes["lk.tts_metrics"]?["metadata"]?["model_name"]?.string,
                    voice: span.attributes["observer.tts.voice"]?.string, evidenceID: span.id)
    }

    public init(model: String? = nil, voice: String? = nil, evidenceID: String? = nil) { self.model = model; self.voice = voice; self.evidenceID = evidenceID }
}

public struct AgentProvenance: Sendable {
    public let agentIDs: [String]
    public var agentID: String? { agentIDs.count == 1 ? agentIDs.first : nil }
    public let versions: [String]
    public let evidenceIDs: [String]
    public var version: String? { agentIDs.count <= 1 && versions.count == 1 ? versions.first : nil }
    public init(logs: [LogRecord], spans: [Span]) {
        let records = logs.map { ($0.id, $0.attributes) } + spans.map { ($0.id, $0.attributes) }
        agentIDs = Array(Set(records.compactMap { $0.1["lk.cloud_agent_id"]?.string }.filter { !$0.isEmpty })).sorted()
        // The current API does not promise a served-version field. Agents may explicitly record
        // observer.agent_version with their immutable deployment version for exact correlation.
        let evidence = records.compactMap { id, attributes -> (String, String)? in
            guard let value = attributes["observer.agent_version"]?.string, !value.isEmpty else { return nil }
            return (id, value)
        }
        versions = Array(Set(evidence.map(\.1))).sorted(); evidenceIDs = evidence.map(\.0)
    }
}

public struct AISuggestionRange: Identifiable {
    public let id: UUID, start: Date, end: Date, text: String

    public init(id: UUID, start: Date, end: Date, text: String) { self.id = id; self.start = start; self.end = end; self.text = text }
}

