import ObserverCore
import SwiftUI

struct OperationsListView: View {
    let section: AppSection
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var ops = app.operations
        VStack(spacing: 0) {
            if let error = ops.error { Text(error).font(.caption).foregroundStyle(.orange).padding(10).textSelection(.enabled) }
            Group {
                switch section {
                case .agents:
                    List(ops.agents, selection: $ops.selectedAgent) { agent in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(agent.title, systemImage: agent.healthy ? "circle.fill" : "circle.dotted").foregroundStyle(agent.healthy ? .green : .secondary)
                            Text("\(agent.version) · \(agent.status)").font(.caption).foregroundStyle(.secondary)
                        }.tag(agent.id)
                    }
                case .simulations:
                    List(ops.runs, selection: $ops.selectedRun) { run in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(run.agentName.isEmpty ? run.id : run.agentName).font(.headline)
                            Text("\(run.mode) · \(run.status)").font(.caption)
                            Text(run.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date").font(.caption).foregroundStyle(.secondary)
                            if let passed = run.passed, let failed = run.failed { Text("\(passed) passed · \(failed) failed").font(.caption) }
                        }.tag(run.id)
                    }
                case .rooms:
                    List(ops.rooms, selection: $ops.selectedRoom) { room in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(room.name).font(.headline)
                            Text("\(room.participants) participants").font(.caption).foregroundStyle(.secondary)
                            if let date = room.createdAt { Text(date, style: .relative).font(.caption) }
                        }.tag(room.id)
                    }
                case .sessions: EmptyView()
                }
            }
            HStack {
                if ops.loading { ProgressView().controlSize(.small) }
                if let date = ops.updatedAt { Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if section == .simulations, ops.nextRunCursor != nil, ops.runs.count < 500 {
                    Button("Older runs") { Task { await ops.refresh(section, older: true) } }.disabled(ops.loading)
                }
            }.padding(8)
        }
        .navigationTitle(section.rawValue)
    }
}

