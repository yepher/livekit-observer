import Foundation
import SQLite3

public struct SessionQuery: Codable, Hashable, Sendable {
    public var startDay: String
    public var endDay: String? = nil
    public var status = ""
    public var roomPrefix = ""
    public var tag = ""

    public init(days: Int = 30, now: Date = Date()) {
        startDay = Self.day(now.addingTimeInterval(-Double(days) * 86400))
    }

    public static func day(_ date: Date) -> String { String(date.ISO8601Format().prefix(10)) }
    public var key: String { String(decoding: (try? JSONEncoder.sorted.encode(self)) ?? Data(), as: UTF8.self) }
    public var start: Date { ISODate.parse(startDay + "T00:00:00Z") ?? .distantPast }
    public var end: Date? { endDay.flatMap { ISODate.parse($0 + "T00:00:00Z") } }

    public func arguments(cursor: String? = nil, limit: Int = 100) -> [String] {
        var args = ["session", "list", "--start", startDay, "--limit", String(max(1, min(limit, 100))), "--sort-order", "desc"]
        if let endDay { args += ["--end", endDay] }
        if !status.isEmpty { args += ["--status", status] }
        if !roomPrefix.isEmpty { args += ["--room", roomPrefix] }
        if !tag.isEmpty { args += ["--tag", tag] }
        if let cursor { args += ["--cursor", cursor] }
        return args
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }
}

public struct SessionPage: Sendable {
    public let sessions: [LiveKitSession]
    public let nextCursor: String?
    public init(json: JSONValue) throws {
        guard let items = json["items"]?.array ?? json["sessions"]?.array ?? json.array else {
            throw LiveKitCLIError(kind: .failed, message: "The CLI returned an unrecognized session page.")
        }
        sessions = items.compactMap(LiveKitSession.init(json:))
        guard sessions.count == items.count else { throw LiveKitCLIError(kind: .failed, message: "A session page contains invalid summaries; its cursor was not advanced.") }
        let pagination = json["pageInfo"] ?? json
        nextCursor = pagination["nextCursor"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let hasMore = pagination["hasMore"]?.bool, hasMore != (nextCursor != nil) {
            throw LiveKitCLIError(kind: .failed, message: "The CLI returned inconsistent pagination metadata. Refresh the range to retry.")
        }
    }
}

public struct SessionCoverage: Codable, Sendable {
    public var nextCursor: String?
    public var fetchedAt: Date
    public var complete: Bool
    public var error: String?
    public var canResume: Bool { complete || nextCursor != nil }

    public init(nextCursor: String? = nil, fetchedAt: Date, complete: Bool, error: String? = nil) { self.nextCursor = nextCursor; self.fetchedAt = fetchedAt; self.complete = complete; self.error = error }
}

public struct SessionBookmark: Codable, Hashable, Sendable {
    public let startedAt: Double
    public let id: String
    public init(startedAt: Double, id: String) { self.startedAt = startedAt; self.id = id }
    public init(_ row: SessionRow) { startedAt = row.startedAt?.timeIntervalSince1970 ?? 0; id = row.id }
}

public struct IndexedSession: Sendable {
    public var row: SessionRow
    public var agentName: String?
    public var lessonFlags: Int?

    public init(row: SessionRow, agentName: String? = nil, lessonFlags: Int? = nil) { self.row = row; self.agentName = agentName; self.lessonFlags = lessonFlags }
}

public struct RecordingScan: Codable, Sendable {
    public var cursor: String?
    public var complete = false
    public var objects = 0
    public var reconciling = false
    public var updatedAt = Date()

