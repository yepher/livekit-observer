import Foundation
import Testing
import SQLite3
import ObserverCore

private struct FixtureSource: SessionSource {
    func sessionPage(query: SessionQuery, cursor: String?) async throws -> SessionPage { try SessionPage(json: .object(["items": .array([])])) }
    func resource(_ id: String, kind: SessionResource) async throws -> SessionResourceDocument {
        if kind == .logs { throw LiveKitCLIError(kind: .notReady, message: "Still settling") }
        return .init(kind: kind, json: JSONValue(any: ["dataStatus": ["state": "DATA_STATE_SETTLED"], "items": []]))
    }
}

@Suite struct RemainingFeaturesTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @Test func resourceFailuresStayIndependent() async throws {
        let result = await SessionResources.load(source: FixtureSource(), id: "RM_one")
        #expect(result.count == 5)
        #expect(try result[.transcript]?.get().readiness.state == .settled)
        guard case .failure(let error) = result[.logs] else { Issue.record("Expected pending logs"); return }
        #expect(ResourceReadiness(error: error).state == .pending)
        #expect(try result[.metrics]?.get().readiness.state == .settled)
    }
    @Test func summarySettlementUsesReportedSessionStatus() {
        let closed = SessionResourceDocument(kind: .summary, json: JSONValue(any: ["session": ["sessionId": "RM_one", "status": "SESSION_STATUS_CLOSED"]]))
        let active = SessionResourceDocument(kind: .summary, json: JSONValue(any: ["sessionId": "RM_one", "status": "SESSION_STATUS_ACTIVE"]))
        #expect(closed.readiness.state == .settled && !closed.readiness.shouldRetry)
        #expect(active.readiness.state == .pending)
    }

    @Test func truncatedResourcesRemainPending() {
        let value = ResourceReadiness(json: JSONValue(any: ["dataStatus": ["state": "settled"], "pageInfo": ["nextCursor": "more"]]))
        #expect(value.state == .pending && value.shouldRetry)
        #expect(ResourceReadiness(error: LiveKitCLIError(kind: .forbidden, message: "Forbidden")).state == .unavailable)
    }
    @Test func readinessSurvivesReopenAndRetriesAreBoundedAndScoped() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.sqlite"), store = SessionStore(url: path), date = Date(timeIntervalSince1970: 1000)
        for i in 0..<12 { try await store.recordResource(project: "p_a", id: "RM_\(i)", kind: .logs, readiness: .init(state: .pending, checkedAt: date)) }
        try await store.recordResource(project: "p_a", id: "RM_0", kind: .transcript, readiness: .init(state: .settled, checkedAt: date))
        try await store.recordResource(project: "p_b", id: "RM_other", kind: .logs, readiness: .init(state: .failed, checkedAt: date))
        let reopened = SessionStore(url: path)
        #expect(try await reopened.pendingResources(project: "p_a", now: date).isEmpty)
        let retry = try await reopened.pendingResources(project: "p_a", now: date.addingTimeInterval(70), limit: 100)
        #expect(retry.count == 8 && retry.allSatisfy { $0.kind == .logs })
        #expect(try await reopened.resourceStates(project: "p_a", id: "RM_0")[.transcript]?.state == .settled)
        #expect(try await reopened.pendingResources(project: "p_b", now: date.addingTimeInterval(70)).isEmpty)
    }
    @Test func durableNotesRecoverAfterIndexRebuildWithoutGuessingProject() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let annotations = AnnotationStore(root: root.appendingPathComponent("notes"))
        let session = CaptureSession(projectKey: "p_a", projectName: "A", sessionID: "RM_known", roomName: "old room", startedAt: Date(timeIntervalSince1970: 1))
        try await annotations.save(.init(project: "p_a", session: session, flagged: true, noted: true))
        let refs = try await annotations.recoverLegacy(flagged: ["RM_known", "RM_legacy"], notes: [:])
        #expect(refs.count == 2)
        #expect(refs.first { $0.session.sessionID == "RM_legacy" }?.project == AnnotationStore.unassigned)
        let store = SessionStore(url: root.appendingPathComponent("rebuilt.sqlite"))
        try await store.restoreAnnotations(refs)
        let queue = try await store.workspacePage(projects: ["p_a", AnnotationStore.unassigned], query: SessionQuery(), onlyFlagged: true)
        #expect(Set(queue.map { $0.row.id }) == ["RM_known", "RM_legacy"])
        #expect(try await store.workspacePage(projects: ["p_b"], query: SessionQuery(), onlyFlagged: true).isEmpty)
    }
    @Test func oneCorruptAnnotationDoesNotHideOtherNotes() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let annotations = AnnotationStore(root: root)
        try await annotations.save(.init(project: "p_a", session: .init(projectKey: "p_a", projectName: "A", sessionID: "RM_1", roomName: "Room"), flagged: true, noted: false))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("broken.json"))
        #expect(try await annotations.references().count == 1)
    }
    @Test func alignmentHandlesInsertionDeletionAndPunctuation() throws {
        #expect(try #require(WordAlignment.align(original: "Hello, world!", alternative: "hello world")).allSatisfy { !$0.differs })
        let inserted = try #require(WordAlignment.align(original: "book Friday", alternative: "book next Friday"))
        #expect(inserted.filter(\.differs) == [AlignedWord(original: nil, alternative: "next")])
        let deleted = try #require(WordAlignment.align(original: "book next Friday", alternative: "book Friday"))
        #expect(deleted.filter(\.differs) == [AlignedWord(original: "next", alternative: nil)])
        #expect(WordAlignment.align(original: String(repeating: "x ", count: 513), alternative: "x") == nil)
    }
    @Test func wordTimingIsValidatedAndConfidenceIsNotInvented() throws {
        #expect(STTSegment.Word(json: JSONValue(any: ["word": "bad", "start": -1, "end": 1])) == nil)
        #expect(STTSegment.Word(json: JSONValue(any: ["word": "bad", "start": 1, "end": 121])) == nil)
        let word = try #require(STTSegment.Word(json: JSONValue(any: ["word": "hello", "start": 0, "end": 1, "confidence": 9])))
        #expect(word.confidence == nil)
    }
    private func turn(_ text: String, start: Double, end: Double, index: Int = 0) -> TranscriptItem {
        TranscriptItem(json: JSONValue(any: ["message": ["role": "user", "text": text, "startedSpeakingAt": Date(timeIntervalSince1970: start).ISO8601Format(), "stoppedSpeakingAt": Date(timeIntervalSince1970: end).ISO8601Format()]]), index: index)
    }
    @Test func clippedTurnsAndOverlapsDoNotProduceFalseWordComparisons() throws {
        let segment = try #require(STTSegment(json: JSONValue(any: ["transcript": "Monday", "start": 1, "duration": 1, "words": [["word": "Monday", "start": 1, "end": 2, "confidence": 0.9]]])))
        let comparisons = TranscriptionComparison.aligned(segments: [segment], transcript: [turn("Friday", start: 100, end: 103), turn("Friday", start: 100, end: 103, index: 1)], origin: Date(timeIntervalSince1970: 100), clipStart: 0, clipDuration: 5, model: "fixture")
        #expect(comparisons.count == 1 && comparisons[0].differs && comparisons[0].confidence == 0.9)
        let clipped = TranscriptionComparison.aligned(segments: [segment], transcript: [turn("next Friday", start: 99, end: 103)], origin: Date(timeIntervalSince1970: 100), clipStart: 0, clipDuration: 5, model: "fixture")
        #expect(clipped.isEmpty)
    }
    @Test func numericUsageRepricesWithoutLosingIncompleteStatus() throws {
        let lines = [CostLine(group: .inference, item: "LLM", quantity: "2M tokens", rate: "old", cost: 0.8, usage: .init(rate: .inputTokens, amount: 2, model: "openai/gpt-4.1-mini"), incomplete: true)]
        let snapshot = CostUsageSnapshot(date: .now, planID: "old", lines: lines, resourcesComplete: true)
        var plan = PricePlan.scale; plan.inference = [.init(model: "openai/gpt-4.1-mini", unit: .inputTokens, price: 3)]
        let updated = snapshot.repriced(plan: plan, priceDate: .now)
        #expect(updated.estimate == 6 && updated.partial)
        #expect(updated.repriced(plan: plan, priceDate: .now).estimate == 6)
        plan.inference = []
        #expect(snapshot.repriced(plan: plan, priceDate: nil).lines[0].cost == nil)
    }
    @Test func costUsageAndResumeCursorAreDurableAndProjectScoped() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.sqlite"), store = SessionStore(url: path)
        let usage = CostUsageSnapshot(date: .now, planID: "Scale", lines: [], resourcesComplete: false)
        try await store.saveCostUsage(project: "p_a", id: "RM_one", usage: usage)
        try await store.saveHistoryProgress(project: "p_a", progress: .init(bookmark: .init(startedAt: 42, id: "RM_one"), completed: 5, repricing: true))
        let reopened = SessionStore(url: path)
        #expect(try await reopened.costUsage(project: "p_a", id: "RM_one")?.partial == true)
        #expect(try await reopened.costUsage(project: "p_b", id: "RM_one") == nil)
        #expect(try await reopened.historyProgress(project: "p_a")?.completed == 5)
        #expect(try await reopened.historyProgress(project: "p_a")?.repricing == true)
    }
    @Test func aiChargesRemainScopedAndReservationsStayVisible() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AIReviewStore(directory: root)
        let charge = try await ledger.reserve(project: "p_a", amount: 0.2, limit: 2, session: "RM_1", feature: "Diagnosis")
        _ = try await ledger.reserve(project: "p_a", amount: 0.3, limit: 2, session: "RM_1", feature: "Transcription")
        _ = try await ledger.reserve(project: "p_b", amount: 1, limit: 2, session: "RM_1", feature: "Diagnosis")
        try await ledger.settle(charge, cost: 0.1)
        let costs = try await AIReviewStore(directory: root).sessionCosts(project: "p_a", session: "RM_1")
        #expect(costs.count == 2)
        #expect(costs.first { $0.item == "Diagnosis" }?.incomplete == false)
        #expect(costs.first { $0.item == "Transcription" }?.incomplete == true)
        #expect(costs.compactMap(\.cost).reduce(0, +) == 0.4)
    }
    @Test func modelMetadataAndLegacyAISettingsDecode() throws {
        let models = InferenceModels.parse("| Old | `vendor/old` | DEPRECATED: retires January 1, 2020 | ✓ |\n| Gone | `vendor/gone` | RETIRED | |")
        #expect(models["vendor/old"]?.isRetired() == true && models["vendor/old"]?.eu == true)
        #expect(models["vendor/gone"]?.isRetired() == true)
        #expect(InferenceModels.bundled().count >= 100)
        let old = try JSONDecoder().decode(AISettings.self, from: Data(#"{"enabled":true,"model":"fixture","monthlyLimit":5,"lowPriority":true}"#.utf8))
        #expect(old.enabled && old.model == "fixture")
    }
    @Test func missingLLMUsageIsPartialAfterRepricing() {
        let span = Span(json: JSONValue(any: ["name": "llm_request", "attributes": ["gen_ai.request.model": "openai/gpt-4.1-mini", "gen_ai.provider.name": "livekit"]]), index: 0)
        let lines = SessionCost.lines(plan: .scale, room: nil, spans: [span], metrics: [], logs: [], transcriptItems: 0, noiseCancellation: false).filter { $0.group == .inference }
        #expect(lines.count == 2 && lines.allSatisfy(\.incomplete))
        let usage = CostUsageSnapshot(date: .now, planID: "Scale", lines: lines, resourcesComplete: true)
        #expect(usage.repriced(plan: .scale, priceDate: .now).partial)
    }

    @Test func reviewIndexMigratesLegacyTagsAndUpdatesWithAnnotations() async throws {
        let root = folder(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("legacy.sqlite")
        var db: OpaquePointer?; #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE sessions(project TEXT NOT NULL,id TEXT NOT NULL,started REAL NOT NULL,room TEXT NOT NULL,status TEXT NOT NULL,summary BLOB,recording BLOB,recording_source TEXT,attachment BLOB,fetched REAL NOT NULL DEFAULT 0,agent TEXT,lesson_flags INTEGER,flagged INTEGER NOT NULL DEFAULT 0,noted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(project,id));
        CREATE TABLE tags(project TEXT NOT NULL,id TEXT NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(project,id,tag));
        INSERT INTO sessions(project,id,started,room,status) VALUES('p_a','RM_old',0,'Old','closed');
        INSERT INTO tags VALUES('p_a','RM_old','flagged:learner');
        PRAGMA user_version=4;
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
        let store = SessionStore(url: path), query = SessionQuery(days: 50000)
        #expect(try await store.page(project: "p_a", query: query, onlyFlagged: true).count == 1)
        let replacement = try #require(LiveKitSession(json: JSONValue(any: ["sessionId": "RM_old", "roomName": "Old", "startedAt": "2026-11-21T12:00:00Z"])))
        try await store.upsert(replacement, project: "p_a")
        #expect(try await store.page(project: "p_a", query: query, onlyFlagged: true).isEmpty)
        try await store.setFlags(project: "p_a", id: "RM_old", flagged: false, noted: true)
        #expect(try await store.workspacePage(projects: ["p_a"], query: query, onlyFlagged: true).count == 1)
    }

    @Test func multipleAgentsCannotBeLinkedToOneUnrelatedVersion() {
        let first = Span(json: JSONValue(any: ["attributes": ["lk.cloud_agent_id": "CA_one"]]), index: 0)
        let second = Span(json: JSONValue(any: ["attributes": ["lk.cloud_agent_id": "CA_two", "observer.agent_version": "v2"]]), index: 1)
        let evidence = AgentProvenance(logs: [], spans: [first, second])
        #expect(evidence.agentIDs.count == 2 && evidence.agentID == nil && evidence.version == nil)
    }

    @Test func provenanceUsesOnlyRecordedEvidence() {
        let span = Span(json: JSONValue(any: ["spanId": "tts", "name": "tts_request", "startTime": "2026-11-21T12:00:00Z", "endTime": "2026-11-21T12:00:01Z", "attributes": ["gen_ai.request.model": "cartesia/sonic-3", "observer.tts.voice": "voice-a", "lk.cloud_agent_id": "CA_one", "observer.agent_version": "immutable-1"]]), index: 0)
        let at = ISODate.parse("2026-11-21T12:00:00Z")!
        let tts = TTSProvenance.find(at: at, spans: [span])
        #expect(tts.model == "cartesia/sonic-3" && tts.voice == "voice-a" && tts.evidenceID == "tts")
        #expect(TTSProvenance.find(at: at.addingTimeInterval(20), spans: [span]).voice == nil)
        #expect(AgentProvenance(logs: [], spans: [span]).version == "immutable-1")
        #expect(AgentProvenance(logs: [], spans: []).version == nil)
    }
}
