import ObserverCore
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
    static func key(for project: String?) -> String {
        guard let project else { return "default" }
        return UserDefaults.standard.string(forKey: "projectIdentity." + project) ?? project
    }

    static func storage(for project: String?) -> StorageSettings {
        guard let data = UserDefaults.standard.data(forKey: "storage." + key(for: project)) else { return StorageSettings() }
        return (try? JSONDecoder().decode(StorageSettings.self, from: data)) ?? StorageSettings()
    }

    static func setStorage(_ settings: StorageSettings, secret: String?, for project: String?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "storage." + key(for: project))
        if let secret, Keychain.setSecret(secret, for: key(for: project)) {
            UserDefaults.standard.removeObject(forKey: "storageSecretAlias." + key(for: project))
        }
    }

    static func storageSecret(for project: String?) -> String {
        let identity = key(for: project)
        let legacy = UserDefaults.standard.string(forKey: "storageSecretAlias." + identity)
        return Keychain.secret(for: legacy ?? identity)
    }

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
    let mediaLease = UUID()
    deinit { let lease = mediaLease; Task { await MediaCache.shared.release(lease) } }
    var simulationJudge: SimulationJob?
    /// Updated in place when the session list refreshes, so a refresh doesn't reset what's open.
    var row: SessionRow
    var transcript: [TranscriptItem] = []
    var logs: [LogRecord] = []
    var spans: [Span] = [] { didSet { findTTSStatic() } }
    var metrics: [MetricPoint] = []
    /// Participants' connected time and bandwidth, for the cost breakdown.
    var room: RoomUsage?
    var dataState: String?
    var resourceStates: [SessionResource: ResourceReadiness] = [:]
    var insights: SessionInsights?
    var observabilityError: LiveKitCLIError?
    var audioError: String?
    var egressError: String?
    var loadingObservability = false
    var loadingAudio = false
    var audioRevision = 0
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
    var transcriptionComparisons: [TranscriptionComparison] = []
    var aiReview: AIReviewResult?
    var aiChargeRevision = 0
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
    var section: AppSection = .sessions
    let operations = OperationsModel()
    let monitor = AgentMonitor()
    static var isTesting: Bool { NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    let captures = PacketCaptureModel()
    private var refreshGeneration = UUID()
    var rows: [SessionRow] = []
    var selection: SessionRow.ID? { didSet { if selection != oldValue { openSelection() } } }
    var detail: SessionDetail?
    var loading = false
    var liveKitError: LiveKitCLIError?
    /// Whether a remote summary page has been loaded. Absence from a page never implies expiry.
    var liveKitLoaded = false
    /// The Cloud project ID, for dashboard links.
    var projectId: String?
    /// The projects saved in `lk`, and the LiveKit user it is signed in as.
    var projects: [ProjectRef] = []
    var signedInUser: String?
    var storageError: String?
    /// Whether egress storage is set up for the current project.
    var storageConfigured = false
    var filter = "" { didSet { if filter != oldValue { scheduleCachedQuery() } } }
    var onlyWithRecording = false { didSet { if onlyWithRecording != oldValue { scheduleCachedQuery() } } }
    var onlyFlagged = false { didSet { if onlyFlagged != oldValue { scheduleCachedQuery() } } }
    var sessionQuery = SessionQuery()
    var coverage: SessionCoverage?
    var loadingMore = false
    var cachedHasMore = false
    var indexError: String?
    var recordingScan: RecordingScan?
    var scanningRecordings = false
    var cliVersion: CLIVersion?
    var showingProjectSwitcher = false
    var openWorkspaceAfterSwitcher = false
    var showingWorkspace = false
    var showingQuickJump = false
    var workspaceFilter: String?
    var scrollAnchor: String?
    var restorationAnchor: SessionBookmark?
    var needsScrollRestoration = false
    private var savedNavigation: ProjectNavigation?
    private var projectStates = ProjectStateCache()
    private var restoringState = false
    private var refreshTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    let sessionStore: SessionStore
    private let mediaCacheDirectory: URL
    private var projectedAttachmentRevision: [String: Int] = [:]
    var projectIdentity: String { AppSettings.key(for: project) }
    var selectedProject: ProjectRef? { projects.first { $0.selection == project || $0.id == project } }
    private var syncScope: String { (signedInUser ?? "signed-out") + ":" + projectIdentity }
    var canLoadMore: Bool { cachedHasMore || coverage?.nextCursor != nil }
    var coverageText: String {
        if let error = indexError { return error }
        if let coverage {
            let freshness = coverage.fetchedAt.formatted(date: .abbreviated, time: .shortened)
            return "\(rows.count) loaded · \(coverage.complete ? "Range indexed" : "Partial history") · Updated \(freshness)"
        }
        return "\(rows.count) cached · Remote coverage unknown"
    }
    /// Sessions flagged in the list so they are easy to find again; saved on this Mac. Session IDs are unique across projects.
    private(set) var flaggedSessions = Set(UserDefaults.standard.stringArray(forKey: AppModel.flaggedSessionsKey) ?? [])
    /// Sessions with flags in them (each flag carries a note), shown with a paperclip.
    private(set) var sessionsWithNotes: Set<String> = AppModel.loadSessionsWithNotes()
    let player = AudioPlayer()
    let skimmer = Skimmer()
    /// The flag whose note is being edited, shown as a sheet over the session.
    var renamingFlag: Flag.ID?

    private var settings = AppSettings()
    private var detailTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    /// Recently computed spectrograms, by file, so revisiting a session is instant.
    private var spectrogramCache: [URL: Spectrogram] = [:]

    /// Enrichment is read from the index or the selected session, never requested by scrolling.
    private(set) var agentNames: [String: String] = [:]
    private(set) var lessonFlagCounts: [String: Int] = [:]
    var visibleRows: [SessionRow] { rows }

    var cli: LiveKitCLI? {
        guard project?.hasPrefix("local:") != true else { return nil }
        return LiveKitCLI.locate(override: settings.lkOverride).map { LiveKitCLI(executable: $0, project: selectedProject?.projectId ?? project) }
    }

    /// The project being shown, by `lk` name; nil is `lk`'s default project.
    private(set) var project: String?

    init(project: String? = nil, sessionStore: SessionStore = .shared, mediaCacheDirectory: URL = AppSettings.cacheDirectory) {
        self.sessionStore = sessionStore
        self.mediaCacheDirectory = mediaCacheDirectory
        self.project = project ?? AppSettings().project
        let navigation = ProjectNavigation.load(AppSettings.key(for: self.project))
        savedNavigation = navigation
        sessionQuery = navigation.query; filter = navigation.search
        onlyFlagged = navigation.flagged; onlyWithRecording = navigation.recorded
        section = AppSection(rawValue: navigation.section) ?? .sessions
        restorationAnchor = navigation.anchor; scrollAnchor = navigation.anchor?.id; needsScrollRestoration = navigation.anchor != nil
    }

    func persistNavigation() {
        guard project != nil, !restoringState else { return }
        var navigation = ProjectNavigation()
        navigation.selection = selection
        navigation.anchor = rows.first(where: { $0.id == scrollAnchor }).map(SessionBookmark.init) ?? restorationAnchor
        navigation.section = section.rawValue
        navigation.agent = operations.selectedAgent; navigation.run = operations.selectedRun; navigation.room = operations.selectedRoom
        navigation.query = sessionQuery; navigation.search = filter; navigation.flagged = onlyFlagged; navigation.recorded = onlyWithRecording
        navigation.save(projectIdentity)
    }

    func restoreOperationSelection() {
        let navigation = ProjectNavigation.load(projectIdentity)
        operations.selectedAgent = navigation.agent; operations.selectedRun = navigation.run; operations.selectedRoom = navigation.room
    }

    /// Retain three lightweight project views; release media when leaving a project.
    func selectProject(_ name: String?) {
        guard name != project else { return }
        persistNavigation()
        projectStates.save(ProjectBrowseState(rows: rows, selection: selection, query: sessionQuery, search: filter,
                                            onlyFlagged: onlyFlagged, onlyRecording: onlyWithRecording, coverage: coverage, navigation: ProjectNavigation.load(projectIdentity)), for: projectIdentity)
        refreshTask?.cancel(); queryTask?.cancel(); pageTask?.cancel(); recordingTask?.cancel(); detailTask?.cancel(); audioTask?.cancel(); analysisTask?.cancel()
        refreshGeneration = UUID()
        selection = nil
        detail = nil
        spectrogramCache.removeAll()
        UserDefaults.standard.set(name ?? "", forKey: AppSettings.projectKey)
        project = name
        projectId = selectedProject?.projectId
        agentNames = [:]; lessonFlagCounts = [:]
        restoringState = true
        let state = projectStates.state(for: projectIdentity)
        let navigation = state?.navigation ?? ProjectNavigation.load(projectIdentity)
        savedNavigation = navigation
        section = AppSection(rawValue: navigation.section) ?? .sessions
        restorationAnchor = navigation.anchor; scrollAnchor = navigation.anchor?.id; needsScrollRestoration = navigation.anchor != nil
        rows = state?.rows ?? []
        sessionQuery = state?.query ?? navigation.query
        filter = state?.search ?? navigation.search
        onlyFlagged = state?.onlyFlagged ?? navigation.flagged
        onlyWithRecording = state?.onlyRecording ?? navigation.recorded
        coverage = state?.coverage
        restoringState = false
        liveKitLoaded = false; liveKitError = nil; storageError = nil; recordingScan = nil
        var recent = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        recent.removeAll { $0 == name }; if let name { recent.insert(name, at: 0) }
        UserDefaults.standard.set(Array(recent.prefix(9)), forKey: "recentProjects")
        selection = state?.selection
        Task { await refresh() }
    }

    private func scheduleCachedQuery() {
        guard !restoringState else { return }
        restorationAnchor = nil; scrollAnchor = nil; needsScrollRestoration = false
        queryTask?.cancel()
        let generation = refreshGeneration
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation() }
            catch { return }
            await loadCached(generation: generation)
        }
    }

    func applySessionQuery() async {
        restorationAnchor = nil; scrollAnchor = nil; needsScrollRestoration = false
        rows = []; coverage = nil
        await refresh()
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

    /// Reload secret-free metadata, then migrate preferences without touching the stored secrets.
    private var restoredAnnotations = false
    private var localProjects: [ProjectRef] = []
    func loadAccount() async {
        if !restoredAnnotations {
            do {
                let notes = Dictionary(uniqueKeysWithValues: sessionsWithNotes.map { ($0, SessionDetail.loadFlags($0)) })
                let refs = try await AnnotationStore.shared.recoverLegacy(flagged: flaggedSessions, notes: notes)
                try await sessionStore.restoreAnnotations(refs)
                if refs.contains(where: { $0.project == AnnotationStore.unassigned && ($0.flagged || $0.noted) }) {
                    localProjects = [ProjectRef(id: AnnotationStore.unassigned, name: "Unassigned local notes", url: "")]
                }
                restoredAnnotations = true
            } catch { indexError = "Local annotation recovery: " + error.localizedDescription }
        }
        for item in localProjects where !projects.contains(where: { $0.id == item.id }) { projects.append(item) }
        guard let executable = LiveKitCLI.locate(override: settings.lkOverride) else { projects = localProjects; return }
        let cli = LiveKitCLI(executable: executable, project: nil)
        do {
            cliVersion = nil
            cliVersion = try await cli.version()
            let found = try await cli.projects()
            try Task.checkCancellation()
            projects = found + localProjects
            for item in found {
                guard let name = item.lkName, name != item.id else { continue }
                let previousIdentity = AppSettings.key(for: name)
                for prefix in ["storage.", "projectId."] {
                    let defaults = UserDefaults.standard
                    let source = defaults.object(forKey: prefix + previousIdentity) != nil ? previousIdentity : name
                    if defaults.object(forKey: prefix + item.id) == nil, let old = defaults.object(forKey: prefix + source) {
                        defaults.set(old, forKey: prefix + item.id)
                        if prefix == "storage." { defaults.set(defaults.string(forKey: "storageSecretAlias." + source) ?? source, forKey: "storageSecretAlias." + item.id) }
                    }
                }
                UserDefaults.standard.set(item.id, forKey: "projectIdentity." + name)
            }
            signedInUser = await cli.signedInUser()
            try Task.checkCancellation()
            if project == nil, let explicit = found.first(where: \.isDefault) ?? (found.count == 1 ? found.first : nil) {
                UserDefaults.standard.set(explicit.selection, forKey: AppSettings.projectKey)
                project = explicit.selection
            }
        } catch is CancellationError { return }
        catch let error as LiveKitCLIError { liveKitError = error }
        catch { liveKitError = LiveKitCLIError(kind: .failed, message: error.localizedDescription) }
    }

    /// LiveKit's model prices, for the cost breakdown; nil until read from the cache or the docs server.
    var pricing: PricingCatalog?
    var inferenceModels = InferenceModels.bundled()
    func availableModels(unit: PricePlan.Unit) -> [String] {
        Array(Set(plan.inference.filter { $0.unit == unit }.map(\.model))).filter { inferenceModels[$0]?.isRetired() != true }.sorted()
    }
    func modelLabel(_ id: String) -> String {
        let info = inferenceModels[id]
        return id + (info?.isRetired() == true ? " · Retired" : info?.deprecated == true ? " · Deprecated" : "") + (info?.eu == true ? " · EU-capable" : "")
    }
    var plan: PricePlan { PricePlan.named(UserDefaults.standard.string(forKey: "pricePlan") ?? PricePlan.scale.id).with(pricing) }

    private static var pricingFile: URL { AppSettings.cacheDirectory.appendingPathComponent("pricing.json") }

    /// Reads the cached price list, then fetches a new one if it is more than a day old. Failures keep what we have.
    func loadPricing() async {
        if let values = await InferenceModels.refresh(cache: AppSettings.cacheDirectory.appendingPathComponent("inference-models.json")) { inferenceModels = values }
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
        refreshTask?.cancel()
        pageTask?.cancel(); recordingTask?.cancel()
        let task = Task { await refreshProject() }
        refreshTask = task
        await task.value
    }

    private func refreshProject() async {
        let generation = UUID()
        let residentLimit = max(100, rows.count)
        refreshGeneration = generation
        loading = true; loadingMore = false; scanningRecordings = false
        defer { if refreshGeneration == generation { loading = false } }
        await captures.load()
        await loadCached(generation: generation, limit: residentLimit)
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        await loadAccount()
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        let override = AppSettings.dashboardProjectId(for: project)
        projectId = override.isEmpty ? selectedProject?.projectId : override
        await loadCached(generation: generation, limit: residentLimit)
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        // Warm the recording index without restoring the old full-bucket scan on refresh.
        scanRecordings(automatic: true)
        guard let cli, project != nil, cliVersion != nil, !Task.isCancelled else { return }
        let identity = projectIdentity, scope = syncScope, query = sessionQuery
        do {
            let previous = try await sessionStore.coverage(scope: scope, query: query)
            let previousIDs = Set(try await sessionStore.page(project: identity, query: query).map { $0.row.id })
            let page = try await cli.sessionPage(query: query)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            try await sessionStore.ingest(page, project: identity, scope: scope, query: query, flagged: flaggedSessions, noted: sessionsWithNotes)
            // The head refresh overlaps a known page: retain the older traversal rather than replaying history.
            if let previous, previous.canResume, !previousIDs.isDisjoint(with: page.sessions.map(\.id)) {
                var updated = previous; updated.fetchedAt = Date(); updated.error = nil
                try await sessionStore.setCoverage(updated, scope: scope, query: query)
            }
            liveKitLoaded = true; liveKitError = nil
            await loadCached(generation: generation, limit: max(100, rows.count))
            // Revisit a bounded number of long-running calls even when they began before the head page.
            let pending = try await sessionStore.unsettled(project: identity)
            var backgroundCLI = cli; backgroundCLI.priority = .background
            for id in pending {
                try Task.checkCancellation()
                if let session = try? await backgroundCLI.session(id) {
                    guard generation == refreshGeneration else { return }
                    try await sessionStore.upsert(session, project: identity, flagged: flaggedSessions.contains(id), noted: sessionsWithNotes.contains(id))
                }
            }
            // Only revisit resources previously opened by a reviewer, at most four per refresh.
            var reconciledCost = false
            for pending in (try await sessionStore.pendingResources(project: identity)) {
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return }
                do {
                    let value = try await backgroundCLI.resource(pending.id, kind: pending.kind)
                    guard generation == refreshGeneration, !Task.isCancelled else { return }
                    try await sessionStore.recordResource(project: identity, id: pending.id, kind: pending.kind, readiness: value.readiness)
                    if pending.kind == .logs, value.readiness.state == .settled {
                        let logs = value.json.items.enumerated().map { LogRecord(json: $1, index: $0) }
                        let name = logs.lazy.compactMap { $0.attributes["lk.agent_name"]?.string }.first { !$0.isEmpty }
                        let count = SessionDetail.lessonFlags(logs: logs, transcript: []).count
                        try await sessionStore.enrich(project: identity, id: pending.id, agent: name, lessonFlags: count)
                    }
                    // At most one already-calculated call is reconciled per refresh. Its saved
                    // partial total is replaced when late resources become available.
                    if !reconciledCost, value.readiness.state == .settled,
                       let usage = try await sessionStore.costUsage(project: identity, id: pending.id), usage.partial,
                       let row = try await sessionStore.page(project: identity, query: query, ids: [pending.id]).first?.row {
                        reconciledCost = true
                        let documents = await SessionResources.load(source: backgroundCLI, id: pending.id)
                        guard generation == refreshGeneration, !Task.isCancelled else { return }
                        let updated = CostUsageSnapshot.make(row: row, documents: documents, plan: plan, priceDate: pricing?.fetched)
                        if documents.values.contains(where: { if case .success = $0 { return true }; return false }) {
                            try await sessionStore.saveCostUsage(project: identity, id: pending.id, usage: updated)
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { try await sessionStore.recordResource(project: identity, id: pending.id, kind: pending.kind, readiness: ResourceReadiness(error: error)) }
            }
            await loadCached(generation: generation, limit: max(100, rows.count))
            if detail?.row.session != nil { reloadObservability() }
            let retention = UserDefaults.standard.integer(forKey: "summaryRetentionDays")
            try await sessionStore.prune(project: identity, before: SessionQuery(days: retention == 0 ? 30 : max(1, retention)).start)
        } catch is CancellationError { return }
        catch {
            guard generation == refreshGeneration else { return }
            liveKitError = (error as? LiveKitCLIError) ?? LiveKitCLIError(kind: .failed, message: error.localizedDescription)
            if var previous = coverage { previous.error = error.localizedDescription; try? await sessionStore.setCoverage(previous, scope: scope, query: query) }
        }
        if generation == refreshGeneration { Task { await loadPricing() } }
    }

    private func loadCached(generation: UUID, limit: Int = 100, after: SessionBookmark? = nil, incomingIDs: [String]? = nil) async {
        let identity = projectIdentity, query = sessionQuery, scope = syncScope
        let search = filter, flagged = onlyFlagged, recorded = onlyWithRecording
        guard project != nil else { return }
        do {
            let local = captures.items.filter { captureMatchesProject($0.session) }.map(\.session)
            if projectedAttachmentRevision[identity] != captures.revision {
                let revision = captures.revision
                try await sessionStore.attach(local, project: identity)
                projectedAttachmentRevision[identity] = revision
            }
            let source = recordingSourceKey
            let restored = incomingIDs == nil && after == nil ? restorationAnchor : nil
            let bookmark = restored.map { SessionBookmark(startedAt: $0.startedAt, id: $0.id + "\u{10FFFF}") }
            var page = try await sessionStore.page(project: identity, query: query, after: incomingIDs == nil ? (after ?? bookmark) : nil, limit: limit,
                                                   search: search, onlyFlagged: flagged, onlyRecording: recorded, recordingSource: source, ids: incomingIDs)
            if let source {
                for i in page.indices {
                    if var recording = page[i].row.recording, let size = try await sessionStore.recordingSize(source: source, key: recording.audioKey) {
                        recording.size = size; page[i].row.recording = recording
                    }
                }
            }
            let knownCoverage = try await sessionStore.coverage(scope: scope, query: query)
            let scan: RecordingScan?
            if let source { scan = try await sessionStore.recordingScan(source: source) } else { scan = nil }
            guard generation == refreshGeneration, identity == projectIdentity, search == filter,
                  flagged == onlyFlagged, recorded == onlyWithRecording, query == sessionQuery, !Task.isCancelled else { return }
            if after == nil { rows = page.map(\.row); agentNames = [:]; lessonFlagCounts = [:] }
            else {
                var merged = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for item in page { merged[item.row.id] = item.row }
                rows = merged.values.sorted { SessionBookmark($0).startedAt == SessionBookmark($1).startedAt ? $0.id > $1.id : SessionBookmark($0).startedAt > SessionBookmark($1).startedAt }
                rows = Array(rows.suffix(1000))
            }
            for item in page { agentNames[item.row.id] = item.agentName; lessonFlagCounts[item.row.id] = item.lessonFlags }
            let ids = Set(rows.map(\.id)); agentNames = agentNames.filter { ids.contains($0.key) }; lessonFlagCounts = lessonFlagCounts.filter { ids.contains($0.key) }
            cachedHasMore = page.count == limit
            coverage = knownCoverage; recordingScan = scan; indexError = nil
            if let saved = savedNavigation?.selection, rows.contains(where: { $0.id == saved }), selection == nil { selection = saved; savedNavigation = nil }
            storageConfigured = source != nil
            if let detail, let updated = rows.first(where: { $0.id == detail.row.id }) { updateOpenRow(updated) }
            if incomingIDs != nil, let last = rows.last {
                let more = try await sessionStore.page(project: identity, query: query, after: SessionBookmark(last), limit: 1,
                                                       search: search, onlyFlagged: flagged, onlyRecording: recorded, recordingSource: source)
                if generation == refreshGeneration, search == filter, query == sessionQuery { cachedHasMore = !more.isEmpty }
            }
        } catch { if generation == refreshGeneration { indexError = "Session index: " + error.localizedDescription } }
    }

    func loadMoreSessions() async {
        guard !loadingMore, !loading else { return }
        let task = Task { await loadNextPage() }
        pageTask = task
        await task.value
    }

    private func loadNextPage() async {
        guard !loadingMore, !loading else { return }
        let last = rows.last
        loadingMore = true
        let generation = refreshGeneration, identity = projectIdentity, scope = syncScope, query = sessionQuery
        defer { if generation == refreshGeneration { loadingMore = false } }
        let count = rows.count, bookmark = last.map(SessionBookmark.init)
        await loadCached(generation: generation, after: bookmark)
        guard generation == refreshGeneration, rows.count == count, rows.last?.id == last?.id,
              let cursor = coverage?.nextCursor, let cli else { return }
        do {
            let page = try await cli.sessionPage(query: query, cursor: cursor)
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            guard page.nextCursor != cursor else { throw LiveKitCLIError(kind: .failed, message: "LiveKit repeated the page cursor. Refresh this range to retry.") }
            try await sessionStore.ingest(page, project: identity, scope: scope, query: query, flagged: flaggedSessions, noted: sessionsWithNotes)
            // A remote traversal is not a snapshot: late arrivals may precede our oldest visible row.
            // Merge those IDs too, rather than silently hiding them behind the local keyset bookmark.
            await loadCached(generation: generation, after: bookmark, incomingIDs: page.sessions.map(\.id))
            liveKitError = nil
        } catch {
            guard generation == refreshGeneration else { return }
            liveKitError = (error as? LiveKitCLIError) ?? LiveKitCLIError(kind: .failed, message: error.localizedDescription)
            if error.localizedDescription.localizedCaseInsensitiveContains("cursor") {
                let invalidated = SessionCoverage(nextCursor: nil, fetchedAt: coverage?.fetchedAt ?? Date(), complete: false, error: error.localizedDescription)
                try? await sessionStore.setCoverage(invalidated, scope: scope, query: query)
                coverage = invalidated
            }
        }
    }

    func captureSession(for row: SessionRow) -> CaptureSession? {
        // An implicit CLI default can change outside the app. Require an explicit project
        // until the ProjectRef foundation can resolve that default authoritatively.
        guard let name = project, !name.isEmpty else { return nil }
        // Keep an existing attachment's target key, so deduplication and paths survive identity migration.
        let existing = captures.items.first { captureMatchesProject($0.session) && $0.session.sessionID == row.id }?.session.projectKey
        return CaptureSession(projectKey: existing ?? projectIdentity, projectName: selectedProject?.name ?? name, sessionID: row.id,
                              roomName: row.roomName, startedAt: row.startedAt, endedAt: row.endedAt)
    }

    private func captureMatchesProject(_ session: CaptureSession) -> Bool {
        session.projectKey == "lk:" + (project ?? "") || session.projectKey == projectIdentity
            || selectedProject?.lkName.map { session.projectKey == "lk:" + $0 } == true
    }

    func mergeLocalCaptureRows() {
        let generation = refreshGeneration
        Task { await loadCached(generation: generation, limit: max(100, rows.count)) }
    }

    /// Unexamined log-derived flags remain unknown until a session is opened.
    func flaggedInLesson(_ row: SessionRow) -> Bool {
        if let detail, detail.row.id == row.id, detail.flags.contains(where: \.isFromLesson) { return true }
        return row.session?.flaggedInLesson == true || (lessonFlagCounts[row.id] ?? 0) > 0
    }

    private var recordingSourceKey: String? {
        let config = AppSettings.storage(for: project)
        guard !config.isEmpty else { return nil }
        return [projectIdentity, config.endpoint, config.bucket, config.prefix].joined(separator: "|")
    }

    /// Explicit, resumable discovery: one small object page and at most two manifest requests at once.
    func scanRecordings(restart: Bool = false, automatic: Bool = false) {
        guard !scanningRecordings else { return }
        let generation = refreshGeneration, identity = projectIdentity
        scanningRecordings = true
        recordingTask = Task {
            defer { if generation == refreshGeneration { scanningRecordings = false } }
            do {
                guard let source = recordingSourceKey, let client = try storageClient() else { return }
                var scan = restart ? RecordingScan() : (try await sessionStore.recordingScan(source: source) ?? RecordingScan())
                if automatic, scan.complete, Date().timeIntervalSince(scan.updatedAt) < 300 { return }
                if scan.complete || restart { scan = RecordingScan(reconciling: true) }
                let page = try await client.listPage(prefix: client.config.prefix, cursor: scan.cursor)
                if let cursor = scan.cursor, page.nextToken == cursor { throw StorageError.message("Storage repeated its cursor. Restart the recording scan to retry.") }
                try Task.checkCancellation()
                var fetched: [(String, EgressRecording?)] = []
                let candidates = page.objects.filter { $0.key.hasSuffix(".json") }
                for pair in stride(from: 0, to: candidates.count, by: 2) {
                    let batch = Array(candidates[pair..<min(pair + 2, candidates.count)])
                    var missing: [StorageObject] = []
                    for object in batch {
                        let known = try await sessionStore.hasManifest(source: source, key: object.key)
                        if !known || scan.reconciling { missing.append(object) }
                    }
                    try await withThrowingTaskGroup(of: (String, EgressRecording?).self) { group in
                        for object in missing { group.addTask { (object.key, EgressRecording(manifest: try JSONValue.parse(try await client.manifest(object.key)))) } }
                        for try await value in group { fetched.append(value) }
                    }
                    try Task.checkCancellation()
                }
                guard generation == refreshGeneration else { return }
                scan.cursor = page.nextToken; scan.complete = page.nextToken == nil; scan.objects += page.objects.count; scan.updatedAt = Date()
                try await sessionStore.saveRecordingPage(source: source, project: identity, objects: page.objects, manifests: fetched, scan: scan)
                recordingScan = scan; storageError = nil
                await loadCached(generation: generation, limit: max(100, rows.count))
                // A selected session can be outside the current filtered or paged list.
                if let detail, let recording = try await sessionStore.recording(project: identity, id: detail.row.id, source: source),
                   generation == refreshGeneration, detail === self.detail {
                    var row = detail.row; row.recording = recording
                    updateOpenRow(row)
                }
            } catch is CancellationError { }
            catch { if generation == refreshGeneration { storageError = "Recording discovery: " + error.localizedDescription } }
        }
    }

    func openIndexedSession(_ row: SessionRow) {
        if !rows.contains(where: { $0.id == row.id }) {
            rows.insert(row, at: 0)
            if rows.count > 1000 { rows.removeLast() }
        }
        section = .sessions; selection = row.id
    }

    func openRemoteSession(_ id: String) async {
        if let row = rows.first(where: { $0.id == id }) { openIndexedSession(row); return }
        guard let cli else { return }; let identity = projectIdentity
        do {
            guard let session = try await cli.session(id) else { throw LiveKitCLIError(kind: .notReady, message: "This session is not available yet. Try again after the call ends.") }
            guard identity == projectIdentity, !Task.isCancelled else { return }
            if !rows.contains(where: { $0.id == id }) { rows.insert(SessionRow(id: id, session: session), at: 0); if rows.count > 1000 { rows.removeLast() } }
            section = .sessions; selection = id
        } catch { if identity == projectIdentity { operations.error = error.localizedDescription } }
    }

    func openSimulation(_ job: SimulationJob, run: SimulationRun, export: JSONValue?) {
        detailTask?.cancel(); audioTask?.cancel(); analysisTask?.cancel(); selection = nil
        let row = SessionRow(id: "simulation:\(projectIdentity):\(run.id):\(job.id)")
        let review = SessionDetail(row: row); review.simulationJudge = job; review.dataState = "settled"
        let history = export?["summary"]?.field("chatHistory")?[job.id]?["items"]?.array ?? []
        review.transcript = history.enumerated().map { index, item in
            var normalized: [String: JSONValue] = ["id": .string(item.text("id").isEmpty ? "simulation-item-\(index)" : item.text("id"))]
            for key in ["message", "functionCall", "functionCallOutput", "agentHandoff", "agentConfigUpdate"] {
                guard let value = item.field(key) else { continue }
                var payload = value.object ?? [:]
                if key == "message" {
                    payload["text"] = .string((value["content"]?.array ?? []).compactMap { $0["text"]?.string ?? $0.string }.joined(separator: "\n"))
                }
                normalized[key] = .object(payload)
                if let date = value.field("createdAt") { normalized["timestamp"] = date }
            }
            return TranscriptItem(json: .object(normalized), index: index)
        }
        review.insights = SessionInsights(transcript: review.transcript, logs: [], spans: [])
        detail = review; section = .sessions
    }

    private func openSelection() {
        detailTask?.cancel(); audioTask?.cancel(); analysisTask?.cancel()
        player.unload()
        if let previous = detail { noteFlags(of: previous) }
        guard let selection, let row = rows.first(where: { $0.id == selection }) else { detail = nil; return }
        let detail = SessionDetail(row: row)
        self.detail = detail
        reloadAudio()
        let identity = projectIdentity
        detailTask = Task {
            detail.aiReview = try? await AIReviewStore.shared.load(project: identity, session: detail.row.id)
            if let data = try? await AudioAIStore.shared.load(project: identity, session: detail.row.id, name: "transcription-comparison.json") {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                detail.transcriptionComparisons = (try? decoder.decode([TranscriptionComparison].self, from: data)) ?? []
            }
            await loadObservability(detail)
        }
    }

    func reloadObservability() {
        guard let detail else { return }
        Task { await loadObservability(detail) }
    }

    private func loadObservability(_ detail: SessionDetail) async {
        guard detail === self.detail, !Task.isCancelled else { return }
        guard let cli, detail.row.session != nil else {
            detail.insights = SessionInsights(transcript: [], logs: [], spans: [])
            detail.observabilityError = detail.row.session == nil
                ? LiveKitCLIError(kind: .failed, message: "LiveKit session data is unavailable. Local recordings and imported captures remain accessible.")
                : liveKitError
            return
        }
        detail.loadingObservability = true
        defer { detail.loadingObservability = false }
        let id = detail.row.id, identity = projectIdentity
        let results = await SessionResources.load(source: cli, id: id)
        guard detail === self.detail, identity == projectIdentity, !Task.isCancelled else { return }
        for (kind, result) in results {
            switch result {
            case .success(let document):
                let json = document.json
                var readiness = document.readiness
                if kind == .summary, readiness.state == .unknown, let session = LiveKitSession(json: json["session"] ?? json) {
                    readiness.state = session.status == "active" ? .pending : .settled
                }
                detail.resourceStates[kind] = readiness
                switch kind {
                case .transcript: detail.transcript = json.items.enumerated().map { TranscriptItem(json: $1, index: $0) }; detail.dataState = readiness.state.rawValue
                case .logs: detail.logs = json.items.enumerated().map { LogRecord(json: $1, index: $0) }
                case .traces: detail.spans = json.items.enumerated().map { Span(json: $1, index: $0) }
                case .metrics: detail.metrics = json.items.enumerated().map { MetricPoint(json: $1, index: $0) }
                case .summary: detail.room = RoomUsage(json: json)
                case .recording: break
                }
            case .failure(let error): detail.resourceStates[kind] = ResourceReadiness(error: error)
            }
            if let state = detail.resourceStates[kind] { try? await sessionStore.recordResource(project: identity, id: id, kind: kind, readiness: state) }
        }
        guard detail === self.detail, identity == projectIdentity, !Task.isCancelled else { return }
        detail.insights = SessionInsights(transcript: detail.transcript, logs: detail.logs, spans: detail.spans)
        detail.applyLessonFlags()
        let count = detail.flags.filter(\.isFromLesson).count
        let name = detail.logs.lazy.compactMap { $0.attributes["lk.agent_name"]?.string }.first { !$0.isEmpty }
        if detail.resourceStates[.logs]?.state == .settled { lessonFlagCounts[id] = count }
        agentNames[id] = name
        try? await sessionStore.enrich(project: identity, id: id, agent: name, lessonFlags: detail.resourceStates[.logs]?.state == .settled ? count : nil)
        if detail.row.startedAt != nil {
            let usage = CostUsageSnapshot.make(row: detail.row, documents: results, plan: plan, priceDate: pricing?.fetched)
            try? await sessionStore.saveCostUsage(project: identity, id: id, usage: usage)
        }
        let failures = detail.resourceStates.values.compactMap(\.message)
        detail.observabilityError = failures.isEmpty ? nil : LiveKitCLIError(kind: .failed, message: failures.joined(separator: "\n"))
    }

    /// Keep the selected review open when its egress manifest arrives after its summary.
    @discardableResult func updateOpenRow(_ row: SessionRow) -> Task<Void, Never>? {
        guard let detail, detail.row.id == row.id else { return nil }
        let changed = detail.row.recording != row.recording
        detail.row = row
        guard changed else { return nil }
        analysisTask?.cancel()
        for source in detail.sources where source.kind == .egress { spectrogramCache.removeValue(forKey: source.file) }
        detail.spectrograms.removeValue(forKey: .egress)
        detail.spectrogramErrors.removeValue(forKey: .egress)
        return reloadAudio()
    }

    @discardableResult func reloadAudio() -> Task<Void, Never>? {
        guard let detail else { return nil }
        let previous = audioTask
        previous?.cancel()
        let task = Task {
            // Serialize replacement loads so cancelled downloads/decoders cannot overwrite new media.
            await previous?.value
            guard !Task.isCancelled, detail === self.detail else { return }
            await loadAudio(detail)
        }
        audioTask = task
        return task
    }

    /// Downloads both sources and loads their channels. LiveKit's duplicate audio starts muted.
    func loadAudio(_ detail: SessionDetail) async {
        guard detail === self.detail, !Task.isCancelled else { return }
        detail.loadingAudio = true
        defer { detail.loadingAudio = false }
        let mediaProject = projectIdentity
        detail.audioError = nil; detail.egressError = nil
        if detail.row.recording == nil, let source = recordingSourceKey {
            do {
                let recording = try await sessionStore.recording(project: mediaProject, id: detail.row.id, source: source)
                guard detail === self.detail, !Task.isCancelled else { return }
                detail.row.recording = recording
            } catch { detail.egressError = "Could not read the egress recording index: \(error.localizedDescription)" }
        }
        let filesToPin = [observabilityFile(detail.row.id)] + (detail.row.recording.map { [egressFile($0)] } ?? [])
        await MediaCache.shared.pin(filesToPin, lease: detail.mediaLease)
        async let egress = egressSource(detail)
        async let observability = observabilitySource(detail)
        let found = await [egress, observability].compactMap { $0 }
        guard detail === self.detail, !Task.isCancelled else { return }
        detail.sources = found
        detail.audioRevision += 1
        guard !found.isEmpty else {
            if detail.audioError == nil { detail.audioError = "No recording for this session." }
            return
        }
        var tracks: [PlaybackTrack] = []
        for source in found {
            let files = (try? await MediaResources.compute(project: mediaProject) { try PlaybackFile.channels(source.file) }) ?? []
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
        let moment = player.currentDate, wasPlaying = player.isPlaying
        player.load(tracks, muted: duplicate)
        if let moment, let origin = player.origin { player.seek(to: moment.timeIntervalSince(origin)) }
        if wasPlaying { player.play() }
        try? await MediaCache.shared.prune(root: mediaCacheDirectory)
    }

    private func egressSource(_ detail: SessionDetail) async -> RecordingSource? {
        guard let recording = detail.row.recording else { return nil }
        do {
            let file = egressFile(recording)
            let cachedSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if cachedSize == nil || cachedSize == 0 || (recording.size > 0 && cachedSize != recording.size) {
                guard let client = try storageClient() else { throw StorageError.message("Egress storage is not set up for this project.") }
                try await MediaResources.downloads.perform(project: projectIdentity) { try await client.download(recording.audioKey, to: file) }
            }
            return RecordingSource(kind: .egress, file: file, origin: recording.startedAt,
                                   userLeftAgentRight: AppSettings.storage(for: project).userLeftAgentRight)
        } catch is CancellationError { return nil }
        catch {
            detail.audioError = "Could not download the egress recording: \(error.localizedDescription)"
            detail.egressError = detail.audioError
            return nil
        }
    }

    /// Where an egress recording is cached once downloaded.
    func egressFile(_ recording: EgressRecording) -> URL {
        let root = mediaCacheDirectory.appendingPathComponent("recordings")
        let identity = AppSettings.key(for: project)
        let name = recording.audioKey.replacingOccurrences(of: "/", with: "_")
        let current = root.appendingPathComponent(identity, isDirectory: true).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: current.path) { return current }
        // The project-ID migration copied settings, but existing audio stayed under the old name.
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: "storageSecretAlias." + identity),
           defaults.string(forKey: "projectIdentity." + legacy) == identity,
           let data = defaults.data(forKey: "storage." + legacy),
           let old = try? JSONDecoder().decode(StorageSettings.self, from: data) {
            let settings = AppSettings.storage(for: project)
            let file = root.appendingPathComponent(legacy, isDirectory: true).appendingPathComponent(name)
            if old.endpoint == settings.endpoint, old.region == settings.region, old.bucket == settings.bucket,
               old.prefix == settings.prefix, FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return current
    }

    /// Where LiveKit's session recording is cached once downloaded.
    private func observabilityFile(_ sessionId: String) -> URL {
        mediaCacheDirectory.appendingPathComponent("livekit").appendingPathComponent("\(sessionId).ogg")
    }

    /// LiveKit's session recording, downloaded because its link expires and the spectrogram needs the file.
    private func observabilitySource(_ detail: SessionDetail) async -> RecordingSource? {
        guard detail.row.session != nil, let cli else { return nil }
        let identity = projectIdentity
        let file = observabilityFile(detail.row.id)
        let marker = file.appendingPathExtension("json")
        // A settled recording never changes, so reuse it with its saved start time.
        if let saved = try? JSONValue.parse(Data(contentsOf: marker)), FileManager.default.fileExists(atPath: file.path) {
            detail.resourceStates[.recording] = ResourceReadiness(state: .settled)
            return RecordingSource(kind: .observability, file: file, origin: saved["startedAt"]?.date)
        }
        do {
            let document = try await cli.resource(detail.row.id, kind: .recording)
            let state = document.readiness
            detail.resourceStates[.recording] = state
            try? await sessionStore.recordResource(project: identity, id: detail.row.id, kind: .recording, readiness: state)
            guard let link = document.json["url"]?.string, let url = URL(string: link), ["https", "http"].contains(url.scheme) else { return nil }
            let recording = (url: url, startedAt: document.json["recordingStartedAt"]?.date, settled: state.state == .settled)
            let (download, response) = try await MediaResources.downloads.perform(project: projectIdentity) { try await URLSession.shared.download(from: recording.url) }
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
            let state = ResourceReadiness(error: error)
            detail.resourceStates[.recording] = state
            try? await sessionStore.recordResource(project: identity, id: detail.row.id, kind: .recording, readiness: state)
            return nil
        }
    }

    /// Computes a spectrogram for each recording of the session that does not have one yet.
    func analyze(_ detail: SessionDetail) async {
        let previous = analysisTask
        previous?.cancel()
        let task = Task {
            // A new source can arrive while SwiftUI cancels the preceding analysis task.
            // Let it clear its in-flight markers before deciding which lanes still need work.
            await previous?.value
            guard detail === self.detail, !Task.isCancelled else { return }
            await computeSpectrograms(detail)
        }
        analysisTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func computeSpectrograms(_ detail: SessionDetail) async {
        let mediaProject = projectIdentity
        await withTaskGroup(of: Void.self) { group in
            for source in detail.sources where detail.spectrograms[source.kind] == nil && !detail.analyzing.contains(source.kind) {
                if let cached = spectrogramCache[source.file] { detail.spectrograms[source.kind] = cached; continue }
                detail.analyzing.insert(source.kind)
                group.addTask { @MainActor in
                    defer { detail.analyzing.remove(source.kind) }
                    do {
                        let spectrogram = try await MediaResources.compute(project: mediaProject) { try Spectrogram.compute(file: source.file) }
                        try Task.checkCancellation()
                        guard detail === self.detail else { return }
                        detail.spectrograms[source.kind] = spectrogram
                        if self.spectrogramCache.count >= 6 || self.spectrogramCache.values.reduce(0, { $0 + $1.byteCount }) + spectrogram.byteCount > 64 * 1024 * 1024 { self.spectrogramCache.removeAll() }
                        if spectrogram.byteCount <= 64 * 1024 * 1024 { self.spectrogramCache[source.file] = spectrogram }
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
                  WindowContext.shared.active === self,
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
        projectFlagsChanged(id)
    }

    /// Whether a session has flags with notes; the open session is read live so the list updates as you flag.
    func hasNotes(_ id: String) -> Bool {
        if let detail, detail.row.id == id { return detail.flags.contains { !$0.isFromLesson } }
        return sessionsWithNotes.contains(id)
    }

    func noteFlags(of detail: SessionDetail) {
        guard detail === self.detail else { return }
        if detail.flags.allSatisfy(\.isFromLesson) { sessionsWithNotes.remove(detail.row.id) } else { sessionsWithNotes.insert(detail.row.id) }
        projectFlagsChanged(detail.row.id)
    }

    private func projectFlagsChanged(_ id: String) {
        let project = projectIdentity, flagged = isFlagged(id), noted = sessionsWithNotes.contains(id)
        let reference = rows.first(where: { $0.id == id }).flatMap { captureSession(for: $0) }.map { AnnotationReference(project: project, session: $0, flagged: flagged, noted: noted) }
        Task {
            if let reference { try? await AnnotationStore.shared.save(reference) }
            try? await sessionStore.setFlags(project: project, id: id, flagged: flagged, noted: noted)
            if project == projectIdentity, onlyFlagged { scheduleCachedQuery() }
        }
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
        // Freeze all project-sensitive inputs before presenting the panel or awaiting I/O.
        let exportCLI = cli
        let exportProject = projectIdentity
        let exportCaptures = captures.captures(for: captureSession(for: row))
        let recordings: [(source: URL, name: String)] = [(observabilityFile(row.id), "livekit-recording.ogg")]
            + (row.recording.map { recording in
                let file = egressFile(recording)
                return [(file, "egress-recording." + (file.pathExtension.isEmpty ? "audio" : file.pathExtension))]
            } ?? [])
        let open = detail?.row.id == row.id ? detail : nil
        let flags = open?.flags ?? SessionDetail.loadFlags(row.id)
        let report = open.flatMap { detail in detail.insights.map {
            SessionReport.markdown(row: detail.row, transcript: detail.transcript, insights: $0,
                                   origin: player.origin ?? detail.row.startedAt, flags: flags, logs: detail.logs, spans: detail.spans)
        } }
        let panel = NSSavePanel()
        panel.title = "Save Session Data"
        panel.message = "Saves a folder with the session's transcript, logs, traces, metrics, recordings, and flags."
        panel.nameFieldStringValue = Self.folderName(for: row)
        panel.canCreateDirectories = true
        let includeCaptures = NSButton(checkboxWithTitle: "Include \(exportCaptures.count) imported packet capture(s)", target: nil, action: nil)
        includeCaptures.state = .off
        includeCaptures.isEnabled = !exportCaptures.isEmpty
        panel.accessoryView = includeCaptures
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let selectedCaptures = includeCaptures.state == .on ? exportCaptures : []
        savingSessions.insert(row.id)
        Task {
            defer { savingSessions.remove(row.id) }
            do {
                if let review = try await AIReviewStore.shared.load(project: exportProject, session: row.id) {
                    let directory = folder.appendingPathComponent("ai", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(review).write(to: directory.appendingPathComponent("review.json"), options: .atomic)
                }
                try await AudioAIStore.shared.export(project: exportProject, session: row.id, to: folder.appendingPathComponent("ai/audio", isDirectory: true))
                let skipped = try await writeSessionData(row, to: folder, exportCLI: exportCLI, recordings: recordings,
                                                        flags: flags, report: report, packetCaptures: selectedCaptures)
                UserDefaults.standard.set(folder.path, forKey: Self.savedFolderKey(row.id))
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                if !skipped.isEmpty { saveMessage = "Saved, without:\n" + skipped.joined(separator: "\n") }
            } catch {
                saveMessage = "Could not save the session data: \(error.localizedDescription)"
            }
        }
    }

    /// Writes the session's files into `folder` and returns what it left out and why.
    private func writeSessionData(_ row: SessionRow, to folder: URL, exportCLI: LiveKitCLI?,
                                  recordings: [(source: URL, name: String)], flags: [Flag], report: String?,
                                  packetCaptures: [PacketCapture]) async throws -> [String] {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var skipped: [String] = []

        if row.session != nil, let exportCLI {
            let raw = await exportCLI.rawSessionData(row.id)
            for file in raw.files { try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic) }
            skipped += raw.failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        } else if row.session == nil {
            skipped.append("LiveKit data: this session is available locally only.")
        } else {
            skipped.append("LiveKit data: \(liveKitError?.message ?? "lk is not available.")")
        }

        // Recordings are copied only once downloaded, which opening the session does.
        for recording in recordings {
            guard files.fileExists(atPath: recording.source.path) else {
                if row.session != nil || recording.name.hasPrefix("egress") { skipped.append("\(recording.name): not downloaded. Open the session first to download it, if there is one.") }
                continue
            }
            let destination = folder.appendingPathComponent(recording.name)
            try? files.removeItem(at: destination)
            try files.copyItem(at: recording.source, to: destination)
        }

        if !flags.isEmpty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(flags).write(to: folder.appendingPathComponent("flags.json"), options: .atomic)
        }
        if let report {
            try Data(report.utf8).write(to: folder.appendingPathComponent("report.md"), options: .atomic)
        }
        if !packetCaptures.isEmpty {
            do { try await captures.store.export(packetCaptures, to: folder.appendingPathComponent("packet-captures", isDirectory: true)) }
            catch { skipped.append("Packet captures: \(error.localizedDescription)") }
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