struct OperationsDetailView: View {
    let section: AppSection
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var ops = app.operations
        Group {
            switch section {
            case .agents:
                if let agent = ops.agents.first(where: { $0.id == ops.selectedAgent }) { AgentDetailView(agent: agent).id(agent.id) }
                else { ContentUnavailableView("Choose an agent", systemImage: section.symbol) }
            case .simulations:
                if ops.selectedRun != nil { SimulationRunView().id(ops.selectedRun) }
                else { ContentUnavailableView("Choose a simulation run", systemImage: section.symbol) }
            case .rooms:
                if let room = ops.rooms.first(where: { $0.id == ops.selectedRoom }) { RoomDetailView(room: room).id(room.id) }
                else { ContentUnavailableView("Choose a live room", systemImage: section.symbol, description: Text("Rooms appear while participants are connected.")) }
            case .sessions: EmptyView()
            }
        }
        .sheet(item: $ops.confirmation) { request in
            OperationConfirmationView(request: request) { values in Task { await ops.perform(request, section: section, values: values) } }
        }
        .sheet(item: $ops.rerun) { request in
            SimulationRerunView(request: request) { ops.startRerun(request) }
        }
        .overlay(alignment: .bottom) { if ops.mutating { ProgressView("Applying change…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding() } }
    }
}

struct AgentDetailView: View {
    let agent: CloudAgent
    @Environment(AppModel.self) private var app
    @State private var tab = "Versions"
    @State private var talking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(agent.title).font(.title2.bold())
                    Text("\(agent.id) · \(agent.version) · \(agent.status)").font(.caption).textSelection(.enabled)
                }
                Spacer()
                Button("Talk…") { talking = true }
                Button("Restart…") { confirm("Restart agent", target: nil) }.disabled(app.operations.mutating)
                if let project = app.selectedProject?.projectId, let url = URL(string: "https://cloud.livekit.io/projects/\(project)/agents/\(agent.id)") { Link("Dashboard", destination: url) }
            }
            ForEach(Array(agent.deployments.enumerated()), id: \.offset) { _, deployment in
                Text("\(deployment.region) · \(deployment.name) · \(deployment.status) · \(deployment.replicas.map(String.init) ?? "?") replicas").font(.caption).foregroundStyle(.secondary)
            }
            Picker("View", selection: $tab) { ForEach(["Versions", "Logs", "Secrets", "Sessions"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if let error = app.operations.detailError { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            if tab == "Logs", let cli = app.operations.cli { AgentLogsView(cli: cli, agent: agent.id) }
            else if tab == "Versions" {
                if let target = app.operations.referencedVersion {
                    Text(app.operations.versions.contains(where: { $0.id == target }) ? "Session recorded version: \(target)" : "Session recorded version \(target) is not in the available version list.").font(.caption).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                List(app.operations.versions) { version in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(version.id).font(.headline)
                            if version.id == app.operations.referencedVersion { Tag(text: "Served session", symbol: "link", color: .purple) }
                            if version.current { Tag(text: "Production", symbol: "checkmark.circle", color: .green) }
                            if version.draining { Text("Draining").foregroundStyle(.orange) }
                            Text(version.status).foregroundStyle(.secondary)
                            Spacer()
                            Button("Roll back…") { confirm("Roll back agent", target: version.id) }.disabled(version.current || app.operations.mutating)
                        }
                        if let date = version.deployedAt ?? version.createdAt { Text(date.formatted()).font(.caption) }
                        ForEach(version.attributes.keys.sorted(), id: \.self) { key in Text("\(key): \(version.attributes[key] ?? "")").font(.caption.monospaced()).textSelection(.enabled) }
                    }.padding(.vertical, 6).id(version.id)
                }
                .task(id: app.operations.versions.map(\.id)) { if let target = app.operations.referencedVersion { proxy.scrollTo(target, anchor: .top) } }
                }
            } else if tab == "Secrets" {
                Text("Names only. Manage secret values with the CLI.").foregroundStyle(.secondary)
                List(app.operations.secrets, id: \.self) { Text($0).font(.body.monospaced()) }
            } else {
                Text("Sessions whose opened logs identify this agent. Unopened sessions have unknown agent names.").font(.caption).foregroundStyle(.secondary)
                List(app.rows.filter { app.agentNames[$0.id] == agent.name }) { row in
                    Button(row.title) { app.section = .sessions; app.selection = row.id }.buttonStyle(.plain)
                }
            }
            if app.operations.loadingDetail { ProgressView().controlSize(.small) }
        }.padding().task { await app.operations.loadAgent() }
        .sheet(isPresented: $talking) { if let project = app.selectedProject { TalkView(project: project, initialAgent: agent.name).id(project.id + agent.id) } }
    }
    private func confirm(_ title: String, target: String?) {
        guard let project = app.selectedProject else { return }
        app.operations.confirm(title, explanation: "Agent: \(agent.title) (\(agent.id))\nCurrent version: \(agent.version)" + (target.map { "\nTarget version: \($0)" } ?? "\nThis restarts the deployed agent."),
                               arguments: ["agent", target == nil ? "restart" : "rollback", "--id", agent.id] + (target.map { ["--version", $0] } ?? []), project: project)
    }
}

struct AgentLogsView: View {
    let cli: LiveKitCLI, agent: String
    @State private var stream = AgentLogStream()
    @State private var paused = false
    @State private var type = "deploy"
    @State private var search = ""
    @State private var level = "All"
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Logs", selection: $type) { Text("Runtime").tag("deploy"); Text("Build").tag("build") }.frame(width: 180)
                Picker("Level", selection: $level) { ForEach(["All", "Error", "Warning", "Info", "Debug"], id: \.self) { Text($0) } }.frame(width: 160)
                TextField("Search logs", text: $search)
                Toggle("Pause", isOn: $paused).toggleStyle(.checkbox)
            }
            if let error = stream.error { Text(error).foregroundStyle(.orange).font(.caption) }
            List(stream.lines.filter { (level == "All" || $0.level == level) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }) { line in
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(line.level == "Error" ? .red : line.level == "Warning" ? .orange : .primary)
            }
            Text("Last 5,000 lines · \(stream.running ? "Streaming" : "Stopped") · Pause disconnects the tail").font(.caption2).foregroundStyle(.secondary)
        }.task(id: "\(paused)-\(type)") { if !paused { await stream.tail(cli: cli, agent: agent, type: type) } }
    }
}

