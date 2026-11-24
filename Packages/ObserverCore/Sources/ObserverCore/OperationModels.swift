import Foundation

public extension JSONValue {
    /// Public API uses camelCase; CLI simulation exports use protobuf snake_case.
    func field(_ name: String) -> JSONValue? {
        if let value = self[name] { return value }
        let snake = name.reduce(into: "") { result, character in
            if character.isUppercase { result += "_" + character.lowercased() } else { result.append(character) }
        }
        return self[snake]
    }
    func text(_ name: String) -> String { field(name)?.string ?? "" }
}

public struct CloudAgent: Identifiable, Hashable, Sendable {
    public struct Deployment: Hashable, Sendable {
        public let region: String, status: String, version: String, name: String
        public let replicas: Int?
        public var healthy: Bool { ["running", "ready", "available"].contains(status.lowercased()) }
        public init(_ json: JSONValue) {
            region = json.text("region"); status = json.text("status"); version = json.text("version")
            name = json.text("deployment").isEmpty ? "production" : json.text("deployment")
            replicas = json.field("replicas")?.double.map(Int.init)
        }
    }
    public let id: String, name: String, version: String
    public let deployedAt: Date?
    public let deployments: [Deployment]
    public var title: String { name.isEmpty ? id : name }
    public var status: String { deployments.isEmpty ? "Unknown" : Array(Set(deployments.map(\.status))).sorted().joined(separator: ", ") }
    public var healthy: Bool { !deployments.isEmpty && deployments.allSatisfy(\.healthy) }
    public init?(json: JSONValue) {
        guard !json.text("agentId").isEmpty else { return nil }
        id = json.text("agentId"); name = json.text("agentName"); version = json.text("version")
        deployedAt = json.field("deployedAt")?.date
        deployments = (json.field("agentDeployments")?.array ?? []).map(Deployment.init)
    }
}

public struct AgentVersion: Identifiable, Sendable {
    public let id: String, status: String
    public let current: Bool, active: Bool, draining: Bool
    public let createdAt: Date?, deployedAt: Date?
    public let attributes: [String: String]
    public init?(json: JSONValue) {
        guard !json.text("version").isEmpty else { return nil }; id = json.text("version")
        status = json.text("status"); current = json["current"]?.bool ?? false
        active = json["active"]?.bool ?? false; draining = json["draining"]?.bool ?? false
        createdAt = json.field("createdAt")?.date; deployedAt = json.field("deployedAt")?.date
        attributes = (json["attributes"]?.object ?? [:]).compactMapValues(\.string)
    }
}

public struct SimulationJob: Identifiable, Sendable {
    public let id: String, scenarioID: String, label: String, status: String, error: String
    public let instructions: String, expectations: String, roomID: String, roomName: String
    public let startedAt: Date?, endedAt: Date?
    public var duration: TimeInterval? { guard let startedAt, let endedAt else { return nil }; return endedAt.timeIntervalSince(startedAt) }
    public init?(json: JSONValue) {
        guard !json.text("id").isEmpty else { return nil }; id = json.text("id")
        scenarioID = json.text("scenarioId"); label = json.text("label")
        status = json.text("status").replacingOccurrences(of: "STATUS_", with: "").lowercased()
        error = json.text("error").isEmpty ? json.text("failureReason") : json.text("error")
        instructions = json.text("instructions"); expectations = json.text("agentExpectations")
        roomID = json.text("roomId"); roomName = json.text("roomName")
        startedAt = json.field("startedAt")?.date; endedAt = json.field("endedAt")?.date
    }
}

public struct SimulationRun: Identifiable, Sendable {
    public let id: String, agentName: String, status: String, mode: String, error: String
    public let createdAt: Date?, endedAt: Date?
    public let passed: Int?, failed: Int?, count: Int?
    public let jobs: [SimulationJob]
    public let scenarioGroup: JSONValue?
    public var finished: Bool { ["completed", "failed", "cancelled"].contains(status) }
    public init?(json: JSONValue) {
        let json = json["run"] ?? json
        guard !json.text("id").isEmpty else { return nil }; id = json.text("id")
        agentName = json.text("agentName"); status = json.text("status").replacingOccurrences(of: "STATUS_", with: "").lowercased()
        mode = json.text("mode").replacingOccurrences(of: "SIMULATION_MODE_", with: "").lowercased()
        error = json.text("error"); createdAt = json.field("createdAt")?.date; endedAt = json.field("endedAt")?.date
        passed = json.field("passedCount")?.double.map(Int.init); failed = json.field("failedCount")?.double.map(Int.init)
        count = json.field("jobCount")?.double.map(Int.init) ?? json.field("numSimulations")?.double.map(Int.init)
        jobs = (json["jobs"]?.array ?? []).compactMap(SimulationJob.init)
        scenarioGroup = json.field("scenarioGroup")
    }
}

