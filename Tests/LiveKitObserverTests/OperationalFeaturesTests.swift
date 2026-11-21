import Foundation
import Testing
import Yams
@testable import LiveKitObserver

@Suite struct OperationalFeaturesTests {
    @Test func aiFindingsRejectInventedEvidence() throws {
        let evidence = [AIEvidence(id: "turn-1", kind: "user", text: "Book Tuesday", date: .now)]
        let (summary, findings) = try AIReviewResult.findings(from: #"{"summary":"Review","findings":[{"explanation":"Check booking","evidenceIDs":["turn-1"]}]}"#, evidence: evidence)
        #expect(summary == "Review" && findings.count == 1 && findings[0].decision == nil)
        #expect(throws: (any Error).self) { try AIReviewResult.findings(from: #"{"summary":"Review","findings":[{"explanation":"Invented","evidenceIDs":["missing"]}]}"#, evidence: evidence) }
        #expect(throws: (any Error).self) { try AIReviewResult.findings(from: #"{"summary":"Review","findings":[{"explanation":"No evidence","evidenceIDs":[]}]}"#, evidence: evidence) }
    }

    @Test func aiBudgetReservationsSurviveRestartAndStayProjectScoped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AIReviewStore(directory: folder)
        let id = try await store.reserve(project: "a", amount: 0.75, limit: 1)
        await #expect(throws: (any Error).self) { try await store.reserve(project: "a", amount: 0.5, limit: 1) }
        #expect(try await store.spent(project: "b") == 0)
        try await store.settle(id, cost: 0.2)
        let reopened = AIReviewStore(directory: folder)
        #expect(try await reopened.spent(project: "a") == 0.2)
        await #expect(throws: (any Error).self) { try await reopened.reserve(project: "a", amount: .nan, limit: 1) }
    }

    @Test @MainActor func aiPreviewRedactsObviousCredentials() {
        let redacted = AIReviewView.redacted("Bearer abc.def.ghi api_key=secret password: hidden hello")
        #expect(!redacted.contains("abc.def") && !redacted.contains("=secret") && !redacted.contains("hidden"))
        #expect(redacted.contains("hello"))
    }

