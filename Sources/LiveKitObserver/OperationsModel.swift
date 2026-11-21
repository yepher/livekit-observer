import ObserverCore
import AppKit
import Observation

struct OperationConfirmation: Identifiable {
    let id = UUID()
    let projectID: String, projectName: String, title: String, explanation: String
    let protected: Bool
    let arguments: [String]
}

struct SimulationRerun: Identifiable {
    let id = UUID()
    let projectID: String, projectName: String, agent: String, mode: String
    let file: URL
    let count: Int
}

@MainActor @Observable
final class OperationsModel {
    var agents: [CloudAgent] = []
    var runs: [SimulationRun] = []
    var rooms: [LiveRoom] = []
    var versions: [AgentVersion] = []
    var secrets: [String] = []
    var participants: [LiveParticipant] = []
    var run: SimulationRun?
    var export: JSONValue?
    var referencedVersion: String?
    var selectedAgent: String?
    var selectedRun: String?
    var selectedRoom: String?
    var loading = false
    var loadingDetail = false
    var mutating = false
    var error: String?
    var detailError: String?
    var updatedAt: Date?
    var nextRunCursor: String?
    var confirmation: OperationConfirmation?
    var rerun: SimulationRerun?
    var simulationProgress: String?
    private var simulationTask: Task<Void, Never>?
    private(set) var projectID = ""
    private(set) var cli: LiveKitCLI?
    private var generation = UUID()
    private var source: (any OperationsSource)?

    init(source: (any OperationsSource)? = nil) { self.source = source }

    func configure(cli: LiveKitCLI?, projectID: String) {
        guard projectID != self.projectID || cli?.executable != self.cli?.executable else { return }
        generation = UUID(); self.projectID = projectID; self.cli = cli; self.source = cli
        agents = []; runs = []; rooms = []; versions = []; secrets = []; participants = []
        referencedVersion = nil; selectedAgent = nil; selectedRun = nil; selectedRoom = nil; run = nil; export = nil
        error = nil; detailError = nil; updatedAt = nil; nextRunCursor = nil; confirmation = nil; rerun = nil
        loading = false; loadingDetail = false
    }

    func watch(_ section: AppSection) async {
        guard section != .sessions else { return }
        while !Task.isCancelled {
            await refresh(section)
            do { try await Task.sleep(for: .seconds(section == .rooms ? 5 : section == .agents ? 60 : 15)) }
            catch { return }
        }
    }

    func refresh(_ section: AppSection, older: Bool = false) async {
        guard let source, !loading else { return }
        let token = generation; loading = true
        defer { if token == generation { loading = false } }
        do {
            switch section {
            case .sessions: return
            case .agents:
                let value = try await source.agents()
                try Task.checkCancellation(); guard token == generation else { return }; agents = value
            case .rooms:
                let value = try await source.rooms()
                try Task.checkCancellation(); guard token == generation else { return }; rooms = value
            case .simulations:
                let cursor = older ? nextRunCursor : nil
                let page = try await source.simulationRuns(cursor: cursor)
                try Task.checkCancellation(); guard token == generation else { return }
                let values = page.runs
                // Preserve previously loaded pages on head refresh; at most 500 summaries.
                var merged = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for value in values { merged[value.id] = value }
                runs = Array(merged.values.sorted { ($0.createdAt ?? .distantPast, $0.id) > ($1.createdAt ?? .distantPast, $1.id) }.prefix(500))
                if older || nextRunCursor == nil { nextRunCursor = page.nextCursor }
            }
            error = nil; updatedAt = .now
        } catch is CancellationError {} catch { if token == generation { self.error = error.localizedDescription } }
    }

    func loadAgent() async {
        guard let source, let id = selectedAgent else { return }; let token = generation
        versions = []; secrets = []; detailError = nil; loadingDetail = true
        defer { if token == generation, id == selectedAgent { loadingDetail = false } }
        do {
            async let versionResult: Result<[AgentVersion], Error> = capture { try await source.agentVersions(id) }
            async let secretResult: Result<[String], Error> = capture { try await source.agentSecrets(id) }
            let (loadedVersions, loadedSecrets) = await (versionResult, secretResult)
            try Task.checkCancellation(); guard token == generation, id == selectedAgent else { return }
            var errors: [String] = []
            switch loadedVersions { case .success(let values): versions = values; case .failure(let error): errors.append("Versions: " + error.localizedDescription) }
            switch loadedSecrets { case .success(let values): secrets = values; case .failure(let error): errors.append("Secret names: " + error.localizedDescription) }
            detailError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        } catch is CancellationError {} catch { if token == generation, id == selectedAgent { detailError = error.localizedDescription } }
    }