public struct LiveRoom: Identifiable, Sendable {
    public let id: String, name: String, metadata: String
    public let participants: Int, createdAt: Date?
    public let publishers: Int, maxParticipants: Int
    public let emptyTimeout: Int, departureTimeout: Int
    public let recording: Bool
    public let codecs: [String]
    /// The CLI's room record, without the TURN password.
    public let raw: JSONValue
    public init?(json: JSONValue) {
        guard !json.text("sid").isEmpty else { return nil }; id = json.text("sid")
        name = json.text("name"); metadata = json.text("metadata")
        participants = Int(json.field("numParticipants")?.double ?? 0)
        createdAt = json.field("creationTime")?.double.map { Date(timeIntervalSince1970: $0) }
        publishers = Int(json.field("numPublishers")?.double ?? 0)
        maxParticipants = Int(json.field("maxParticipants")?.double ?? 0)
        emptyTimeout = Int(json.field("emptyTimeout")?.double ?? 0)
        departureTimeout = Int(json.field("departureTimeout")?.double ?? 0)
        recording = json.field("activeRecording")?.bool ?? false
        codecs = (json.field("enabledCodecs")?.array ?? []).compactMap { $0.field("mime")?.string }
        var object = json.object ?? [:]
        object["turnPassword"] = nil; object["turn_password"] = nil
        raw = .object(object)
    }
}
public struct LiveParticipant: Identifiable, Sendable {
    public struct Track: Identifiable, Sendable {
        public let id: String, name: String, type: String
        public let muted: Bool
        public let source: String, mimeType: String
        public let simulcast: Bool
        public let width: Int, height: Int
        public init?(_ json: JSONValue) {
            guard !json.text("sid").isEmpty else { return nil }; id = json.text("sid")
            name = json.text("name"); type = json.text("type"); muted = json["muted"]?.bool ?? false
            source = json.text("source"); mimeType = json.text("mimeType")
            simulcast = json.field("simulcast")?.bool ?? false
            width = Int(json.field("width")?.double ?? 0); height = Int(json.field("height")?.double ?? 0)
        }
        /// "audio/opus · microphone", or the track type when the CLI leaves those out.
        public var summary: String {
            let parts = [mimeType, source.lowercased().replacingOccurrences(of: "_", with: " ")].filter { !$0.isEmpty }
            return parts.isEmpty ? type.lowercased() : parts.joined(separator: " · ")
        }
    }
    public let id: String, identity: String, name: String, kind: String, metadata: String
    public let joinedAt: Date?
    public let tracks: [Track]
    public let state: String, region: String, version: Int
    public let attributes: [String: String]
    /// Grants that are on, such as "canPublish", in the CLI's order.
    public let permissions: [String]
    public let raw: JSONValue
    public init?(json: JSONValue) {
        guard !json.text("identity").isEmpty else { return nil }
        identity = json.text("identity"); id = json.text("sid").isEmpty ? identity : json.text("sid")
        name = json.text("name"); kind = json.text("kind").isEmpty ? "STANDARD" : json.text("kind")
        metadata = json.text("metadata"); joinedAt = json.field("joinedAt")?.double.map { Date(timeIntervalSince1970: $0) }
        tracks = (json["tracks"]?.array ?? []).compactMap(Track.init)
        state = json.text("state"); region = json.text("region"); version = Int(json.field("version")?.double ?? 0)
        attributes = (json.field("attributes")?.object ?? [:]).compactMapValues(\.string)
        permissions = (json.field("permission")?.object ?? [:]).filter { $0.value.bool == true }.map(\.key).sorted()
        raw = json
    }
    /// The agent's state attribute (listening, thinking, speaking), set by LiveKit Agents.
    public var agentState: String? { attributes["lk.agent.state"] }

    /// lk 2.19.4 prints `identity (STATE)\t tracks: N`, not JSON. Match the suffix,
    /// so spaces and parentheses inside an identity are retained. Refuse malformed output.
    public static func identities(_ text: String) throws -> [String] {
        try text.split(separator: "\n").map { line in
            guard let suffix = line.range(of: #" \([A-Z_]+\)\s+tracks: \d+\s*$"#, options: .regularExpression) else {
                throw LiveKitCLIError(kind: .failed, message: "The CLI participant list has an unsupported format. Update Observer or inspect this room in the dashboard.")
            }
            return String(line[..<suffix.lowerBound])
        }
    }
}