    @Test func agentDeploymentAndVersionDecoding() throws {
        let json = try JSONValue.parse(Data(#"{"agents":[{"agentId":"CA_synthetic","agentName":"support","version":"v42","agentDeployments":[{"region":"us-east","status":"Running","replicas":2,"version":"v42"}],"deployedAt":"2026-11-20T12:00:00Z"}]}"#.utf8))
        let agent = try #require(CloudAgent(json: json["agents"]!.array![0]))
        #expect(agent.healthy && agent.deployments.first?.replicas == 2)
        #expect(agent.id == "CA_synthetic" && agent.version == "v42")
        let unknown = try #require(CloudAgent(json: JSONValue(any: ["agentId": "CA_no_status"])))
        #expect(!unknown.healthy && unknown.status == "Unknown")
        let version = try #require(AgentVersion(json: JSONValue(any: ["version": "v41", "active": true, "attributes": ["git_commit": "abc"]])))
        #expect(!version.current && version.active && version.attributes["git_commit"] == "abc")
    }

    @Test func simulationAPIAndExportUseDifferentCasing() throws {
        let source: [String: Any] = ["id": "SIM_test", "agentName": "support", "status": "STATUS_COMPLETED", "mode": "SIMULATION_MODE_TEXT", "passedCount": 0, "jobs": [["id": "job-1", "scenarioId": "SCN_a", "status": "STATUS_FAILED", "agentExpectations": "Remember date", "error": "Asked twice"]]]
        let run = try #require(SimulationRun(json: JSONValue(any: source)))
        #expect(run.finished && run.passed == 0 && run.failed == nil)
        #expect(run.jobs.first?.expectations == "Remember date")
        let exported = try #require(SimulationRun(json: JSONValue(any: ["run": ["id": "SIM_test", "agent_name": "support", "status": "STATUS_COMPLETED", "jobs": [["id": "job-1", "scenario_id": "SCN_a", "agent_expectations": "Remember date"]]]])))
        #expect(exported.agentName == "support" && exported.jobs.first?.scenarioID == "SCN_a")
    }

    @Test func participantIdentityParsingDoesNotSplitNames() throws {
        #expect(try LiveParticipant.identities("alice (mobile) (ACTIVE)\t tracks: 2\nBob Smith (JOINED)\t tracks: 0\n") == ["alice (mobile)", "Bob Smith"])
        #expect(try LiveParticipant.identities("").isEmpty)
        #expect(throws: (any Error).self) { try LiveParticipant.identities("unexpected output") }
        let participant = try #require(LiveParticipant(json: JSONValue(any: ["identity": "alice", "sid": "PA_1", "tracks": [["sid": "TR_1", "type": "AUDIO", "muted": true]]])))
        #expect(participant.kind == "STANDARD" && participant.tracks.first?.muted == true)
    }

    @Test func mutationRequestsAreNeverClassifiedAsReads() {
        for args in [["agent", "restart", "--id", "list"], ["agent", "rollback", "--id", "get", "--version", "list"], ["room", "participants", "remove", "--identity", "get"], ["agent", "simulate", "cancel", "list"], ["token", "create", "--inference"]] {
            #expect(!LiveKitCLI.isReadOnly(["--project", "analytics", "--user-auth", "--yes"] + args))
        }
        #expect(LiveKitCLI.isReadOnly(["--project", "p_a", "--user-auth", "agent", "simulate", "get", "SIM_1"]))
        #expect(LiveKitCLI.isReadOnly(["--project", "p_a", "room", "participants", "get", "--identity", "alice"]))
    }

    @Test func scenarioAppendPreservesCommentsAndBacksUpOriginal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scenarios.yaml")
        let original = "# team scenarios\nid: SCNG_test\nname: tests\nscenarios:\n  # keep this comment\n  - id: SCN_existing\n    label: first\n    instructions: call\n    agent_expectations: help\nother: keep\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        var draft = ScenarioDraft(); draft.label = "Second"; draft.instructions = "Ask for a date\nThen change it"; draft.expectations = "Use the new date"; draft.userdata = #"{"plan":"pro","nested":{"value":1}}"#
        let result = try await ScenarioWriter.shared.save(draft, to: file)
        #expect(result == file)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("# keep this comment") && written.contains("other: keep"))
        let parsed = try #require(try Yams.load(yaml: written) as? [String: Any])
        let rows = try #require(parsed["scenarios"] as? [[String: Any]])
        #expect(rows.count == 2 && rows[1]["instructions"] as? String == draft.instructions)
        #expect(try String(contentsOf: file.appendingPathExtension("observer-backup"), encoding: .utf8) == original)
    }

    @Test func complexScenarioFileGetsSiblingWithoutOverwrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scenarios.yaml")
        let original = "id: SCNG_test\nscenarios: [] # keep\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        var draft = ScenarioDraft(); draft.label = "Test"; draft.instructions = "Call"; draft.expectations = "Answer"
        let result = try await ScenarioWriter.shared.save(draft, to: file)
        #expect(result != file && result.deletingLastPathComponent().path == folder.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func rerunRetainsSeedStateAndDeduplicatesSamples() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let job: [String: Any] = ["id": "job-1", "scenarioId": "SCN_one", "instructions": "Call", "agentExpectations": "Answer", "status": "STATUS_FAILED"]
        var second = job; second["id"] = "job-2"
        let run = try #require(SimulationRun(json: JSONValue(any: ["id": "SIM_run", "jobs": [job, second], "scenarioGroup": ["id": "SCNG_test", "scenarios": [["id": "SCN_one", "tags": ["flow": "booking"], "userdata": "{\"name\":\"Sam\"}"]]]])))
        let (file, count) = try await ScenarioWriter.shared.rerunFile(run, failedOnly: true, directory: folder)
        #expect(count == 1)
        let document = try #require(try Yams.load(yaml: String(contentsOf: file, encoding: .utf8)) as? [String: Any])
        let scenarios = try #require(document["scenarios"] as? [[String: Any]])
        #expect((scenarios[0]["userdata"] as? [String: String])?["name"] == "Sam")
        #expect((scenarios[0]["tags"] as? [String: String])?["flow"] == "booking")
    }
}
