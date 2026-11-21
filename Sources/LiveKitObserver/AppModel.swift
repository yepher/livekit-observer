import AppKit
import Foundation
import Observation

/// Where the app finds `lk`, which project it shows, and where that project's egress recordings are.
struct AppSettings {
    static let lkKey = "lkPath"
    /// The selected `lk` project name; blank uses `lk`'s default project.
    static let projectKey = "lkProject"

    var lkOverride: String { UserDefaults.standard.string(forKey: Self.lkKey) ?? "" }
    var project: String? { UserDefaults.standard.string(forKey: Self.projectKey).flatMap { $0.isEmpty ? nil : $0 } }

    /// Per-project settings are stored under the project name, or "default" for `lk`'s default project.
    static func key(for project: String?) -> String { project ?? "default" }

    static func storage(for project: String?) -> StorageSettings {
        guard let data = UserDefaults.standard.data(forKey: "storage." + key(for: project)) else { return StorageSettings() }
        return (try? JSONDecoder().decode(StorageSettings.self, from: data)) ?? StorageSettings()
    }

    static func setStorage(_ settings: StorageSettings, secret: String?, for project: String?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "storage." + key(for: project))
        if let secret { Keychain.setSecret(secret, for: key(for: project)) }
    }

    static func storageSecret(for project: String?) -> String { Keychain.secret(for: key(for: project)) }

    /// The Cloud project ID (`p_…`) for dashboard links, when `lk` does not know it.
    static func dashboardProjectId(for project: String?) -> String {
        UserDefaults.standard.string(forKey: "projectId." + key(for: project))?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func setDashboardProjectId(_ id: String, for project: String?) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespaces), forKey: "projectId." + key(for: project))
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveKitObserver", isDirectory: true)
    }
}

/// One playable recording of a session, downloaded to the local cache.
struct RecordingSource: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable { case egress, observability }
    let kind: Kind
    let file: URL
    /// The wall-clock time of the first sample, used to line recordings up with each other and the transcript.
    let origin: Date?
    /// For egress: whether the project routes the user to the left channel and the agent to the right.
    var userLeftAgentRight = false
    var id: Kind { kind }

    var title: String { kind == .egress ? "Egress" : "LiveKit session" }
    var detail: String { kind == .egress ? "Egress recording from your storage bucket" : "LiveKit agent observability recording" }

    /// What each channel holds. LiveKit's session recording puts the user on the left and the agent on the right;
    /// egress does too only when the project routes audio by participant kind. A mixed recording is one lane.
    func channelName(_ channel: Int, of count: Int, identical: Bool) -> String {
        if identical { return "Mix (both channels identical)" }
        guard count == 2 else { return "Channel \(channel + 1)" }
        if kind == .observability || userLeftAgentRight { return channel == 0 ? "User (left)" : "Agent (right)" }
        return channel == 0 ? "Left" : "Right"
    }

    /// The channel holding the agent's audio: the right one when the layout is known, the only one in a mix,
    /// or nil when egress doesn't separate the agent.
    func agentChannel(channels count: Int, identical: Bool) -> Int? {
        if identical || count == 1 { return 0 }
        guard count == 2, kind == .observability || userLeftAgentRight else { return nil }
        return 1
    }
}

/// The detail of one session, loaded on selection.
@MainActor @Observable
final class SessionDetail {
    /// Updated in place when the session list refreshes, so a refresh doesn't reset what's open.
    var row: SessionRow
    var transcript: [TranscriptItem] = []
    var logs: [LogRecord] = []
    var spans: [Span] = [] { didSet { findTTSStatic() } }
    var metrics: [MetricPoint] = []
    /// Participants' connected time and bandwidth, for the cost breakdown.
    var room: RoomUsage?
    var dataState: String?
    var insights: SessionInsights?
    var observabilityError: LiveKitCLIError?
    var audioError: String?
    var loadingObservability = false
    var loadingAudio = false
    var sources: [RecordingSource] = [] { didSet { findTTSStatic() } }
    /// Each recording's channels as mono files, for playback and skimming.
    var channelFiles: [RecordingSource.Kind: [URL]] = [:]
    var spectrograms: [RecordingSource.Kind: Spectrogram] = [:] { didSet { findTTSStatic() } }
    var spectrogramErrors: [RecordingSource.Kind: String] = [:]
    var analyzing: Set<RecordingSource.Kind> = []
    /// Corrections to each recording's reported start time, found by matching the recordings' audio.
    var originCorrection: [RecordingSource.Kind: TimeInterval] = [:] { didSet { findTTSStatic() } }
    /// How the egress recording was lined up with LiveKit's, shown beside it.
    var alignment: Alignment = .reported
    /// Stretches marked while reviewing, highlighted in every view; saved per session.
    var flags: [Flag] = []
    /// Spans expanded in the trace tree. Kept here so the tree can be rebuilt without collapsing.
    var expandedSpans: Set<String> = []
    /// Possible static in the agent's TTS audio, per recording, on the session's clock.
    private(set) var ttsStatic: [RecordingSource.Kind: [TTSStatic]] = [:]

