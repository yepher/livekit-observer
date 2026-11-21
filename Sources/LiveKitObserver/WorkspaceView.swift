import ObserverCore
import SwiftUI

@MainActor @Observable
final class WorkspaceModel {
    enum Tab: String, CaseIterable { case sessions = "Sessions", flagged = "Flagged", agents = "Agents", simulations = "Simulations", rooms = "Rooms", cost = "Cost" }
    var tab = Tab.sessions
    var selected: Set<String> = []
    var search = ""
    var rows: [SessionStore.WorkspaceRow] = []
    var costs: [SessionStore.CostRollup] = []
    var agents: [(ProjectRef, CloudAgent)] = []
    var runs: [(ProjectRef, SimulationRun)] = []
    var rooms: [(ProjectRef, LiveRoom)] = []
    var errors: [String: String] = [:]
    var coverage: [String: SessionCoverage] = [:]
    var working = false
    var olderIndexed = false
    let query = SessionQuery()
    private var work: Task<Void, Never>?
    private var generation = UUID()
    let store: SessionStore
    init(store: SessionStore = .shared) { self.store = store }
    func cancel() { generation = UUID(); work?.cancel(); work = nil; working = false }
    func refresh(app: AppModel, remote: Bool = false, next: Bool = false) {
        cancel(); let token = generation, ids = Array(selected.prefix(20)), tab = tab, query = query
        let projects = app.projects.filter { ids.contains($0.id) }, search = search
        let base = app.cli
        let scope = "workspace:" + (app.signedInUser ?? "signed-out")
        let flagged = app.flaggedSessions, noted = app.sessionsWithNotes
        working = true
        work = Task {
            defer { if token == generation { working = false } }
            do {
                if tab == .sessions || tab == .flagged || tab == .cost {
                    let initial = try await store.workspacePage(projects: ids, query: query, onlyFlagged: tab == .flagged, search: search)
                    guard token == generation else { return }; rows = initial; olderIndexed = initial.count == 100
                    costs = try await store.costs(projects: ids, since: query.startDay)
                    for project in projects { coverage[project.id] = try await store.coverage(scope: scope + ":" + project.id, query: query) }
                    if !remote { return }
                }
                guard let base else { throw LiveKitCLIError(kind: .failed, message: "Install or configure lk to refresh Cloud data. Cached sessions remain available.") }
                let store = self.store
                for start in stride(from: 0, to: projects.count, by: 2) {
                    try Task.checkCancellation()
                    let batch = projects[start..<min(start + 2, projects.count)]
                    await withTaskGroup(of: (ProjectRef, Result<Payload, Error>).self) { group in
                        for project in batch {
                            let cursor = next ? coverage[project.id]?.nextCursor : nil
                            if next && coverage[project.id]?.complete == true { continue }
                            group.addTask {
                                let cli = LiveKitCLI(executable: base.executable, project: project.projectId ?? project.selection, priority: .background)
                                do {
                                    switch tab {
                                    case .sessions, .flagged, .cost:
                                        let page = try await cli.sessionPage(query: query, cursor: cursor)
                                        try await store.ingest(page, project: project.id, scope: scope + ":" + project.id, query: query, flagged: flagged, noted: noted)
                                        return (project, .success(.sessions(try await store.coverage(scope: scope + ":" + project.id, query: query))))
                                    case .agents: return (project, .success(.agents(try await cli.agents())))
                                    case .simulations: return (project, .success(.runs(try await cli.operationJSON(["agent", "simulate", "list", "--json"]).items.compactMap(SimulationRun.init))))
                                    case .rooms: return (project, .success(.rooms(try await cli.rooms())))
                                    }
                                } catch { return (project, .failure(error)) }
                            }
                        }
                        for await (project, result) in group {
                            guard token == generation else { continue }
                            switch result {
                            case .failure(let error): errors[project.id] = error.localizedDescription
                            case .success(let payload):
                                errors.removeValue(forKey: project.id)
                                switch payload {
                                case .sessions(let value): coverage[project.id] = value
                                case .agents(let values): agents.removeAll { $0.0.id == project.id }; agents += values.map { (project, $0) }
                                case .runs(let values): runs.removeAll { $0.0.id == project.id }; runs += values.prefix(10).map { (project, $0) }
                                case .rooms(let values): rooms.removeAll { $0.0.id == project.id }; rooms += values.map { (project, $0) }
                                }
                            }
                        }
                    }
                }
                if tab == .sessions || tab == .flagged || tab == .cost {
                    let values = try await store.workspacePage(projects: ids, query: query, onlyFlagged: tab == .flagged, search: search)
                    guard token == generation else { return }; rows = values; olderIndexed = values.count == 100
                }
            } catch is CancellationError {} catch { if token == generation { errors["index"] = error.localizedDescription } }
        }
    }
    private enum Payload: Sendable { case sessions(SessionCoverage?), agents([CloudAgent]), runs([SimulationRun]), rooms([LiveRoom]) }
    func older() async {
        guard !working, let last = rows.last, rows.count < 1000 else { return }
        let token = generation; working = true
        defer { if token == generation { working = false } }
        do {
            let values = try await store.workspacePage(projects: Array(selected), query: query, after: last, onlyFlagged: tab == .flagged, search: search)
            guard token == generation else { return }; rows += values; olderIndexed = values.count == 100 && rows.count < 1000
        } catch { errors["index"] = error.localizedDescription }
    }
}

struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = WorkspaceModel()
    @State private var choosing = false
    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workspace").font(.title2.bold()); Text("\(workspace.selected.count) projects").foregroundStyle(.secondary)
                Spacer()
                Menu("Workspace") {
                    Button("All accessible projects") { app.workspaceFilter = nil; chooseWorkspace(nil) }
                    ForEach(Array(Set(app.projects.compactMap(\.workspaceID))).sorted(), id: \.self) { id in
                        Button(app.projects.first { $0.workspaceID == id }?.workspaceName ?? id) { app.workspaceFilter = id; chooseWorkspace(id) }
                    }
                }
                Button("Choose projects…") { choosing = true }
                Button("Refresh") { workspace.refresh(app: app, remote: true) }.disabled(workspace.working)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("View", selection: $workspace.tab) { ForEach(WorkspaceModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Text("Last 30 days · Indexed summaries and explicitly reviewed costs. Coverage may be partial; unread log flags and missing costs are unknown.").font(.caption).foregroundStyle(.secondary)
            if workspace.tab == .sessions || workspace.tab == .flagged {
                TextField("Search indexed room prefix or session ID", text: $workspace.search)
                WorkspaceSessionList(workspace: workspace, name: name, open: open)
                HStack {
                    Button("Older indexed sessions") { Task { await workspace.older() } }.disabled(!workspace.olderIndexed || workspace.working)
                    Button("Index next page per project") { workspace.refresh(app: app, remote: true, next: true) }.disabled(workspace.working)
                    Spacer(); Text("\(workspace.rows.count) shown · 1,000-row limit").font(.caption)
                }
            } else if workspace.tab == .cost {
                List(workspace.costs) { item in
                    HStack {
                        Text(name(item.project)).frame(width: 150, alignment: .leading)
                        Text(item.day); Spacer(); Text(Format.dollars(item.estimate))
                        Text("\(item.reviewed) reviewed · \(item.partial) partial").foregroundStyle(.secondary)
                    }
                }
                Text("Calculated calls only; missing calls are unknown. Overage-rate estimates in UTC days, not invoices. Repricing uses stored usage without fetching calls.").font(.caption).foregroundStyle(.secondary)
                CostHistoryControls(projects: app.projects.filter { workspace.selected.contains($0.id) }) {
                    workspace.refresh(app: app)
                }
            } else if workspace.tab == .agents {
                List(Array(workspace.agents.filter { workspace.selected.contains($0.0.id) }.enumerated()), id: \.offset) { _, pair in
                    HStack { Text(pair.0.name).frame(width: 150, alignment: .leading); Text(pair.1.title); Spacer(); Text(pair.1.version); Text(pair.1.status).foregroundStyle(pair.1.healthy ? .green : .secondary) }
                        .contentShape(Rectangle()).onTapGesture { app.selectProject(pair.0.selection); app.section = .agents; dismiss() }
                }
            } else if workspace.tab == .simulations {
                List(Array(workspace.runs.filter { workspace.selected.contains($0.0.id) }.enumerated()), id: \.offset) { _, pair in
                    HStack { Text(pair.0.name).frame(width: 150, alignment: .leading); Text(pair.1.agentName); Text(pair.1.status); Spacer(); Text("\(pair.1.passed.map(String.init) ?? "?") passed · \(pair.1.failed.map(String.init) ?? "?") failed") }
                        .contentShape(Rectangle()).onTapGesture { app.selectProject(pair.0.selection); app.section = .simulations; dismiss() }
                }
            } else {
                List(Array(workspace.rooms.filter { workspace.selected.contains($0.0.id) }.enumerated()), id: \.offset) { _, pair in
                    HStack { Text(pair.0.name).frame(width: 150, alignment: .leading); Text(pair.1.name); Spacer(); Text("\(pair.1.participants) participants") }
                        .contentShape(Rectangle()).onTapGesture { app.selectProject(pair.0.selection); app.section = .rooms; dismiss() }
                }
            }
            DisclosureGroup("Coverage and errors") {
                ScrollView {
                    ForEach(app.projects.filter { workspace.selected.contains($0.id) }) { project in
                        HStack {
                            Text(project.name); Spacer()
                            Text(coverageText(project.id)).foregroundStyle(workspace.errors[project.id] == nil ? Color.secondary : Color.orange)
                        }.font(.caption)
                    }
                    if let error = workspace.errors["index"] { Text(error).foregroundStyle(.orange) }
                }.frame(maxHeight: 120)
            }
            if workspace.working { HStack { ProgressView().controlSize(.small); Button("Stop") { workspace.cancel() } } }
        }.padding(20).frame(width: 1000, height: 650)
        .onAppear {
            let saved = UserDefaults.standard.stringArray(forKey: "workspaceProjects") ?? []
            let recent = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
            let available = Set(app.projects.map(\.id))
            workspace.selected = Set(saved.filter { available.contains($0) }.prefix(20))
            if workspace.selected.isEmpty { workspace.selected = Set(app.projects.sorted { (recent.firstIndex(of: $0.selection) ?? 1000) < (recent.firstIndex(of: $1.selection) ?? 1000) }.prefix(20).map(\.id)) }
            if let id = app.workspaceFilter { workspace.selected = Set(app.projects.filter { $0.workspaceID == id }.prefix(20).map(\.id)) }
            workspace.refresh(app: app)
            if app.projects.count > 20 && saved.isEmpty { choosing = true }
        }
        .onDisappear { workspace.cancel() }
        .onChange(of: workspace.tab) { _, _ in workspace.refresh(app: app) }
        .task(id: workspace.search) { do { try await Task.sleep(for: .milliseconds(250)); workspace.refresh(app: app) } catch {} }
        .sheet(isPresented: $choosing) {
            VStack(alignment: .leading) {
                Text("Include up to 20 projects").font(.headline)
                List(app.projects) { project in
                    Toggle(project.name, isOn: Binding(get: { workspace.selected.contains(project.id) }, set: { enabled in
                        if enabled { if workspace.selected.count < 20 { workspace.selected.insert(project.id) } } else { workspace.selected.remove(project.id) }
                    })).disabled(!workspace.selected.contains(project.id) && workspace.selected.count >= 20)
                }
                Button("Apply") { UserDefaults.standard.set(workspace.selected.sorted(), forKey: "workspaceProjects"); workspace.refresh(app: app); choosing = false }
            }.padding(20).frame(width: 480, height: 450)
        }
    }
    private func chooseWorkspace(_ id: String?) {
        let projects = app.projects.filter { id == nil || $0.workspaceID == id }
        workspace.selected = Set(projects.prefix(20).map(\.id))
        workspace.refresh(app: app)
        if projects.count > 20 { choosing = true }
    }
    private func name(_ id: String) -> String { app.projects.first { $0.id == id }?.name ?? id }
    private func coverageText(_ id: String) -> String { workspace.errors[id] ?? (workspace.coverage[id]?.complete == true ? "Range indexed" : "Partial or not indexed") }
    private func open(_ item: SessionStore.WorkspaceRow) {
        guard let project = app.projects.first(where: { $0.id == item.project }) else { return }
        WindowContext.shared.pendingLinks[project.id] = item.row.id
        app.selectProject(project.selection); app.section = .sessions; dismiss()
    }
}

struct WorkspaceSessionList: View {
    let workspace: WorkspaceModel
    var name: (String) -> String
    var open: (SessionStore.WorkspaceRow) -> Void
    var body: some View {
        List(workspace.rows) { item in
            HStack {
                Text(name(item.project)).frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                Button(item.row.title) { open(item) }.buttonStyle(.plain)
                Spacer(); Text(item.row.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date").font(.caption)
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}