    public init(cursor: String? = nil, complete: Bool = false, objects: Int = 0, reconciling: Bool = false, updatedAt: Date = Date()) { self.cursor = cursor; self.complete = complete; self.objects = objects; self.reconciling = reconciling; self.updatedAt = updatedAt }
}

/// A single off-main-actor SQLite writer. Only bounded pages and metadata cross this boundary.
public actor SessionStore {
    public static let shared = SessionStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveKit Observer/session-index.sqlite"))
    private let url: URL
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close(database) } }

    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000; PRAGMA cache_size=-8192;")
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) <= 5 else {
                throw StoreError(message: "This session index was created by a newer Observer version.")
            }
            let oldVersion = sqlite3_column_int(version, 0)
            try execute("""
                CREATE TABLE IF NOT EXISTS sessions (
                    project TEXT NOT NULL, id TEXT NOT NULL, started REAL NOT NULL, room TEXT NOT NULL,
                    status TEXT NOT NULL, summary BLOB, recording BLOB, recording_source TEXT, attachment BLOB,
                    fetched REAL NOT NULL DEFAULT 0, agent TEXT, lesson_flags INTEGER,
                    flagged INTEGER NOT NULL DEFAULT 0, noted INTEGER NOT NULL DEFAULT 0, tag_flag INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(project,id));
                CREATE INDEX IF NOT EXISTS session_time ON sessions(project,started DESC,id DESC);
                CREATE INDEX IF NOT EXISTS session_status ON sessions(project,status,started DESC,id DESC);
                CREATE INDEX IF NOT EXISTS session_room ON sessions(project,room COLLATE NOCASE);
                CREATE INDEX IF NOT EXISTS session_flags ON sessions(project,flagged,started DESC,id DESC);
                CREATE INDEX IF NOT EXISTS session_attachments ON sessions(project) WHERE attachment IS NOT NULL;
                CREATE INDEX IF NOT EXISTS session_local_only ON sessions(project) WHERE summary IS NULL AND recording IS NULL;
                CREATE TABLE IF NOT EXISTS tags(project TEXT NOT NULL,id TEXT NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(project,id,tag));
                CREATE INDEX IF NOT EXISTS tag_lookup ON tags(project,tag,id);
                CREATE TABLE IF NOT EXISTS coverage(scope TEXT NOT NULL,query TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(scope,query));
                CREATE TABLE IF NOT EXISTS recording_objects(source TEXT NOT NULL,key TEXT NOT NULL,size INTEGER NOT NULL,PRIMARY KEY(source,key));
                CREATE TABLE IF NOT EXISTS recording_manifests(source TEXT NOT NULL,key TEXT NOT NULL,value BLOB,PRIMARY KEY(source,key));
                CREATE TABLE IF NOT EXISTS recording_scans(source TEXT PRIMARY KEY,value BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS workspace_time ON sessions(started DESC,project DESC,id DESC);
                CREATE TABLE IF NOT EXISTS cost_summaries(project TEXT NOT NULL,id TEXT NOT NULL,day TEXT NOT NULL,estimate REAL NOT NULL,partial INTEGER NOT NULL,updated REAL NOT NULL,PRIMARY KEY(project,id));
                CREATE INDEX IF NOT EXISTS cost_days ON cost_summaries(project,day);
                CREATE TABLE IF NOT EXISTS session_resources(project TEXT NOT NULL,id TEXT NOT NULL,kind TEXT NOT NULL,value BLOB NOT NULL,retry REAL,PRIMARY KEY(project,id,kind));
                CREATE INDEX IF NOT EXISTS resource_retry ON session_resources(project,retry) WHERE retry IS NOT NULL;
                CREATE TABLE IF NOT EXISTS cost_usage(project TEXT NOT NULL,id TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(project,id));
                CREATE TABLE IF NOT EXISTS history_jobs(project TEXT NOT NULL,kind TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(project,kind));
                """)
            try transaction {
                if oldVersion > 0 && oldVersion < 5 {
                    try execute("ALTER TABLE sessions ADD COLUMN tag_flag INTEGER NOT NULL DEFAULT 0")
                    try run("UPDATE sessions SET tag_flag=1 WHERE EXISTS(SELECT 1 FROM tags t WHERE t.project=sessions.project AND t.id=sessions.id AND t.tag=?)", [.text(Flag.lessonTag)])
                }
                try execute("CREATE INDEX IF NOT EXISTS session_review ON sessions(project,started DESC,id DESC) WHERE flagged=1 OR noted=1 OR lesson_flags>0 OR tag_flag=1; PRAGMA user_version=5;")
            }
            if oldVersion == 1 {
                // Development builds before pageInfo support overstated coverage; rows are still valid.
                try execute("DELETE FROM coverage")
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    public func ingest(_ page: SessionPage, project: String, scope: String, query: SessionQuery,
                flagged: Set<String> = [], noted: Set<String> = []) throws {
        try open()
        try transaction {
            for session in page.sessions { try upsertRecord(session, project: project, flagged: flagged.contains(session.id), noted: noted.contains(session.id)) }
            try setCoverage(SessionCoverage(nextCursor: page.nextCursor, fetchedAt: Date(), complete: page.nextCursor == nil), scope: scope, query: query)
        }
    }

    public func upsert(_ session: LiveKitSession, project: String, flagged: Bool = false, noted: Bool = false) throws {
        try open()
        try transaction { try upsertRecord(session, project: project, flagged: flagged, noted: noted) }
    }

    private func upsertRecord(_ session: LiveKitSession, project: String, flagged: Bool, noted: Bool) throws {
        try run("""
            INSERT INTO sessions(project,id,started,room,status,summary,fetched,flagged,noted,tag_flag) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(project,id) DO UPDATE SET started=excluded.started,room=excluded.room,status=excluded.status,
                summary=excluded.summary,fetched=excluded.fetched,flagged=excluded.flagged,noted=excluded.noted,tag_flag=excluded.tag_flag
            """, [.text(project), .text(session.id), .number(session.startedAt?.timeIntervalSince1970 ?? 0), .text(session.roomName),
                  .text(session.status), .blob(try encoder.encode(session)), .number(Date().timeIntervalSince1970), .number(flagged ? 1 : 0), .number(noted ? 1 : 0), .number(session.flaggedInLesson ? 1 : 0)])
        try run("DELETE FROM tags WHERE project=? AND id=?", [.text(project), .text(session.id)])
        for tag in Set(session.tags) { try run("INSERT INTO tags VALUES(?,?,?)", [.text(project), .text(session.id), .text(tag)]) }
    }

    public func attach(_ captures: [CaptureSession], project: String) throws {
        try open()
        try transaction {
            try run("UPDATE sessions SET attachment=NULL WHERE project=? AND attachment IS NOT NULL AND flagged=0 AND noted=0", [.text(project)])
            for capture in captures {
                try run("""
                    INSERT INTO sessions(project,id,started,room,status,attachment) VALUES(?,?,?,?,'',?)
                    ON CONFLICT(project,id) DO UPDATE SET attachment=excluded.attachment
                    """, [.text(project), .text(capture.sessionID), .number(capture.startedAt?.timeIntervalSince1970 ?? 0), .text(capture.roomName), .blob(try encoder.encode(capture))])
            }
            try run("DELETE FROM sessions WHERE project=? AND summary IS NULL AND recording IS NULL AND attachment IS NULL AND flagged=0 AND noted=0", [.text(project)])
        }
    }

    public func page(project: String, query: SessionQuery, after: SessionBookmark? = nil, limit: Int = 100,
              search: String = "", onlyFlagged: Bool = false, onlyRecording: Bool = false, recordingSource: String? = nil,
              ids: [String]? = nil) throws -> [IndexedSession] {
        try open()
        var whereSQL = "s.project=?"
        var values: [Value] = [.text(project)]
        if let ids {
            guard !ids.isEmpty else { return [] }
            let bounded = Array(Set(ids).prefix(100))
            whereSQL += " AND s.id IN (" + Array(repeating: "?", count: bounded.count).joined(separator: ",") + ")"
            values += bounded.map(Value.text)
        }
        // Durable attachments remain reachable even after the remote retention window.
        whereSQL += " AND (s.started>=? OR s.attachment IS NOT NULL OR s.flagged=1 OR s.noted=1)"
        values += [.number(query.start.timeIntervalSince1970)]
        if let end = query.end { whereSQL += " AND s.started<?"; values += [.number(end.timeIntervalSince1970)] }
        if !query.status.isEmpty { whereSQL += " AND s.status=?"; values += [.text(query.status)] }
        if !query.roomPrefix.isEmpty { whereSQL += " AND substr(s.room,1,length(?))=?"; values += [.text(query.roomPrefix), .text(query.roomPrefix)] }
        if !query.tag.isEmpty { whereSQL += " AND EXISTS(SELECT 1 FROM tags t WHERE t.project=s.project AND t.id=s.id AND t.tag=?)"; values += [.text(query.tag)] }
        if !search.isEmpty { whereSQL += " AND (s.room LIKE ? ESCAPE '\\' OR s.id=?)"; values += [.text(Self.escaped(search) + "%"), .text(search)] }
        if onlyFlagged { whereSQL += " AND (s.flagged=1 OR s.noted=1 OR s.lesson_flags>0 OR s.tag_flag=1)" }
        if onlyRecording { whereSQL += " AND s.recording IS NOT NULL AND s.recording_source=?"; values += [recordingSource.map(Value.text) ?? .null] }
        if let after { whereSQL += " AND (s.started,s.id)<(?,?)"; values += [.number(after.startedAt), .text(after.id)] }
        let index = onlyFlagged ? " INDEXED BY session_review" : (ids == nil && search.isEmpty ? " INDEXED BY session_time" : "")
        let stmt = try statement("SELECT id,summary,CASE WHEN recording_source=? THEN recording END,attachment,agent,lesson_flags FROM sessions s\(index) WHERE \(whereSQL) ORDER BY s.started DESC,s.id DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        try bind([recordingSource.map(Value.text) ?? .null] + values + [.number(Double(max(1, min(limit, 1000))))], to: stmt)
        var result: [IndexedSession] = []
        while try next(stmt) {
            let row = SessionRow(id: string(stmt, 0)!, session: try decode(LiveKitSession.self, stmt, 1),
                                 recording: try decode(EgressRecording.self, stmt, 2), localCaptureSession: try decode(CaptureSession.self, stmt, 3))
            result.append(IndexedSession(row: row, agentName: string(stmt, 4), lessonFlags: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))))
        }
        return result
    }

    public struct WorkspaceRow: Identifiable, Sendable {
        public let project: String, row: SessionRow
        public var id: String { project + ":" + row.id }
    
    public init(project: String, row: SessionRow) { self.project = project; self.row = row }
}
    public func workspacePage(projects: [String], query: SessionQuery, after: WorkspaceRow? = nil, onlyFlagged: Bool = false, search: String = "") throws -> [WorkspaceRow] {
        // Each project uses its time/review index and returns at most 100 summaries.
        // Merging at most 2,000 rows avoids a workspace-wide scan and temporary sort.
        let projects = Array(Set(projects).prefix(20))
        var candidates: [WorkspaceRow] = []
        for project in projects {
            let bookmark = after.map { value in
                let id = project == value.project ? value.row.id : (project < value.project ? "\u{10FFFF}" : "")
                return SessionBookmark(startedAt: value.row.startedAt?.timeIntervalSince1970 ?? 0, id: id)
            }
            let rows = try page(project: project, query: query, after: bookmark, search: search, onlyFlagged: onlyFlagged)
            candidates += rows.map { WorkspaceRow(project: project, row: $0.row) }
        }
        return Array(candidates.sorted {
            ($0.row.startedAt?.timeIntervalSince1970 ?? 0, $0.project, $0.row.id) >
            ($1.row.startedAt?.timeIntervalSince1970 ?? 0, $1.project, $1.row.id)
        }.prefix(100))
    }

    public struct CostRollup: Identifiable, Sendable {
        public let project: String, day: String
        public let estimate: Double, reviewed: Int, partial: Int, updated: Date
        public var id: String { project + ":" + day }
    
    public init(project: String, day: String, estimate: Double, reviewed: Int, partial: Int, updated: Date) { self.project = project; self.day = day; self.estimate = estimate; self.reviewed = reviewed; self.partial = partial; self.updated = updated }
}
    public func saveCost(project: String, id: String, date: Date, estimate: Double, partial: Bool) throws {
        try open(); guard estimate.isFinite, estimate >= 0 else { return }
        let day = String(ISO8601DateFormatter().string(from: date).prefix(10))
        try run("INSERT INTO cost_summaries VALUES(?,?,?,?,?,?) ON CONFLICT(project,id) DO UPDATE SET day=excluded.day,estimate=excluded.estimate,partial=excluded.partial,updated=excluded.updated",
                [.text(project), .text(id), .text(day), .number(estimate), .number(partial ? 1 : 0), .number(Date().timeIntervalSince1970)])
    }
    public func costUsage(project: String, id: String) throws -> CostUsageSnapshot? {
        try open(); let stmt = try statement("SELECT value FROM cost_usage WHERE project=? AND id=?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(project), .text(id)], to: stmt)
        return try next(stmt) ? decode(CostUsageSnapshot.self, stmt, 0) : nil
    }
    public func saveCostUsage(project: String, id: String, usage: CostUsageSnapshot) throws {
        try open()
        try transaction {
            try run("INSERT OR REPLACE INTO cost_usage VALUES(?,?,?)", [.text(project), .text(id), .blob(try encoder.encode(usage))])
            try saveCost(project: project, id: id, date: usage.date, estimate: usage.estimate, partial: usage.partial)
        }
    }
    public func historyProgress(project: String) throws -> CostHistoryProgress? {
        try open(); let stmt = try statement("SELECT value FROM history_jobs WHERE project=? AND kind='cost'")
        defer { sqlite3_finalize(stmt) }; try bind([.text(project)], to: stmt)
        return try next(stmt) ? decode(CostHistoryProgress.self, stmt, 0) : nil
    }
    public func saveHistoryProgress(project: String, progress: CostHistoryProgress) throws {
        try open(); try run("INSERT OR REPLACE INTO history_jobs VALUES(?,'cost',?)", [.text(project), .blob(try encoder.encode(progress))])
    }

    public func costs(projects: [String], since day: String) throws -> [CostRollup] {
        try open(); let projects = Array(Set(projects).prefix(20)); guard !projects.isEmpty else { return [] }
        let stmt = try statement("SELECT project,day,SUM(estimate),COUNT(*),SUM(partial),MAX(updated) FROM cost_summaries WHERE project IN (" + Array(repeating: "?", count: projects.count).joined(separator: ",") + ") AND day>=? GROUP BY project,day ORDER BY day DESC,project LIMIT 1000")
        defer { sqlite3_finalize(stmt) }; try bind(projects.map(Value.text) + [.text(day)], to: stmt)
        var result: [CostRollup] = []
        while try next(stmt) { result.append(CostRollup(project: string(stmt, 0)!, day: string(stmt, 1)!, estimate: sqlite3_column_double(stmt, 2), reviewed: Int(sqlite3_column_int(stmt, 3)), partial: Int(sqlite3_column_int(stmt, 4)), updated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)))) }
        return result
    }

    public func resourceStates(project: String, id: String) throws -> [SessionResource: ResourceReadiness] {
        try open()
        let stmt = try statement("SELECT kind,value FROM session_resources WHERE project=? AND id=?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(project), .text(id)], to: stmt)
        var result: [SessionResource: ResourceReadiness] = [:]
        while try next(stmt) {
            if let kind = string(stmt, 0).flatMap(SessionResource.init(rawValue:)), let state = try decode(ResourceReadiness.self, stmt, 1) { result[kind] = state }
        }
        return result
    }

    public func recordResource(project: String, id: String, kind: SessionResource, readiness: ResourceReadiness) throws {
        try open()
        let delay: TimeInterval = readiness.state == .pending ? 60 : 300
        let retry: Value = readiness.shouldRetry ? .number(readiness.checkedAt.addingTimeInterval(delay).timeIntervalSince1970) : .null
        try run("INSERT INTO session_resources VALUES(?,?,?,?,?) ON CONFLICT(project,id,kind) DO UPDATE SET value=excluded.value,retry=excluded.retry",
                [.text(project), .text(id), .text(kind.rawValue), .blob(try encoder.encode(readiness)), retry])
    }

    public struct PendingResource: Sendable { public let id: String; public let kind: SessionResource 
    public init(id: String, kind: SessionResource) { self.id = id; self.kind = kind }
}
    public func pendingResources(project: String, now: Date = .now, limit: Int = 4) throws -> [PendingResource] {
        try open()
        let stmt = try statement("SELECT id,kind FROM session_resources WHERE project=? AND retry<=? ORDER BY retry,id,kind LIMIT ?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(project), .number(now.timeIntervalSince1970), .number(Double(max(1, min(8, limit))))], to: stmt)
        var values: [PendingResource] = []
        while try next(stmt) { if let kind = string(stmt, 1).flatMap(SessionResource.init(rawValue:)) { values.append(.init(id: string(stmt, 0)!, kind: kind)) } }
        return values
    }

    /// Restore durable reviewer references without requiring the remote session to still exist.
    public func restoreAnnotations(_ references: [AnnotationReference]) throws {
        try open()
        try transaction {
            for ref in references {
                try run("""
                    INSERT INTO sessions(project,id,started,room,status,attachment,flagged,noted) VALUES(?,?,?,?,'',?,?,?)
                    ON CONFLICT(project,id) DO UPDATE SET flagged=excluded.flagged,noted=excluded.noted
                    """, [.text(ref.project), .text(ref.session.sessionID), .number(ref.session.startedAt?.timeIntervalSince1970 ?? 0),
                          .text(ref.session.roomName), .blob(try encoder.encode(ref.session)), .number(ref.flagged ? 1 : 0), .number(ref.noted ? 1 : 0)])
            }
        }
    }

    public func unsettled(project: String, limit: Int = 8) throws -> [String] {
        try open()
        let stmt = try statement("SELECT id FROM sessions WHERE project=? AND summary IS NOT NULL AND (status='active' OR started>?) AND fetched<? ORDER BY fetched ASC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        try bind([.text(project), .number(Date().addingTimeInterval(-600).timeIntervalSince1970), .number(Date().addingTimeInterval(-30).timeIntervalSince1970), .number(Double(limit))], to: stmt)
        var ids: [String] = []; while try next(stmt) { ids.append(string(stmt, 0)!) }; return ids
    }

    public func setFlags(project: String, id: String, flagged: Bool, noted: Bool) throws {
        try open()
        try run("UPDATE sessions SET flagged=?,noted=? WHERE project=? AND id=?", [.number(flagged ? 1 : 0), .number(noted ? 1 : 0), .text(project), .text(id)])
    }

    public func enrich(project: String, id: String, agent: String?, lessonFlags: Int?) throws {
        try open()
        try run("UPDATE sessions SET agent=COALESCE(?,agent),lesson_flags=COALESCE(?,lesson_flags) WHERE project=? AND id=?",
                [agent.map(Value.text) ?? .null, lessonFlags.map { .number(Double($0)) } ?? .null, .text(project), .text(id)])
    }

    public func coverage(scope: String, query: SessionQuery) throws -> SessionCoverage? {
        try open()
        let stmt = try statement("SELECT value FROM coverage WHERE scope=? AND query=?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(scope), .text(query.key)], to: stmt)
        return try next(stmt) ? decode(SessionCoverage.self, stmt, 0) : nil
    }

    public func setCoverage(_ value: SessionCoverage, scope: String, query: SessionQuery) throws {
        try open()
        try run("INSERT OR REPLACE INTO coverage VALUES(?,?,?)", [.text(scope), .text(query.key), .blob(try encoder.encode(value))])
    }

    public func prune(project: String, before: Date) throws {
        try open()
        try transaction {
            try run("DELETE FROM sessions WHERE project=? AND started<? AND status!='active' AND attachment IS NULL AND flagged=0 AND noted=0", [.text(project), .number(before.timeIntervalSince1970)])
            let changed = sqlite3_changes(database)
            if changed > 0 {
                try run("DELETE FROM tags WHERE project=? AND NOT EXISTS(SELECT 1 FROM sessions s WHERE s.project=tags.project AND s.id=tags.id)", [.text(project)])
                try run("DELETE FROM session_resources WHERE project=? AND NOT EXISTS(SELECT 1 FROM sessions s WHERE s.project=session_resources.project AND s.id=session_resources.id)", [.text(project)])
                // Eviction invalidates completeness and cursors, never implies remote deletion.
                try execute("DELETE FROM coverage")
            }
        }
    }

    public func recordingScan(source: String) throws -> RecordingScan? {
        try open()
        let stmt = try statement("SELECT value FROM recording_scans WHERE source=?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(source)], to: stmt)
        return try next(stmt) ? decode(RecordingScan.self, stmt, 0) : nil
    }

    /// Resolve audio for an opened session independently of list filters and workspace summaries.
    public func recording(project: String, id: String, source: String) throws -> EgressRecording? {
        try open()
        let stmt = try statement("SELECT recording FROM sessions WHERE project=? AND id=? AND recording_source=?")
        defer { sqlite3_finalize(stmt) }
        try bind([.text(project), .text(id), .text(source)], to: stmt)
        guard try next(stmt), var value = try decode(EgressRecording.self, stmt, 0) else { return nil }
        if let size = try recordingSize(source: source, key: value.audioKey) { value.size = size }
        return value
    }

    public func hasManifest(source: String, key: String) throws -> Bool {
        try open()
        let stmt = try statement("SELECT 1 FROM recording_manifests WHERE source=? AND key=?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(source), .text(key)], to: stmt); return try next(stmt)
    }

    public func saveRecordingPage(source: String, project: String, objects: [StorageObject], manifests: [(String, EgressRecording?)], scan: RecordingScan) throws {
        try open()
        try transaction {
            for object in objects { try run("INSERT OR REPLACE INTO recording_objects VALUES(?,?,?)", [.text(source), .text(object.key), .number(Double(object.size))]) }
            for (key, recording) in manifests {
                try run("INSERT OR REPLACE INTO recording_manifests VALUES(?,?,?)", [.text(source), .text(key), try recording.map { .blob(try encoder.encode($0)) } ?? .null])
                if var recording {
                    if let size = try recordingSize(source: source, key: recording.audioKey) { recording.size = size }
                    let old = try statement("SELECT recording FROM sessions WHERE project=? AND id=?")
                    defer { sqlite3_finalize(old) }
                    try bind([.text(project), .text(recording.roomId)], to: old)
                    if try next(old), let existing = try decode(EgressRecording.self, old, 0), existing.size > recording.size { continue }
                    try run("""
                        INSERT INTO sessions(project,id,started,room,status,recording,recording_source) VALUES(?,?,?,?,'',?,?)
                        ON CONFLICT(project,id) DO UPDATE SET recording=excluded.recording,recording_source=excluded.recording_source
                        """, [.text(project), .text(recording.roomId), .number(recording.startedAt?.timeIntervalSince1970 ?? 0), .text(recording.roomName), .blob(try encoder.encode(recording)), .text(source)])
                }
            }
            try run("INSERT OR REPLACE INTO recording_scans VALUES(?,?)", [.text(source), .blob(try encoder.encode(scan))])
        }
    }

    public func recordingSize(source: String, key: String) throws -> Int64? {
        try open(); let stmt = try statement("SELECT size FROM recording_objects WHERE source=? AND key=?")
        defer { sqlite3_finalize(stmt) }; try bind([.text(source), .text(key)], to: stmt)
        return try next(stmt) ? sqlite3_column_int64(stmt, 0) : nil
    }

    private enum Value { case text(String), number(Double), blob(Data), null }
    private struct StoreError: LocalizedError { let message: String; var errorDescription: String? { message } }
    private func failure() -> StoreError { StoreError(message: database.map { "Session index: " + String(cString: sqlite3_errmsg($0)) } ?? "Could not open the session index.") }
    private static func escaped(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }
    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }; return stmt
    }
    private func bind(_ values: [Value], to stmt: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1); let status: Int32
            switch value {
            case .text(let s): status = sqlite3_bind_text(stmt, i, s, -1, transient)
            case .number(let n): status = sqlite3_bind_double(stmt, i, n)
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(data.count), transient) }
            case .null: status = sqlite3_bind_null(stmt, i)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
    }
    private func run(_ sql: String, _ values: [Value]) throws {
        let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }; try bind(values, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func next(_ stmt: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(stmt); guard status == SQLITE_ROW || status == SQLITE_DONE else { throw failure() }; return status == SQLITE_ROW
    }
    private func string(_ stmt: OpaquePointer, _ index: Int32) -> String? { sqlite3_column_text(stmt, index).map { String(cString: $0) } }
    private func decode<T: Decodable>(_ type: T.Type, _ stmt: OpaquePointer, _ index: Int32) throws -> T? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return try decoder.decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index))))
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
}