    /// The session's possible TTS static, from LiveKit's recording when there is one.
    var ttsStaticFound: [TTSStatic] { ttsStatic[.observability] ?? ttsStatic[.egress] ?? [] }
    /// Whether any recording's audio has been checked for TTS static yet.
    var ttsStaticChecked: Bool { !ttsStatic.isEmpty }

    /// Checks each analyzed recording's agent channel during the TTS lines in the traces.
    private func findTTSStatic() {
        let lines = Span.ttsLines(spans)
        var found: [RecordingSource.Kind: [TTSStatic]] = [:]
        if !lines.isEmpty {
            for source in sources {
                guard let spectrogram = spectrograms[source.kind], let origin = origin(of: source),
                      let channel = source.agentChannel(channels: spectrogram.noise.count, identical: spectrogram.identicalChannels),
                      channel < spectrogram.noise.count else { continue }
                found[source.kind] = StaticDetector.find(in: spectrogram.noise[channel], hop: spectrogram.hop, origin: origin, lines: lines)
            }
        }
        if found != ttsStatic { ttsStatic = found }
    }

    enum Alignment { case reported, byAudio, byHand, noMatch }

    /// When a recording's first sample was heard, corrected so the recordings line up with LiveKit's clock.
    func origin(of source: RecordingSource) -> Date? { source.origin?.addingTimeInterval(originCorrection[source.kind] ?? 0) }

    init(row: SessionRow) {
        self.row = row
        flags = Self.loadFlags(row.id)
    }
}

@MainActor @Observable
final class AppModel {
    var rows: [SessionRow] = []
    var selection: SessionRow.ID? { didSet { if selection != oldValue { openSelection() } } }
    var detail: SessionDetail?
    var loading = false
    var liveKitError: LiveKitCLIError?
    /// Whether the session list came from LiveKit, so a missing session means it has expired there.
    var liveKitLoaded = false
    /// The Cloud project ID, for dashboard links.
    var projectId: String?
    /// The projects saved in `lk`, and the LiveKit user it is signed in as.
    var projects: [LKProject] = []
    var signedInUser: String?
    var storageError: String?
    /// Whether egress storage is set up for the current project.
    var storageConfigured = false
    var filter = ""
    var onlyWithRecording = false
    var onlyFlagged = false
    /// Sessions flagged in the list so they are easy to find again; saved on this Mac. Session IDs are unique across projects.
    private(set) var flaggedSessions = Set(UserDefaults.standard.stringArray(forKey: AppModel.flaggedSessionsKey) ?? [])
    /// Sessions with flags in them (each flag carries a note), shown with a paperclip.
    private(set) var sessionsWithNotes: Set<String> = AppModel.loadSessionsWithNotes()
    let player = AudioPlayer()
    let skimmer = Skimmer()
    /// The flag whose note is being edited, shown as a sheet over the session.
    var renamingFlag: Flag.ID?

    private var settings = AppSettings()
    private var manifests: [String: EgressRecording] = [:]
    private var detailTask: Task<Void, Never>?
    /// Recently computed spectrograms, by file, so revisiting a session is instant.
    private var spectrogramCache: [URL: Spectrogram] = [:]

    /// The agent that ran each session, by session ID; "" when the session's logs name none.
    /// Fetched as rows appear, since LiveKit's session list does not include it.
    private(set) var agentNames: [String: String] = AppModel.loadAgentNames()
    private var agentNameRequested: Set<String> = []
    private var agentNameQueue: [String] = []
    private var agentNameFetches = 0
    /// Moments flagged from the lesson page per session, read from warning logs as rows appear; cached once settled.
    private(set) var lessonFlagCounts: [String: Int] = AppModel.loadLessonFlagCounts()
    private var lessonFlagsRequested: Set<String> = []
    private var lessonFlagQueue: [String] = []
    private var lessonFlagFetches = 0
    private static var lessonFlagsFile: URL { AppSettings.cacheDirectory.appendingPathComponent("lesson-flags.json") }
    private static var agentNamesFile: URL { AppSettings.cacheDirectory.appendingPathComponent("agent-names.json") }