struct SimulationRunView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run = app.operations.run {
                HStack {
                    VStack(alignment: .leading) {
                        Text(run.agentName.isEmpty ? run.id : run.agentName).font(.title2.bold())
                        Text("\(run.mode) · \(run.status) · \(run.id)").font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Refresh") { Task { await app.operations.loadRun() } }
                    if run.finished {
                        Button("Load transcripts") { Task { await app.operations.loadExport() } }.disabled(app.operations.loadingDetail)
                        Button("Export…") { exportRun() }.disabled(app.operations.export == nil)
                        Menu("Re-run") {
                            Button("Failed scenarios…") { prepare(failedOnly: true) }
                            Button("All scenarios…") { prepare(failedOnly: false) }
                        }
                    } else {
                        Button("Cancel run…") { if let project = app.selectedProject {
                            app.operations.confirm("Cancel simulation", explanation: "Run: \(run.id)\nAgent: \(run.agentName)", arguments: ["agent", "simulate", "cancel", run.id, "--json"], project: project)
                        } }
                    }
                }
                if let progress = app.operations.simulationProgress { Text(progress).font(.caption).foregroundStyle(.secondary) }
                if !run.error.isEmpty { Text(run.error).foregroundStyle(.orange).textSelection(.enabled) }
                List(run.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.label.isEmpty ? job.id : job.label).font(.headline)
                            Text(job.status).foregroundStyle(job.status == "passed" ? .green : job.status == "failed" ? .red : .secondary)
                            Spacer(); Text(Format.duration(job.duration)).font(.caption)
                            Button("Review") { app.openSimulation(job, run: run, export: app.operations.export) }
                            if !job.roomID.isEmpty { Button("Open session") { Task { await app.openRemoteSession(job.roomID) } } }
                        }
                        if !job.error.isEmpty { Text(job.error).font(.caption).foregroundStyle(.orange) }
                        DisclosureGroup("Instructions and pass criteria") {
                            Text(job.instructions).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            Text(job.expectations).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.caption)
                    }.padding(.vertical, 8)
                }
            }
            if let error = app.operations.detailError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if app.operations.loadingDetail { ProgressView("Loading simulation…") }
        }.padding().task { await app.operations.loadRun() }
    }
    private func prepare(failedOnly: Bool) { if let project = app.selectedProject { Task { await app.operations.prepareRerun(failedOnly: failedOnly, project: project) } } }
    private func exportRun() {
        guard let value = app.operations.export, let run = app.operations.run else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(run.id).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONSerialization.data(withJSONObject: value.foundation, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { app.operations.detailError = error.localizedDescription }
    }
}

struct SimulationRerunView: View {
    let request: SimulationRerun
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run simulations").font(.title2.bold())
            Text("Project: \(request.projectName)\nAgent: \(request.agent.isEmpty ? "Default agent" : request.agent)\nScenarios: \(request.count) · \(request.mode) mode · concurrency 2")
            Text("This creates a new paid Cloud simulation run against the currently deployed agent. Its model calls and, in audio mode, speech processing are billed to this project.")
            Button("Review scenario file") { NSWorkspace.shared.activateFileViewerSelecting([request.file]) }
            HStack { Spacer(); Button("Cancel") { try? FileManager.default.removeItem(at: request.file); dismiss() }; Button("Start run") { dismiss(); start() } }
        }.padding(24).frame(width: 480)
    }
}

struct OperationConfirmationView: View {
    let request: OperationConfirmation
    let perform: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var fields: [OperationConfirmation.Field] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.bold())
            Text("Project: \(request.projectName) (\(request.projectID))").font(.headline)
            Text(request.explanation).textSelection(.enabled)
            ForEach($fields) { $field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label + (field.optional ? " (optional)" : "")).font(.caption).foregroundStyle(.secondary)
                    if field.multiline {
                        TextEditor(text: $field.text).font(.body.monospaced()).frame(minHeight: 90, maxHeight: 220)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    } else {
                        TextField(field.label, text: $field.text).font(.body.monospaced()).labelsHidden()
                    }
                    if let problem = field.problem, !(field.text.isEmpty && !field.optional) { Text(problem).font(.caption).foregroundStyle(.orange) }
                }
            }
            if request.protected { TextField("Type \(request.projectName) to confirm", text: $typedName) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.title, role: .destructive) { let values = fields.map(\.text); dismiss(); perform(values) }
                    .disabled((request.protected && typedName != request.projectName) || fields.contains { $0.problem != nil })
            }
        }.padding(24).frame(width: request.fields.isEmpty ? 480 : 560)
        .onAppear { if fields.isEmpty { fields = request.fields } }
    }
}
