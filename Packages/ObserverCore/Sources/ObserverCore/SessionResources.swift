import Foundation

public enum SessionResource: String, Codable, CaseIterable, Sendable {
    case summary, transcript, logs, traces, metrics, recording
    public var title: String { rawValue.capitalized }
    public func arguments(_ id: String) -> [String] {
        switch self {
        case .summary: ["session", "get", id]
        case .recording: ["session", "recording", id, "--type", "audio"]
        case .transcript: ["session", rawValue, id, "--limit", "5000"]
        default: ["session", rawValue, id, "--limit", "20000"]
        }
    }
}

public struct ResourceReadiness: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case unknown, pending, settled, unavailable, failed }
    public var state: State
    public var checkedAt = Date()
    public var message: String?
    public var shouldRetry: Bool { state == .pending || state == .failed || state == .unknown }
    public init(state: State, checkedAt: Date = .now, message: String? = nil) {
        self.state = state; self.checkedAt = checkedAt; self.message = message
    }
    public init(json: JSONValue) {
        let reported = json["dataStatus"]?["state"]?.string?.replacingOccurrences(of: "DATA_STATE_", with: "").lowercased()
        let page = json["pageInfo"]
        if page?["hasMore"]?.bool == true || !(page?["nextCursor"]?.string ?? "").isEmpty {
            state = .pending; message = "Response is truncated; more data exists upstream."
        } else {
            state = State(rawValue: reported ?? "") ?? (reported == "not_available" ? .unavailable : .unknown)
        }
    }
    public init(error: Error) {
        if let error = error as? LiveKitCLIError {
            switch error.kind {
            case .notReady: state = .pending
            case .observabilityOff, .forbidden, .projectNotFound, .signedOut: state = .unavailable
            default: state = .failed
            }
        } else { state = .failed }
        message = error.localizedDescription
    }
}

public struct SessionResourceDocument: Sendable {
    public let kind: SessionResource
    public let json: JSONValue
    public var readiness: ResourceReadiness {
        var value = ResourceReadiness(json: json)
        if kind == .summary, value.state == .unknown, let session = LiveKitSession(json: json["session"] ?? json) {
            if session.status == "active" { value.state = .pending }
            else if session.status == "closed" { value.state = .settled }
        }
        return value
    }

    public init(kind: SessionResource, json: JSONValue) { self.kind = kind; self.json = json }
}

/// Transport-independent boundary for desktop CLI and future native API adapters.
public protocol SessionSource: Sendable {
    func sessionPage(query: SessionQuery, cursor: String?) async throws -> SessionPage
    func resource(_ id: String, kind: SessionResource) async throws -> SessionResourceDocument
}

public enum SessionResources {
    public static let review: [SessionResource] = [.summary, .transcript, .logs, .traces, .metrics]
    public static func load(source: any SessionSource, id: String, kinds: [SessionResource] = review) async -> [SessionResource: Result<SessionResourceDocument, Error>] {
        await withTaskGroup(of: (SessionResource, Result<SessionResourceDocument, Error>).self) { group in
            for kind in kinds {
                group.addTask {
                    do { return (kind, .success(try await source.resource(id, kind: kind))) }
                    catch { return (kind, .failure(error)) }
                }
            }
            var values: [SessionResource: Result<SessionResourceDocument, Error>] = [:]
            for await (kind, value) in group { values[kind] = value }
            return values
        }
    }
}
