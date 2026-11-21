import AVFoundation
import Foundation
import Testing
@testable import LiveKitObserver

@Suite struct PhaseTwoIntegrationTests {
    @Test func mediaEvictionPreservesLeasedFilesAndDurableData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(), lease = UUID()
        let paths = ["livekit/old.ogg", "livekit/old.ogg.ch0.caf", "livekit/current.ogg", "attachments/evidence.pcap", "review.json"]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
        }
        await cache.pin([root.appendingPathComponent("livekit/current.ogg")], lease: lease)
        try await cache.prune(root: root, limits: .init(recordings: 100, decoded: 0))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(paths[0]).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(paths[1]).path))
        for path in paths.dropFirst(2) { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
    }
    @Test func deepLinksRejectAmbiguousOrExternalTargets() throws {
        let link = try #require(SessionLink(project: "p_one", session: "RM_two"))
        #expect(SessionLink(url: link.url) == link)
        for text in ["https://project/p_one/session/RM_two", "livekit-observer://project/p_one/session/RM_two?secret=x", "livekit-observer://project/p_one/session/../RM_two", "livekit-observer://project/p_one/session/RM_two/extra", "livekit-observer://project/other/session/RM_two"] {
            #expect(SessionLink(url: URL(string: text)!) == nil)
        }
    }

    @Test @MainActor func separateWindowsHaveIndependentProjectAndSelection() {
        let a = AppModel(project: "p_a"), b = AppModel(project: "p_b")
        a.filter = "one"; b.filter = "two"
        #expect(a.project == "p_a" && b.project == "p_b")
        #expect(a.filter == "one" && b.filter == "two")
        a.operations.configure(cli: nil, projectID: "p_a")
        a.operations.selectedAgent = "CA_a"
        #expect(b.operations.selectedAgent == nil)
    }

    @Test func workspacePagesUseProjectAsPartOfTheBookmarkAndCostsRemainPartial() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("index.sqlite"))
        let now = ISODate.parse("2026-11-21T12:00:00Z")!
        let query = SessionQuery(days: 30, now: now)
        let items = (0..<75).map { ["sessionId": "RM_\($0)", "startedAt": "2026-11-20T12:00:00Z", "roomName": "test"] }
        let page = try SessionPage(json: JSONValue(any: ["items": items]))
        for project in ["p_a", "p_b", "p_c"] { try await store.ingest(page, project: project, scope: project, query: query) }
        let first = try await store.workspacePage(projects: ["p_a", "p_b"], query: query)
        let second = try await store.workspacePage(projects: ["p_a", "p_b"], query: query, after: first.last)
        #expect(first.count == 100 && second.count == 50)
        #expect(Set((first + second).map(\.id)).count == 150)
        #expect(!first.contains { $0.project == "p_c" })
        #expect(try await store.costs(projects: ["p_a"], since: "2026-11-01").isEmpty)
        try await store.saveCost(project: "p_a", id: "RM_1", date: now, estimate: 0.12, partial: true)
        try await store.saveCost(project: "p_b", id: "RM_1", date: now, estimate: 10, partial: false)
        try await store.saveCost(project: "p_a", id: "RM_1", date: now, estimate: 0.2, partial: false)
        let cost = try #require(try await store.costs(projects: ["p_a"], since: "2026-11-01").first)
        #expect(cost.reviewed == 1 && cost.partial == 0 && cost.estimate == 0.2)
    }

    @Test func audioConversionResamplesAndBoundsClips() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("source.wav")
        try AudioClip.wav(Data(repeating: 0, count: 48000 * 2 * 2), sampleRate: 48000).write(to: wav)
        let converted = try await AudioClip.pcm(url: wav, start: 0.5, duration: 1)
        #expect(abs(converted.count - 32000) <= 64)
        let trimmed = try await AudioClip.pcm(url: wav, start: 1.5, duration: 2)
        #expect(abs(trimmed.count - 16000) <= 64)
        for range in [(start: -1.0, duration: 1.0), (start: 3.0, duration: 1.0), (start: Double.greatestFiniteMagnitude, duration: 1.0), (start: 0.0, duration: 121.0)] {
            await #expect(throws: (any Error).self) { _ = try await AudioClip.pcm(url: wav, start: range.start, duration: range.duration) }
        }
        let file = try AVAudioFile(forReading: wav)
        #expect(file.length == 96000 && file.processingFormat.channelCount == 1)
    }

    @Test func audioResultsAreDurableScopedAndCannotEscapeTheirStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AudioAIStore(root: folder)
        try await store.save(project: "p_a", session: "RM_one", data: Data("[]".utf8), name: "transcription-comparison.json")
        #expect(try await AudioAIStore(root: folder).load(project: "p_a", session: "RM_one", name: "transcription-comparison.json") == Data("[]".utf8))
        #expect(try await store.load(project: "p_b", session: "RM_one", name: "transcription-comparison.json") == nil)
        await #expect(throws: (any Error).self) { try await store.save(project: "p_a", session: "RM_one", data: Data(), name: "../escape") }
    }

    @Test func streamingInferenceHandlesUTF8UsageAndRejectsTruncation() throws {
        let stream = "event: message\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"héllo\"}}]}\r\n\r\ndata: {\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":5}}\n\ndata: [DONE]\n"
        var decoder = InferenceStreamDecoder()
        for byte in stream.utf8 { try decoder.append(byte) }
        try decoder.validate()
        #expect(decoder.text == "héllo" && decoder.inputTokens == 42 && decoder.outputTokens == 5)
        var invalid = InferenceStreamDecoder()
        for byte in "data: {\"usage\":{\"prompt_tokens\":1e100,\"completion_tokens\":-5}}\n".utf8 { try invalid.append(byte) }
        #expect(invalid.inputTokens == nil && invalid.outputTokens == nil)
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) {
            var oversized = InferenceStreamDecoder()
            for byte in String(repeating: "x", count: 70000).utf8 { try oversized.append(byte) }
        }
    }

    @Test func aiScenarioCannotInventExecutableState() throws {
        let draft = try ScenarioDraft.fromAI(#"{"label":"Changed date","instructions":"Ask to move a booking","agent_expectations":"Confirm the updated date","userdata":{"secret":"ignored"}}"#)
        #expect(draft.userdata == "{}")
        #expect(throws: (any Error).self) { try ScenarioDraft.fromAI(#"{"label":"x","instructions":"","agent_expectations":""}"#) }
        #expect(STTSegment(json: JSONValue(any: ["transcript": "hello", "start": -1, "duration": 2])) == nil)
        #expect(TranscriptionComparison.normalized("Hello, WORLD!") == "hello world")
    }

    @Test func evidenceRedactsQuotedCredentialsAndPasswordsWithSpaces() {
        let text = AIReviewView.redacted(#"{"api_key":"synthetic-key", "password": "two secret words", "token": "abc\\\"def"} API_SECRET='another secret'"#)
        for secret in ["synthetic-key", "two secret words", "abc", "another secret"] { #expect(!text.contains(secret)) }
        #expect(text.contains("REDACTED"))
    }
}