    var visibleRows: [SessionRow] {
        rows.filter { row in
            (!onlyWithRecording || row.recording != nil)
                && (!onlyFlagged || flaggedSessions.contains(row.id) || flaggedInLesson(row))
                && (filter.isEmpty || row.roomName.localizedCaseInsensitiveContains(filter) || row.id.localizedCaseInsensitiveContains(filter))
        }
    }

    var cli: LiveKitCLI? {
        LiveKitCLI.locate(override: settings.lkOverride).map { LiveKitCLI(executable: $0, project: settings.project) }
    }

    /// The project being shown, by `lk` name; nil is `lk`'s default project.
    var project: String? { settings.project }

    /// Switches to another `lk` project and reloads everything.
    func selectProject(_ name: String?) {
        UserDefaults.standard.set(name ?? "", forKey: AppSettings.projectKey)
        selection = nil
        rows = []
        manifests = [:]
        liveKitLoaded = false
        Task { await refresh() }
    }

    /// The storage connection for the current project, or nil when none is set up.
    private func storageClient() throws -> StorageClient? {
        let settings = AppSettings.storage(for: project)
        guard !settings.isEmpty else { return nil }
        return StorageClient(config: try StorageConfig(settings: settings, secret: AppSettings.storageSecret(for: project)))
    }

    /// Opens Terminal to sign in to LiveKit Cloud; `lk` runs this browser flow only in a terminal.
    func signIn() { runInTerminal(["cloud", "auth", "--user-auth"]) }

    /// Opens Terminal to link a LiveKit Cloud project to `lk` from the browser.
    func linkCloudProject() { runInTerminal(["cloud", "auth"]) }

    private func runInTerminal(_ arguments: [String]) {
        guard let lk = LiveKitCLI.locate(override: settings.lkOverride) else {
            liveKitError = LiveKitCLIError(kind: .missingCLI, message: "The LiveKit CLI (lk) was not found.")
            return
        }
        do { try LiveKitCLI.openInTerminal(lk, arguments) }
        catch { liveKitError = LiveKitCLIError(kind: .failed, message: error.localizedDescription) }
    }

    func addProject(name: String, url: String, apiKey: String, apiSecret: String) async throws {
        guard let cli else { throw LiveKitCLIError(kind: .missingCLI, message: "The LiveKit CLI (lk) was not found.") }
        let name = name.trimmingCharacters(in: .whitespaces)
        try await cli.addProject(name: name, url: url.trimmingCharacters(in: .whitespaces),
                                 apiKey: apiKey.trimmingCharacters(in: .whitespaces), apiSecret: apiSecret.trimmingCharacters(in: .whitespaces))
        await loadAccount()
        selectProject(name)
    }

    /// Reloads the project list and sign-in state from `lk`.
    func loadAccount() async {
        guard let cli else { return }
        projects = (try? await cli.projects()) ?? []
        signedInUser = await cli.signedInUser()
    }

    /// LiveKit's model prices, for the cost breakdown; nil until read from the cache or the docs server.
    var pricing: PricingCatalog?

    private static var pricingFile: URL { AppSettings.cacheDirectory.appendingPathComponent("pricing.json") }