    private func capture<T>(_ action: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await action()) } catch { return .failure(error) }
    }

    func loadRun() async {
        guard let source, let id = selectedRun else { return }; let token = generation
        run = nil; export = nil; detailError = nil; loadingDetail = true
        defer { if token == generation, id == selectedRun { loadingDetail = false } }
        do {
            let value = try await source.simulation(id)
            try Task.checkCancellation(); guard token == generation, id == selectedRun else { return }; run = value
        } catch is CancellationError {} catch { if token == generation, id == selectedRun { detailError = error.localizedDescription } }
    }

    func loadExport() async {
        guard let source, let run, run.finished else { return }; let token = generation
        loadingDetail = true
        defer { if token == generation { loadingDetail = false } }
        do {
            let value = try await source.simulationExport(run.id)
            try Task.checkCancellation(); guard token == generation, selectedRun == run.id else { return }
            export = value; detailError = nil
        } catch is CancellationError {} catch { if token == generation { detailError = error.localizedDescription } }
    }

    func watchRoom() async {
        guard let source, let id = selectedRoom, let room = rooms.first(where: { $0.id == id }) else { return }
        let token = generation; participants = []; detailError = nil
        while !Task.isCancelled {
            loadingDetail = true
            do {
                let values = try await source.participants(room: room.name)
                try Task.checkCancellation(); guard token == generation, id == selectedRoom else { return }
                participants = values; detailError = nil
            } catch is CancellationError { return } catch { if token == generation, id == selectedRoom { detailError = error.localizedDescription } }
            guard token == generation, id == selectedRoom else { return }; loadingDetail = false
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func confirm(_ title: String, explanation: String, arguments: [String], project: ProjectRef) {
        guard project.id == projectID else { return }
        confirmation = OperationConfirmation(projectID: project.id, projectName: project.name, title: title,
                                               explanation: explanation, protected: project.protected, arguments: arguments)
    }

    func prepareRerun(failedOnly: Bool, project: ProjectRef) async {
        guard let run, run.finished, project.id == projectID else { return }
        let token = generation
        do {
            let prepared = try await ScenarioWriter.shared.rerunFile(run, failedOnly: failedOnly, directory: AppSettings.cacheDirectory.appendingPathComponent("SimulationRuns"))
            guard token == generation else { try? FileManager.default.removeItem(at: prepared.0); return }
            rerun = SimulationRerun(projectID: projectID, projectName: project.name, agent: run.agentName,
                                     mode: run.mode == "audio" ? "audio" : "text", file: prepared.0, count: prepared.1)
        } catch { self.error = error.localizedDescription }
    }

    func startRerun(_ request: SimulationRerun) {
        guard let cli, request.projectID == projectID, simulationTask == nil else { return }
        rerun = nil; simulationProgress = "Running \(request.count) \(request.mode) scenarios in \(request.projectName)…"
        simulationTask = Task {
            defer { simulationTask = nil; try? FileManager.default.removeItem(at: request.file) }
            do {
                _ = try await cli.operation(["agent", "simulate", "--scenarios", request.file.path, "--agent-name", request.agent, "--concurrency", "2", "--yes", request.mode], json: false, timeout: 3600)
                simulationProgress = "Simulation finished in \(request.projectName). Refresh runs to review the results."
                if request.projectID == projectID { await refresh(.simulations) }
            } catch { simulationProgress = "Simulation command ended: \(error.localizedDescription). Refresh runs to check its Cloud status." }
        }
    }

    func perform(_ request: OperationConfirmation, section: AppSection) async {
        guard let cli, projectID == request.projectID, !mutating else { return }
        let token = generation; mutating = true; confirmation = nil
        defer { mutating = false }
        do {
            _ = try await cli.operation(request.arguments, json: false)
            guard token == generation else { return }
            await refresh(section)
            if section == .agents { await loadAgent() }
            if section == .simulations { await loadRun() }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
}
