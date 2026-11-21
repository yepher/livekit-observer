import Foundation
import ObserverCore

extension LiveKitCLI: InferenceTokenSource, OperationsSource {
    func inferenceToken() async throws -> String {
        let data = try await operation(["token", "create", "--inference", "--identity", "agent", "--valid-for", "10m", "--token-only"], json: false)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func simulation(_ id: String) async throws -> SimulationRun {
        let json = try await operationJSON(["agent", "simulate", "get", id, "--json"])
        guard let run = SimulationRun(json: json) else { throw LiveKitCLIError(kind: .failed, message: "The CLI returned an unsupported simulation response.") }
        return run
    }
    func simulationExport(_ id: String) async throws -> JSONValue {
        try await operationJSON(["agent", "simulate", "export", id])
    }
    func simulationRuns(cursor: String?) async throws -> (runs: [SimulationRun], nextCursor: String?) {
        let json = try await operationJSON(["agent", "simulate", "list", "--json"] + (cursor.map { ["--cursor", $0] } ?? []))
        return (json.items.compactMap(SimulationRun.init), (json["pageInfo"] ?? json)["nextCursor"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }
}
