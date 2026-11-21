import ObserverCore
import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions", simulations = "Simulations", agents = "Agents", rooms = "Rooms"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .sessions: "waveform"; case .simulations: "checklist"; case .agents: "person.wave.2"; case .rooms: "dot.radiowaves.left.and.right" }
    }
}

extension LiveKitCLI {
    /// Verified against installed lk 2.19.4. All operations explicitly select the project.
    func operation(_ arguments: [String], json: Bool = true, timeout: TimeInterval = 60) async throws -> Data {
        guard let project, !project.isEmpty else { throw LiveKitCLIError(kind: .projectNotFound, message: "Choose a project first.") }
        let result = try await Self.execute(executable, ["--project", project, "--user-auth", "--yes"] + arguments,
                                            in: Self.workingDirectory, priority: priority, timeout: timeout)
        guard result.status == 0 else {
            let detail = String(decoding: result.stderr.prefix(8000), as: UTF8.self)
            throw LiveKitCLIError(kind: detail.contains("403") || detail.localizedCaseInsensitiveContains("permission") ? .forbidden : .failed,
                                 message: detail.isEmpty ? "The CLI operation failed (\(result.status))." : detail)
        }
        return result.stdout
    }
    func operationJSON(_ arguments: [String]) async throws -> JSONValue { try await JSONValue.parse(operation(arguments)) }
    func agents() async throws -> [CloudAgent] {
        try await operationJSON(["agent", "list", "--json"])["agents"]?.array?.compactMap(CloudAgent.init) ?? []
    }
    func agentVersions(_ id: String) async throws -> [AgentVersion] {
        try await operationJSON(["agent", "versions", "--id", id, "--json"])["versions"]?.array?.compactMap(AgentVersion.init) ?? []
    }
    func agentSecrets(_ id: String) async throws -> [String] {
        // Only names leave this method; values are never retained or displayed.
        try await operationJSON(["agent", "secrets", "--id", id, "--json"])["secrets"]?.array?.compactMap { $0["name"]?.string }.sorted() ?? []
    }
    func rooms() async throws -> [LiveRoom] {
        try await operationJSON(["room", "list", "--json"])["rooms"]?.array?.compactMap(LiveRoom.init) ?? []
    }
    func participants(room: String) async throws -> [LiveParticipant] {
        let data = try await operation(["room", "participants", "list", room], json: false)
        let names = try LiveParticipant.identities(String(decoding: data, as: UTF8.self))
        guard names.count <= 100 else { throw LiveKitCLIError(kind: .busy, message: "This room has over 100 participants. Open the dashboard to inspect the full room.") }
        var participants: [LiveParticipant] = []
        // Small batches avoid filling the shared CLI queue for a large room.
        for start in stride(from: 0, to: names.count, by: 2) {
            try Task.checkCancellation()
            let batch = names[start..<min(start + 2, names.count)]
            let values = try await withThrowingTaskGroup(of: LiveParticipant?.self) { group in
                for name in batch { group.addTask { try await LiveParticipant(json: self.operationJSON(["room", "participants", "get", "--room", room, "--identity", name])) } }
                var values: [LiveParticipant] = []
                for try await value in group { if let value { values.append(value) } }; return values
            }
            participants += values
        }
        return participants.sorted { $0.identity < $1.identity }
    }
}
