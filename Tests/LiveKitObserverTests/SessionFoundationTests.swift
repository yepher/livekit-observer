import Foundation
import Testing
@testable import LiveKitObserver

private func summaryPage(_ ids: [String], cursor: String? = nil, room: String = "support", status: String = "closed", date: String = "2026-11-20T12:00:00Z", tags: [String] = []) throws -> SessionPage {
    let items: [[String: Any]] = ids.map { ["sessionId": $0, "roomName": room, "status": status, "startedAt": date, "hasDetailData": true, "tags": tags] }
    return try SessionPage(json: JSONValue(any: ["items": items, "nextCursor": cursor ?? ""]))
}

private func temporaryStore() throws -> (URL, SessionStore) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ObserverIndexTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder, SessionStore(url: folder.appendingPathComponent("index.sqlite")))
}

@Suite struct SessionIndexTests {
    private var query: SessionQuery { SessionQuery(days: 30, now: ISODate.parse("2026-11-21T12:00:00Z")!) }

    @Test func equalTimestampsDuplicatePagesAndProjectIsolation() async throws {
        let (folder, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.ingest(summaryPage(["c", "b"], cursor: "next"), project: "p_a", scope: "user:p_a", query: query)
        try await store.ingest(summaryPage(["b", "a"]), project: "p_a", scope: "user:p_a", query: query)
        try await store.ingest(summaryPage(["c"], room: "other-project"), project: "p_b", scope: "user:p_b", query: query)
        let first = try await store.page(project: "p_a", query: query, limit: 2)
        #expect(first.map { $0.row.id } == ["c", "b"])
        let second = try await store.page(project: "p_a", query: query, after: SessionBookmark(first[1].row), limit: 2)
        #expect(second.map { $0.row.id } == ["a"])
        let arrivingEarlier = try await store.page(project: "p_a", query: query, ids: ["c", "a"])
        #expect(arrivingEarlier.map { $0.row.id } == ["c", "a"])
        let isolated = try await store.page(project: "p_b", query: query)
        #expect(isolated.first?.row.roomName == "other-project")
        #expect(try await store.coverage(scope: "user:p_a", query: query)?.complete == true)
        #expect(try await store.coverage(scope: "another-user:p_a", query: query) == nil)
    }

    @Test func coverageIsScopedToFiltersAndPreservesErrors() async throws {
        let (folder, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.ingest(summaryPage(["one"], cursor: "opaque"), project: "p_a", scope: "user:p_a", query: query)
        var other = query; other.status = "active"
        #expect(try await store.coverage(scope: "user:p_a", query: other) == nil)
        var coverage = try #require(try await store.coverage(scope: "user:p_a", query: query))
        #expect(!coverage.complete)
        coverage.error = "offline"
        try await store.setCoverage(coverage, scope: "user:p_a", query: query)
        let reopened = SessionStore(url: folder.appendingPathComponent("index.sqlite"))
        #expect(try await reopened.coverage(scope: "user:p_a", query: query)?.nextCursor == "opaque")
        #expect(try await reopened.coverage(scope: "user:p_a", query: query)?.error == "offline")
        #expect(try await reopened.page(project: "p_a", query: query).count == 1)
    }

    @Test func filtersAndUnknownEnrichment() async throws {
        let (folder, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.ingest(summaryPage(["closed"], room: "support%_one", tags: [Flag.lessonTag]), project: "p", scope: "s", query: query)
        try await store.ingest(summaryPage(["live"], room: "Support-two", status: "active"), project: "p", scope: "s", query: query)
        #expect(try await store.page(project: "p", query: query, search: "support%_").map { $0.row.id } == ["closed"])
        var filtered = query; filtered.roomPrefix = "support"
        #expect(try await store.page(project: "p", query: filtered).map { $0.row.id } == ["closed"])
        filtered = query; filtered.status = "active"
        #expect(try await store.page(project: "p", query: filtered).map { $0.row.id } == ["live"])
        #expect(try await store.page(project: "p", query: query, onlyFlagged: true).map { $0.row.id } == ["closed"])
        let unknown = try #require(try await store.page(project: "p", query: query).first)
        #expect(unknown.agentName == nil && unknown.lessonFlags == nil)
        try await store.enrich(project: "p", id: "live", agent: "agent-a", lessonFlags: 0)
        #expect(try await store.page(project: "p", query: filtered).first?.lessonFlags == 0)
        try await store.setFlags(project: "p", id: "live", flagged: true, noted: false)
        #expect(try await store.page(project: "p", query: query, onlyFlagged: true).count == 2)
    }

    @Test func retentionPreservesAnnotationsAttachmentsAndLongCalls() async throws {
        let (folder, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let old = "2026-09-01T00:00:00Z"
        try await store.ingest(summaryPage(["expire", "flagged", "noted", "capture"], date: old), project: "p", scope: "s", query: query, flagged: ["flagged"], noted: ["noted"])
        try await store.ingest(summaryPage(["long"], status: "active", date: old), project: "p", scope: "s", query: query)
        let capture = CaptureSession(projectKey: "p", projectName: "Project", sessionID: "capture", roomName: "Saved call", startedAt: ISODate.parse(old), endedAt: nil)
        try await store.attach([capture], project: "p")
        try await store.prune(project: "p", before: query.start)
        let all = SessionQuery(days: 365, now: ISODate.parse("2026-11-21T12:00:00Z")!)
        #expect(Set(try await store.page(project: "p", query: all).map { $0.row.id }) == ["capture", "flagged", "noted", "long"])
        #expect(try await store.coverage(scope: "s", query: query) == nil)
        #expect(try await store.page(project: "p", query: query).contains { $0.row.localCaptureSession != nil })
    }

    @Test func recordingPagesResumeAndRemainIsolatedFromOtherBuckets() async throws {
        let (folder, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let recording = try #require(EgressRecording(manifest: JSONValue(any: ["room_id": "RM_1", "started_at": 1795176000000000000 as Int64, "files": [["filename": "audio.ogg"]]])))
        let scan = RecordingScan(cursor: "storage-cursor", objects: 2)
        try await store.saveRecordingPage(source: "bucket-a", project: "p", objects: [StorageObject(key: "audio.ogg", size: 2048)], manifests: [("call.json", recording)], scan: scan)
        #expect(try await store.recordingScan(source: "bucket-a")?.cursor == "storage-cursor")
        #expect(try await store.recordingScan(source: "bucket-b") == nil)
        #expect(try await store.hasManifest(source: "bucket-a", key: "call.json"))
        #expect(try await store.page(project: "p", query: query, onlyRecording: true, recordingSource: "bucket-a").count == 1)
        #expect(try await store.page(project: "p", query: query, onlyRecording: true, recordingSource: "bucket-b").isEmpty == true)
        #expect(try await store.page(project: "p", query: query, recordingSource: "bucket-a").first?.row.recording?.size == 2048)
    }

    @Test func boundsResidentQueriesAndRetainsAllIndexedHistory() async throws {
        let (folder, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
        for page in 0..<20 {
            try await store.ingest(summaryPage((0..<100).map { "id-\(page * 100 + $0)" }), project: "p", scope: "s", query: query)
        }
        #expect(try await store.page(project: "p", query: query, limit: 100_000).count == 1000)
        #expect(try await store.page(project: "p", query: query, search: "id-3").first?.row.id == "id-3")
    }
}

@Suite struct FoundationContractTests {
    @Test func installedCLIPageInfoEnvelope() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/session-page.json")
        let page = try SessionPage(json: JSONValue.parse(Data(contentsOf: url)))
        #expect(page.sessions.first?.id == "RM_synthetic")
        #expect(page.nextCursor == "synthetic-opaque-cursor")
        #expect(throws: (any Error).self) {
            try SessionPage(json: JSONValue(any: ["items": [], "pageInfo": ["hasMore": true]]))
        }
    }

    @Test func sessionPageRejectsMalformedDataAndKeepsCursor() throws {
        let page = try SessionPage(json: JSONValue(any: ["items": [], "nextCursor": "next"]))
        #expect(page.sessions.isEmpty && page.nextCursor == "next")
        #expect(throws: (any Error).self) { try SessionPage(json: .object(["message": .string("not a page")])) }
        #expect(throws: (any Error).self) { try SessionPage(json: JSONValue(any: ["items": [["roomName": "no-id"]]])) }
        var query = SessionQuery(days: 7, now: ISODate.parse("2026-11-21T12:00:00Z")!)
        query.roomPrefix = "x; $(bad)"; query.tag = "flagged:learner"
        #expect(query.arguments(cursor: "opaque").contains("x; $(bad)"))
        #expect(query.arguments(limit: 10000).contains("100"))
        #expect(query.startDay == "2026-11-14")
    }

    @Test func projectMetadataIgnoresSecretsAndMergesByIdentity() throws {
        let yaml = """
        default_project: old-name
        projects:
          - name: old-name
            project_id: p_1
            url: wss://app.livekit.cloud
            api_key: synthetic-key
            api_secret: synthetic-secret
        users:
          - session_token: synthetic-token
        """
        let local = try SavedProjects.decode(Data(yaml.utf8))
        let merged = ProjectRef.merged(local: local, cloud: JSONValue(any: [["id": "p_1", "name": "New name", "url": "wss://app.livekit.cloud"], ["id": "p_2", "name": "Other"]]))
        #expect(merged.count == 2)
        let linked = try #require(merged.first { $0.id == "p_1" })
        #expect(linked.lkName == "old-name" && linked.name == "New name" && linked.isDefault)
        let exported = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
        #expect(!exported.contains("synthetic"))
        #expect(try SavedProjects.decode(Data("projects: [{name: no-default}]".utf8)).first?.isDefault == false)
        do { _ = try SavedProjects.decode(Data("projects: [synthetic-secret".utf8)); Issue.record("Should reject invalid YAML") }
        catch { #expect(!error.localizedDescription.contains("synthetic-secret")) }
    }

    @Test func versionAndProjectStateBounds() throws {
        #expect(CLIVersion("lk version 2.19.4") == .minimum)
        #expect(CLIVersion("lk version 2.9.4")! < .minimum)
        #expect(CLIVersion("unknown") == nil)
        var cache = ProjectStateCache()
        for i in 0..<5 { cache.save(ProjectBrowseState(rows: [], selection: "room-\(i)", query: SessionQuery(), search: "filter", onlyFlagged: true, onlyRecording: false), for: "p_\(i)") }
        #expect(cache.count == 3 && cache.state(for: "p_0") == nil)
        #expect(cache.state(for: "p_4")?.selection == "room-4")
    }

    @Test func invalidStoragePageDoesNotFinishScan() throws {
        #expect(throws: (any Error).self) { try ListObjectsParser.checked(Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8)) }
        #expect(throws: (any Error).self) { try ListObjectsParser.checked(Data("<broken".utf8)) }
    }
}

@Suite struct WorkBudgetTests {
    @Test func processCancellationDeadlineEnvironmentAndOutputBound() async throws {
        let directory = FileManager.default.temporaryDirectory
        let result = try await CommandProcess.run(URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["OBSERVER_TEST_VALUE"], directory: directory, environment: ["OBSERVER_TEST_VALUE": "synthetic"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "synthetic\n")
        do {
            _ = try await CommandProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: directory, environment: [:], timeout: 0.05)
            Issue.record("Deadline did not stop the process")
        } catch let error as LiveKitCLIError { #expect(error.kind == .timeout) }
        let cancelled = Task { try await CommandProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: directory, environment: [:]) }
        try await Task.sleep(for: .milliseconds(30)); cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancellation did not propagate") } catch is CancellationError { }
        do {
            _ = try await CommandProcess.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: [String(repeating: "x", count: 2048)], directory: directory, environment: [:], outputLimit: 1024)
            Issue.record("Output limit did not apply")
        } catch let error as LiveKitCLIError { #expect(error.kind == .failed) }
    }

    @Test func globallyBoundsBackgroundAndForegroundJobs() async throws {
        let scheduler = WorkScheduler(limit: 4, backgroundLimit: 2, queueLimit: 100)
        actor Counts {
            var running = 0; var background = 0; var peak = 0; var backgroundPeak = 0
            func enter(_ bg: Bool) { running += 1; if bg { background += 1 }; peak = max(peak, running); backgroundPeak = max(backgroundPeak, background) }
            func leave(_ bg: Bool) { running -= 1; if bg { background -= 1 } }
        }
        let counts = Counts()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let background = i % 2 == 0
                    try await scheduler.perform(project: "p\(i % 3)", priority: background ? .background : .interactive) {
                        await counts.enter(background)
                        try await Task.sleep(for: .milliseconds(5))
                        await counts.leave(background)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await counts.peak <= 4)
        #expect(await counts.backgroundPeak <= 2)
        #expect(await scheduler.snapshot().running == 0)
    }

    @Test func cancellingQueuedWorkReleasesWaiters() async throws {
        let scheduler = WorkScheduler(limit: 1, backgroundLimit: 1)
        let first = Task { try await scheduler.perform(project: "a") { try await Task.sleep(for: .milliseconds(100)) } }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task { try await scheduler.perform(project: "b") { _ = Issue.record("Cancelled queued work ran") } }
        try await Task.sleep(for: .milliseconds(10)); second.cancel()
        do { try await second.value; Issue.record("Missing cancellation") } catch is CancellationError { }
        try await first.value
        #expect(await scheduler.snapshot().queued == 0)
    }

    @Test func coalescesReadsAndCancelsOnlyTheLastConsumer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ObserverBrokerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("started")
        let request = CommandBroker.Request(executable: URL(fileURLWithPath: "/bin/sh"),
                                            arguments: ["-c", "printf x >> \"$1\"; exec /bin/sleep 0.2", "test", marker.path],
                                            directory: folder, environment: [:], timeout: 3, nonce: nil)
        let broker = CommandBroker()
        let first = Task { try await broker.run(request, project: "p", priority: .interactive) }
        let second = Task { try await broker.run(request, project: "p", priority: .interactive) }
        try await Task.sleep(for: .milliseconds(30)); first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled subscriber should stop waiting") } catch is CancellationError { }
        #expect(try await second.value.status == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }
}