    /// Reads the cached price list, then fetches a new one if it is more than a day old. Failures keep what we have.
    func loadPricing() async {
        let file = Self.pricingFile
        if pricing == nil, let data = try? Data(contentsOf: file), let json = try? JSONValue.parse(data) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            pricing = PricingCatalog(json: json, fetched: modified)
        }
        guard Date().timeIntervalSince(pricing?.fetched ?? .distantPast) > PricingCatalog.maximumAge else { return }
        guard let data = try? await PricingCatalog.download(), let json = try? JSONValue.parse(data),
              let catalog = PricingCatalog(json: json, fetched: Date()) else { return }
        pricing = catalog
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
    }

    func refresh() async {
        Task { await loadPricing() }
        settings = AppSettings()
        loading = true
        defer { loading = false }
        async let account: Void = loadAccount()
        async let sessions = loadSessions()
        async let recordings = loadRecordings()
        _ = await account
        let override = AppSettings.dashboardProjectId(for: project)
        let known = projects.first { $0.name == project } ?? (project == nil && projects.count == 1 ? projects.first : nil)
        projectId = override.isEmpty ? known?.projectId : override
        let (s, r) = await (sessions, recordings)
        rows = SessionRow.merge(sessions: s, recordings: r)
        guard let selection, let row = rows.first(where: { $0.id == selection }), detail?.row != row else { return }
        if let detail, detail.row.id == row.id, detail.row.recording == row.recording, (detail.row.session == nil) == (row.session == nil) {
            // Same session with newer details, such as a live session that has ended: keep it open and reread its data.
            detail.row = row
            reloadObservability()
        } else {
            openSelection()
        }
    }

    /// Looks up the agent name for a row the list is showing. Only sessions with observability data have logs to read.
    func requestAgentName(for row: SessionRow) {
        requestLessonFlags(for: row)
        guard row.session?.hasDetailData == true, agentNames[row.id] == nil, agentNameRequested.insert(row.id).inserted else { return }
        agentNameQueue.append(row.id)
        pumpAgentNames()
    }

    /// Whether moments in a session were flagged from the lesson page: by its tag, its logs, or the open session's flags.
    func flaggedInLesson(_ row: SessionRow) -> Bool {
        if let detail, detail.row.id == row.id, detail.flags.contains(where: \.isFromLesson) { return true }
        return row.session?.flaggedInLesson == true || (lessonFlagCounts[row.id] ?? 0) > 0
    }

    private func requestLessonFlags(for row: SessionRow) {
        guard row.session?.hasDetailData == true, lessonFlagCounts[row.id] == nil || row.session?.status == "active",
              lessonFlagsRequested.insert(row.id).inserted else { return }
        lessonFlagQueue.append(row.id)
        pumpLessonFlags()
    }

    private func pumpLessonFlags() {
        guard let cli else { return }
        while lessonFlagFetches < 3, let id = lessonFlagQueue.popLast() {
            lessonFlagFetches += 1
            Task {
                let result = try? await cli.lessonFlagCount(id)
                lessonFlagFetches -= 1
                if let result { lessonFlagCounts[id] = result.count }
                if let result, result.settled {
                    saveLessonFlagCounts()
                } else {
                    lessonFlagsRequested.remove(id)  // logs may still arrive; check again the next time the row appears
                }
                pumpLessonFlags()
            }
        }
    }

    private static func loadLessonFlagCounts() -> [String: Int] {
        guard let data = try? Data(contentsOf: lessonFlagsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private func saveLessonFlagCounts() {
        try? FileManager.default.createDirectory(at: AppSettings.cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(lessonFlagCounts).write(to: Self.lessonFlagsFile, options: .atomic)
    }

    private func pumpAgentNames() {
        guard let cli else { return }
        while agentNameFetches < 4, let id = agentNameQueue.popLast() {  // newest request first: the rows on screen now
            agentNameFetches += 1
            Task {
                let result = try? await cli.agentName(id)
                agentNameFetches -= 1
                if let result, result.name != nil || result.settled {
                    agentNames[id] = result.name ?? ""
                    saveAgentNames()
                } else {
                    agentNameRequested.remove(id)  // try again the next time the row appears
                }
                pumpAgentNames()
            }
        }
    }

    private static func loadAgentNames() -> [String: String] {
        guard let data = try? Data(contentsOf: agentNamesFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveAgentNames() {
        try? FileManager.default.createDirectory(at: AppSettings.cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(agentNames).write(to: Self.agentNamesFile, options: .atomic)
    }

    private func loadSessions() async -> [LiveKitSession] {
        guard let cli else {
            liveKitError = LiveKitCLIError(kind: .missingCLI, message: "The LiveKit CLI (lk) was not found. Install it with `brew install livekit-cli`.")
            return []
        }
        do {
            let sessions = try await cli.sessions()
            liveKitError = nil
            liveKitLoaded = true
            return sessions
        } catch let error as LiveKitCLIError {
            liveKitError = error
        } catch {
            liveKitError = LiveKitCLIError(kind: .failed, message: error.localizedDescription)
        }
        return []
    }

    private func loadRecordings() async -> [EgressRecording] {
        do {
            guard let client = try storageClient() else {
                storageConfigured = false
                storageError = nil
                return []
            }
            storageConfigured = true
            let objects = try await client.list(prefix: client.config.prefix)
            let sizes = Dictionary(objects.map { ($0.key, $0.size) }, uniquingKeysWith: { a, _ in a })
            let newManifests = objects.filter { $0.key.hasSuffix(".json") && manifests[$0.key] == nil }
            try await withThrowingTaskGroup(of: (String, EgressRecording?).self) { group in
                for object in newManifests {
                    group.addTask { (object.key, EgressRecording(manifest: try JSONValue.parse(try await client.object(object.key)))) }
                }
                for try await (key, recording) in group { if let recording { manifests[key] = recording } }
            }
            storageError = nil
            return manifests.values.compactMap { recording in
                guard let size = sizes[recording.audioKey] else { return nil }  // manifest without audio
                var r = recording
                r.size = size
                return r
            }
        } catch {
            storageError = "Egress storage: \(error.localizedDescription)"
            return manifests.values.map { $0 }
        }
    }

    private func openSelection() {
        detailTask?.cancel()
        player.unload()
        if let previous = detail { noteFlags(of: previous) }
        guard let selection, let row = rows.first(where: { $0.id == selection }) else { detail = nil; return }
        let detail = SessionDetail(row: row)
        self.detail = detail
        detailTask = Task {
            async let a: Void = loadAudio(detail)
            async let o: Void = loadObservability(detail)
            _ = await (a, o)
        }
    }

    func reloadObservability() {
        guard let detail else { return }
        Task { await loadObservability(detail) }
    }

    private func loadObservability(_ detail: SessionDetail) async {
        guard let cli, detail.row.session != nil else {
            detail.observabilityError = detail.row.session == nil
                ? LiveKitCLIError(kind: .failed, message: "LiveKit has no session for this recording (LiveKit keeps session data for 30 days).")
                : liveKitError
            return
        }
        detail.loadingObservability = true
        defer { detail.loadingObservability = false }
        let id = detail.row.id
        do {
            async let transcript = cli.transcript(id)
            async let logs = cli.logs(id)
            async let spans = cli.traces(id)
            async let metrics = cli.metrics(id)
            async let room = cli.roomUsage(id)
            let t = try await transcript
            detail.transcript = t.items
            detail.dataState = t.status
            detail.logs = (try? await logs) ?? []
            detail.spans = (try? await spans) ?? []
            detail.metrics = (try? await metrics) ?? []
            detail.room = (try? await room) ?? nil
            detail.insights = SessionInsights(transcript: detail.transcript, logs: detail.logs, spans: detail.spans)
            detail.applyLessonFlags()
            lessonFlagCounts[id] = detail.flags.filter(\.isFromLesson).count
            if detail.dataState == "settled" { saveLessonFlagCounts() }
            detail.observabilityError = nil
        } catch let error as LiveKitCLIError {
            detail.observabilityError = error
            if error.kind == .signedOut { liveKitError = error }
        } catch {
            detail.observabilityError = LiveKitCLIError(kind: .failed, message: error.localizedDescription)
        }
    }

    /// Downloads the egress recording and LiveKit's session recording together, then loads every channel of both
    /// into the player. When there are both, LiveKit's is muted to start with, since it holds the same audio.
    private func loadAudio(_ detail: SessionDetail) async {
        detail.loadingAudio = true
        defer { detail.loadingAudio = false }
        async let egress = egressSource(detail)
        async let observability = observabilitySource(detail)
        let found = await [egress, observability].compactMap { $0 }
        guard detail === self.detail, !Task.isCancelled else { return }
        detail.sources = found
        guard !found.isEmpty else {
            if detail.audioError == nil { detail.audioError = "No recording for this session." }
            return
        }
        var tracks: [PlaybackTrack] = []
        for source in found {
            let files = await Task.detached(priority: .userInitiated) { try? PlaybackFile.channels(source.file) }.value ?? []
            guard detail === self.detail, !Task.isCancelled else { return }
            detail.channelFiles[source.kind] = files
            for (channel, file) in files.enumerated() {
                // Each channel keeps its place in the recording: left, right, or the middle for a mix.
                let pan: Float = files.count == 2 ? (channel == 0 ? -1 : 1) : 0
                tracks.append(PlaybackTrack(id: TrackID(kind: source.kind, channel: channel), file: file, origin: detail.origin(of: source), pan: pan))
            }
        }
        if tracks.isEmpty, detail.audioError == nil { detail.audioError = "Could not decode the recordings." }
        let duplicate = found.count > 1 ? Set(tracks.map(\.id).filter { $0.kind == .observability }) : []
        player.load(tracks, muted: duplicate)
    }

    private func egressSource(_ detail: SessionDetail) async -> RecordingSource? {
        guard let recording = detail.row.recording else { return nil }
        do {
            let file = egressFile(recording)
            if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) }) != recording.size {
                guard let client = try storageClient() else { throw StorageError.message("Egress storage is not set up for this project.") }
                try await client.download(recording.audioKey, to: file)
            }
            return RecordingSource(kind: .egress, file: file, origin: recording.startedAt,
                                   userLeftAgentRight: AppSettings.storage(for: project).userLeftAgentRight)
        } catch {
            detail.audioError = "Could not download the egress recording: \(error.localizedDescription)"
            return nil
        }
    }

    /// Where an egress recording is cached once downloaded.
    private func egressFile(_ recording: EgressRecording) -> URL {
        AppSettings.cacheDirectory.appendingPathComponent("recordings")
            .appendingPathComponent(AppSettings.key(for: project), isDirectory: true)
            .appendingPathComponent(recording.audioKey.replacingOccurrences(of: "/", with: "_"))
    }

    /// Where LiveKit's session recording is cached once downloaded.
    private static func observabilityFile(_ sessionId: String) -> URL {
        AppSettings.cacheDirectory.appendingPathComponent("livekit").appendingPathComponent("\(sessionId).ogg")
    }

    /// LiveKit's session recording, downloaded because its link expires and the spectrogram needs the file.
    private func observabilitySource(_ detail: SessionDetail) async -> RecordingSource? {
        guard detail.row.session != nil, let cli else { return nil }
        let file = Self.observabilityFile(detail.row.id)
        let marker = file.appendingPathExtension("json")
        // A settled recording never changes, so reuse it with its saved start time.
        if let saved = try? JSONValue.parse(Data(contentsOf: marker)), FileManager.default.fileExists(atPath: file.path) {
            return RecordingSource(kind: .observability, file: file, origin: saved["startedAt"]?.date)
        }
        do {
            guard let recording = try await cli.recording(detail.row.id) else { return nil }
            let (download, response) = try await URLSession.shared.download(from: recording.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: marker)
            try FileManager.default.moveItem(at: download, to: file)
            if recording.settled, let startedAt = recording.startedAt {
                try? JSONSerialization.data(withJSONObject: ["startedAt": ISO8601DateFormatter().string(from: startedAt)]).write(to: marker)
            }
            return RecordingSource(kind: .observability, file: file, origin: recording.startedAt)
        } catch {
            return nil
        }
    }

    /// Computes a spectrogram for each recording of the session that does not have one yet.
    func analyze(_ detail: SessionDetail) async {
        await withTaskGroup(of: Void.self) { group in
            for source in detail.sources where detail.spectrograms[source.kind] == nil && !detail.analyzing.contains(source.kind) {
                if let cached = spectrogramCache[source.file] { detail.spectrograms[source.kind] = cached; continue }
                detail.analyzing.insert(source.kind)
                group.addTask { @MainActor in
                    defer { detail.analyzing.remove(source.kind) }
                    let work = Task.detached(priority: .userInitiated) { try Spectrogram.compute(file: source.file) }
                    do {
                        let spectrogram = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                        detail.spectrograms[source.kind] = spectrogram
                        if self.spectrogramCache.count >= 6 { self.spectrogramCache.removeAll() }
                        self.spectrogramCache[source.file] = spectrogram
                    } catch is CancellationError {
                    } catch {
                        detail.spectrogramErrors[source.kind] = "Could not analyze the \(source.title.lowercased()) recording: \(error.localizedDescription)"
                    }
                }
            }
        }
        await align(detail)
    }

    /// Egress and LiveKit's recording start on different clocks, at different moments, so line the egress
    /// recording up with LiveKit's (whose clock the transcript and logs use) by matching their audio.
    /// A hand adjustment saved for the session wins.
    private func align(_ detail: SessionDetail) async {
        guard detail.alignment == .reported, detail.sources.contains(where: { $0.kind == .egress }) else { return }
        if let saved = UserDefaults.standard.object(forKey: Self.alignmentKey(detail)) as? Double {
            setCorrection(saved, how: .byHand, in: detail)
            return
        }
        await alignByAudio(detail)
    }

    /// Finds the egress recording's offset from LiveKit's by matching their loudness over time.
    func alignByAudio(_ detail: SessionDetail) async {
        guard let egress = detail.sources.first(where: { $0.kind == .egress }), let egressStart = egress.origin,
              let livekit = detail.sources.first(where: { $0.kind == .observability }), let livekitStart = livekit.origin,
              let a = detail.spectrograms[.egress], let b = detail.spectrograms[.observability]
        else { return }
        let reported = egressStart.timeIntervalSince(livekitStart)
        // Search the whole plausible range around the reported offset, since the two clocks can disagree by a lot.
        let range = max(30, min(300, max(a.duration, b.duration)))
        let measured = await Task.detached(priority: .userInitiated) { a.startOffset(from: b, expected: reported, range: range) }.value
        UserDefaults.standard.removeObject(forKey: Self.alignmentKey(detail))
        if let measured {
            setCorrection(measured - reported, how: .byAudio, in: detail)
        } else {
            setCorrection(nil, how: .noMatch, in: detail)
        }
    }

    /// Moves the egress recording later (positive) or earlier on the session timeline, and remembers it for the session.
    func nudgeEgress(_ detail: SessionDetail, by seconds: TimeInterval) {
        let value = (((detail.originCorrection[.egress] ?? 0) + seconds) * 1000).rounded() / 1000
        UserDefaults.standard.set(value, forKey: Self.alignmentKey(detail))
        setCorrection(value, how: .byHand, in: detail)
    }

    /// Goes back to the start times the recordings report, for now.
    func resetAlignment(_ detail: SessionDetail) {
        UserDefaults.standard.removeObject(forKey: Self.alignmentKey(detail))
        setCorrection(nil, how: .reported, in: detail)
    }

    private func setCorrection(_ value: TimeInterval?, how: SessionDetail.Alignment, in detail: SessionDetail) {
        detail.originCorrection[.egress] = value
        detail.alignment = how
        if detail === self.detail, let egress = detail.sources.first(where: { $0.kind == .egress }) {
            player.setOrigin(detail.origin(of: egress), of: .egress)
        }
    }

    private static func alignmentKey(_ detail: SessionDetail) -> String { "egressAlignment." + detail.row.id }

    func dashboardURL(for id: String) -> URL? { projectId.flatMap { LiveKitCLI.dashboardURL(project: $0, session: id) } }

    func openDashboard(_ id: String) {
        if let url = dashboardURL(for: id) { NSWorkspace.shared.open(url) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ObservationIgnored private var spaceMonitor: Any?

    /// Space plays and pauses anywhere in the session window, whatever has focus, except while typing.
    /// A menu shortcut is not enough: lists, tables, and focused buttons take the key first, and the
    /// menu would take spaces typed into the filter fields.
    func handleSpaceBar() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),  // a text field or the note being typed
                  !(window.identifier?.rawValue.contains("Settings") ?? false),
                  self.player.isLoaded
            else { return event }
            if !event.isARepeat { self.player.toggle() }
            return nil
        }
    }

    // MARK: Session flags and notes

    private static let flaggedSessionsKey = "flaggedSessions"

    func isFlagged(_ id: String) -> Bool { flaggedSessions.contains(id) }

    func toggleSessionFlag(_ id: String) {
        if flaggedSessions.remove(id) == nil { flaggedSessions.insert(id) }
        UserDefaults.standard.set(flaggedSessions.sorted(), forKey: Self.flaggedSessionsKey)
    }

    /// Whether a session has flags with notes; the open session is read live so the list updates as you flag.
    func hasNotes(_ id: String) -> Bool {
        if let detail, detail.row.id == id { return detail.flags.contains { !$0.isFromLesson } }
        return sessionsWithNotes.contains(id)
    }

    private func noteFlags(of detail: SessionDetail) {
        if detail.flags.allSatisfy(\.isFromLesson) { sessionsWithNotes.remove(detail.row.id) } else { sessionsWithNotes.insert(detail.row.id) }
    }

    private static func loadSessionsWithNotes() -> Set<String> {
        let prefix = SessionDetail.flagsKey("")
        return Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    /// Flags the turn at the playhead and asks for a note.
    func flagPlayhead() {
        guard let detail, let now = player.currentDate else { return }
        renamingFlag = (detail.flag(at: now) ?? detail.addFlag(at: now)).id
    }

    func copyReport() {
        guard let detail, let insights = detail.insights else { return }
        let text = SessionReport.markdown(row: detail.row, transcript: detail.transcript, insights: insights, origin: player.origin ?? detail.row.startedAt,
                                          flags: detail.flags, logs: detail.logs, spans: detail.spans)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Saving session data

    /// Sessions whose data is being saved, so their Save commands are disabled until it finishes.
    var savingSessions: Set<String> = []
    /// Why the last save failed, or what it could not include; shown in an alert.
    var saveMessage: String?

    /// Asks where to save a session's data, writes it to a folder there, and shows the folder in Finder.
    /// The folder holds the raw `lk analytics` JSON, the downloaded recordings, the flags, and, for the open
    /// session, the same report Copy for Claude makes.
    func saveSessionData(_ row: SessionRow) {
        guard !savingSessions.contains(row.id) else { return }
        let panel = NSSavePanel()
        panel.title = "Save Session Data"
        panel.message = "Saves a folder with the session's transcript, logs, traces, metrics, recordings, and flags."
        panel.nameFieldStringValue = Self.folderName(for: row)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        savingSessions.insert(row.id)
        Task {
            defer { savingSessions.remove(row.id) }
            do {
                let skipped = try await writeSessionData(row, to: folder)
                UserDefaults.standard.set(folder.path, forKey: Self.savedFolderKey(row.id))
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                if !skipped.isEmpty { saveMessage = "Saved, without:\n" + skipped.joined(separator: "\n") }
            } catch {
                saveMessage = "Could not save the session data: \(error.localizedDescription)"
            }
        }
    }

    /// Writes the session's files into `folder` and returns what it left out and why.
    private func writeSessionData(_ row: SessionRow, to folder: URL) async throws -> [String] {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var skipped: [String] = []

        if row.session != nil, let cli {
            let raw = await cli.rawSessionData(row.id)
            for file in raw.files { try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic) }
            skipped += raw.failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        } else if row.session == nil {
            skipped.append("LiveKit data: LiveKit has no session for this recording (it keeps session data for 30 days).")
        } else {
            skipped.append("LiveKit data: \(liveKitError?.message ?? "lk is not available.")")
        }

        // Recordings are copied only once downloaded, which opening the session does.
        let recordings: [(source: URL, name: String)] = [
            (Self.observabilityFile(row.id), "livekit-recording.ogg"),
        ] + (row.recording.map { recording in
            let file = egressFile(recording)
            return [(file, "egress-recording." + (file.pathExtension.isEmpty ? "audio" : file.pathExtension))]
        } ?? [])
        for recording in recordings {
            guard files.fileExists(atPath: recording.source.path) else {
                if row.session != nil || recording.name.hasPrefix("egress") { skipped.append("\(recording.name): not downloaded. Open the session first to download it, if there is one.") }
                continue
            }
            let destination = folder.appendingPathComponent(recording.name)
            try? files.removeItem(at: destination)
            try files.copyItem(at: recording.source, to: destination)
        }

        let open = detail?.row.id == row.id ? detail : nil
        let flags = open?.flags ?? SessionDetail.loadFlags(row.id)
        if !flags.isEmpty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(flags).write(to: folder.appendingPathComponent("flags.json"), options: .atomic)
        }
        if let open, let insights = open.insights {
            let report = SessionReport.markdown(row: open.row, transcript: open.transcript, insights: insights,
                                                origin: player.origin ?? open.row.startedAt, flags: open.flags, logs: open.logs, spans: open.spans)
            try Data(report.utf8).write(to: folder.appendingPathComponent("report.md"), options: .atomic)
        }
        return skipped
    }

    private static func savedFolderKey(_ sessionId: String) -> String { "savedFolder." + sessionId }

    /// Where the session's data was last saved, while that folder still exists.
    func savedFolder(_ sessionId: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.savedFolderKey(sessionId)) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func showSavedFolder(_ sessionId: String) {
        if let folder = savedFolder(sessionId) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    /// "<room> <session id>", without characters Finder would not keep in a name.
    private static func folderName(for row: SessionRow) -> String {
        let name = [row.roomName, row.id].filter { !$0.isEmpty }.joined(separator: " ")
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    func clearCache() {
        player.unload()
        spectrogramCache.removeAll()
        try? FileManager.default.removeItem(at: AppSettings.cacheDirectory)
        detail = nil
        selection = nil
    }

    var cacheSize: Int64 {
        let files = FileManager.default.enumerator(at: AppSettings.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
