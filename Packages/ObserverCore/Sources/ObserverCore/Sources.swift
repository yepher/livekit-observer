import Foundation

public protocol InferenceTokenSource: Sendable {
    var project: String? { get }
    func inferenceToken() async throws -> String
}
public protocol AgentSource: Sendable {
    func agents() async throws -> [CloudAgent]
    func agentVersions(_ id: String) async throws -> [AgentVersion]
}
public protocol RoomSource: Sendable {
    func rooms() async throws -> [LiveRoom]
    func participants(room: String) async throws -> [LiveParticipant]
}
public protocol SimulationSource: Sendable {
    func simulationRuns(cursor: String?) async throws -> (runs: [SimulationRun], nextCursor: String?)
}

public protocol OperationsSource: AgentSource, RoomSource, SimulationSource {
    func agentSecrets(_ id: String) async throws -> [String]
    func simulation(_ id: String) async throws -> SimulationRun
    func simulationExport(_ id: String) async throws -> JSONValue
}
