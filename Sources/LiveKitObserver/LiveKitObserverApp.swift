import ObserverCore
import SwiftUI

@main
struct LiveKitObserverApp: App {
    @State private var model = AppModel()
    @AppStorage("agentHealthMonitoring") private var agentHealthMonitoring = false
    @FocusedValue(\.observerModel) private var focusedModel
    @Environment(\.openWindow) private var openWindow

    init() { _ = Updater.shared }

    var body: some Scene {
        let activeModel = focusedModel ?? WindowContext.shared.active ?? model
        Window("LiveKit Observer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    // Hosted unit tests must not refresh real accounts or prompt for Keychain access.
                    guard NSClassFromString("XCTestCase") == nil,
                          NSClassFromString("XCTest.XCTestCase") == nil,
                          ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await model.refresh()
                }
                .onAppear { model.handleSpaceBar() }
        }
        .commands {
            CheckForUpdatesCommand()
            CommandGroup(replacing: .newItem) {
                Button("New Window for Project") {
                    if let project = activeModel.project { openWindow(id: "project", value: project) }
                    else { activeModel.showingProjectSwitcher = true }
                }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Add Packet Capture…") { activeModel.captures.chooseFiles(for: activeModel.detail.flatMap { activeModel.captureSession(for: $0.row) }) }
                    .disabled(activeModel.detail == nil || activeModel.captures.importing)
                Button("Save Session Data…") { if let row = activeModel.detail?.row { activeModel.saveSessionData(row) } }
                    .keyboardShortcut("s")
                    .disabled(activeModel.detail.map { activeModel.savingSessions.contains($0.row.id) } ?? true)
            }
            CommandMenu("Playback") {
                // Space is handled by AppModel.handleSpaceBar, so focused lists and buttons cannot swallow it
                // and text fields still get it.
                Button(activeModel.player.isPlaying ? "Pause (Space)" : "Play (Space)") { activeModel.player.toggle() }
                    .disabled(!activeModel.player.isLoaded)
                Button("Back 10 Seconds") { activeModel.player.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward 10 Seconds") { activeModel.player.skip(10) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Toggle("Scrub", isOn: Bindable(activeModel.skimmer).isEnabled).keyboardShortcut("s", modifiers: .option)
                Divider()
                Button("Flag Playhead") { activeModel.flagPlayhead() }.keyboardShortcut("m", modifiers: .option)
                    .disabled(activeModel.detail == nil || activeModel.player.currentDate == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Sessions") { Task { await activeModel.refresh() } }.keyboardShortcut("r")
                Button("Quick Jump…") { activeModel.showingQuickJump = true }.keyboardShortcut("k")
                Button("Switch Project…") { activeModel.showingProjectSwitcher = true }.keyboardShortcut("p")
                Button("Workspace") { activeModel.showingWorkspace = true }.keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) { activeModel.section = section }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                ForEach(1...9, id: \.self) { number in
                    Button("Recent Project \(number)") {
                        let recent = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
                        if recent.indices.contains(number - 1) { activeModel.selectProject(recent[number - 1]) }
                    }.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .control)
                }
            }
        }
        Settings { SettingsView().environment(activeModel) }
        WindowGroup("Project", id: "project", for: String.self) { $project in ProjectWindow(project: $project) }
        MenuBarExtra("Observer Agent Health", systemImage: "waveform.path.ecg", isInserted: $agentHealthMonitoring) {
            AgentHealthMenu().environment(activeModel)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("agentHealthMonitoring") private var agentHealthMonitoring = false
    @State private var talking = false
    @Environment(\.openWindow) private var openWindow
    @State private var windowContext = WindowContext.shared
    @SceneStorage("observer.selectedSession") private var savedSelection = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 200)
            .navigationTitle("Observer")
        } content: {
            Group {
                if model.section == .sessions { SessionListView() }
                else { OperationsListView(section: model.section) }
            }.navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if model.section != .sessions {
                OperationsDetailView(section: model.section)
            } else if let detail = model.detail {
                SessionDetailView(detail: detail).id(detail.row.id)
            } else {
                ContentUnavailableView("Choose a session", systemImage: "waveform", description: Text("Pick a session to hear the recording and read its transcript, logs, and traces."))
            }
        }
        .alert("Save Session Data", isPresented: Binding(get: { model.saveMessage != nil }, set: { if !$0 { model.saveMessage = nil } })) {
            Button("OK") { model.saveMessage = nil }
        } message: {
            Text(model.saveMessage ?? "")
        }
        .alert("Packet Captures", isPresented: Binding(get: { model.captures.message != nil }, set: { if !$0 { model.captures.message = nil } })) {
            Button("OK") { model.captures.message = nil }
        } message: { Text(model.captures.message ?? "") }
        .sheet(item: Binding(get: { model.captures.openedCapture }, set: { model.captures.openedCapture = $0 })) { capture in
            PacketCaptureViewer(capture: capture, store: model.captures.store).id(capture.id)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { CaptureTransferView(library: model.captures) }
        .safeAreaInset(edge: .top, spacing: 0) { (model.selectedProject?.color ?? .gray).frame(height: 3) }
        .sheet(isPresented: $model.showingProjectSwitcher, onDismiss: {
            if model.openWorkspaceAfterSwitcher { model.openWorkspaceAfterSwitcher = false; model.showingWorkspace = true }
        }) { ProjectSwitcher() }
        .sheet(isPresented: $model.showingWorkspace) { WorkspaceView() }
        .sheet(isPresented: $model.showingQuickJump) { QuickJumpView() }
        .sheet(isPresented: $talking) { if let project = model.selectedProject { TalkView(project: project, initialAgent: "").id(project.id) } }
        .focusedSceneValue(\.observerModel, model)
        .background(WindowFocusReader(model: model).frame(width: 0, height: 0))
        .onAppear { windowContext.active = model }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { windowContext.active = model } else { model.persistNavigation() }
        }
        .task(id: "\(model.projectIdentity):\(model.section):\(model.selection ?? ""):\(model.scrollAnchor ?? ""):\(model.operations.selectedAgent ?? ""):\(model.operations.selectedRun ?? ""):\(model.operations.selectedRoom ?? "")") {
            do { try await Task.sleep(for: .milliseconds(500)); model.persistNavigation() } catch {}
        }
        .onChange(of: model.selection) { _, selection in if let selection { savedSelection = selection } }
        .onOpenURL { url in
            guard let link = SessionLink(url: url) else { return }
            windowContext.pendingLinks[link.project] = link.session
            if model.selectedProject?.id != link.project { openWindow(id: "project", value: link.project) }
        }
        .task(id: "\(model.projectIdentity):\(windowContext.pendingLinks[model.projectIdentity] ?? ""):\(model.loading)") {
            guard !model.loading, !AppModel.isTesting, model.projects.count > 0 else { return }
            if let session = windowContext.pendingLinks.removeValue(forKey: model.projectIdentity) { await model.openRemoteSession(session) }
            else if model.selection == nil, !savedSelection.isEmpty, model.rows.contains(where: { $0.id == savedSelection }) { model.selection = savedSelection }
        }
        .task(id: "\(model.section.rawValue):\(model.projectIdentity):\(scenePhase)") {
            guard !AppModel.isTesting else { return }
            let changedProject = model.operations.projectID != model.projectIdentity
            model.operations.configure(cli: model.cli, projectID: model.projectIdentity)
            if changedProject { model.restoreOperationSelection() }
            if scenePhase == .active { await model.operations.watch(model.section) }
        }
        .task(id: "\(agentHealthMonitoring):\(model.projectIdentity):\(scenePhase)") {
            guard agentHealthMonitoring, !AppModel.isTesting else { return }
            await model.monitor.watch(cli: model.cli, project: model.selectedProject, background: scenePhase != .active)
        }
        .onChange(of: model.captures.revision) { _, _ in model.mergeLocalCaptureRows() }
        .toolbar {
            ToolbarItem { Button { model.showingWorkspace = true } label: { Label("Workspace", systemImage: "square.grid.2x2") } }
            ToolbarItem { Button { talking = true } label: { Label("Talk to Agent", systemImage: "mic") }.disabled(model.selectedProject == nil) }
            ToolbarItem(placement: .navigation) { ProjectMenu() }
            ToolbarItem {
                Button { Task { if model.section == .sessions { await model.refresh() } else { await model.operations.refresh(model.section) } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.section == .sessions ? model.loading : model.operations.loading)
            }
        }
    }
}

struct SessionListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.liveKitError { ProblemBanner(error: error) }
            if let error = model.storageError {
                Label(error, systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange).padding(8)
            }
            ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(DaySection.group(model.visibleRows)) { day in
                    Section(day.title) {
                        ForEach(day.rows) { row in
                            SessionRowView(row: row, agentName: model.agentNames[row.id], liveKitLoaded: model.liveKitLoaded,
                                           flagged: model.isFlagged(row.id), noted: model.hasNotes(row.id),
                                           lessonFlags: model.flaggedInLesson(row) ? max(model.lessonFlagCounts[row.id] ?? 1, 1) : 0)
                                .equatable().frame(height: 60, alignment: .leading).tag(row.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: SessionRowPositions.self, value: [row.id: geometry.frame(in: .named("sessions")).minY])
                                })
                                .dropDestination(for: URL.self) { urls, _ in
                                    model.captures.importFiles(urls, to: model.captureSession(for: row))
                                }

                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) { sessionActions(row) }
            }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .coordinateSpace(name: "sessions")
            .onPreferenceChange(SessionRowPositions.self) { positions in
                guard !model.loading, let id = positions.filter({ $0.value >= -20 }).min(by: { $0.value < $1.value })?.key,
                      let row = model.rows.first(where: { $0.id == id }) else { return }
                model.scrollAnchor = id; model.restorationAnchor = SessionBookmark(row)
            }
            .task(id: "\(model.projectIdentity):\(model.rows.first?.id ?? "")") {
                if model.needsScrollRestoration, let anchor = model.restorationAnchor?.id, model.rows.contains(where: { $0.id == anchor }) {
                    model.needsScrollRestoration = false; proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .overlay {
                if model.loading && model.rows.isEmpty { ProgressView("Loading sessions…") }
                else if !model.loading && model.visibleRows.isEmpty { ContentUnavailableView("No sessions", systemImage: "tray") }
            }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.coverageText).font(.caption2).foregroundStyle(.secondary)
                if !model.filter.isEmpty || model.onlyFlagged || model.onlyWithRecording {
                    Text("Searching indexed summaries. Unread log flags and undiscovered recordings are unknown.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Only sessions with a recording", isOn: $model.onlyWithRecording)
                Toggle("Only flagged sessions", isOn: $model.onlyFlagged)
                Text("Agent names and log flags are filled when a session is opened.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Newest") { Task { await model.applySessionQuery() } }.disabled(model.loading)
                    Button("Load older sessions") { Task { await model.loadMoreSessions() } }
                        .disabled(!model.canLoadMore || model.loadingMore || model.loading)
                    if model.loadingMore { ProgressView().controlSize(.small) }
                }
                if model.storageConfigured {
                    HStack {
                        Button(model.recordingScan?.complete == false ? "Continue recording scan" : "Scan recordings") { model.scanRecordings() }
                            .disabled(model.scanningRecordings)
                        if model.scanningRecordings { ProgressView().controlSize(.small) }
                    }
                    if let scan = model.recordingScan {
                        Text("\(scan.objects) storage objects checked · \(scan.complete ? "Scan complete" : "Partial coverage")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .searchable(text: $model.filter, placement: .sidebar, prompt: "Indexed room prefix or session ID")
        .safeAreaInset(edge: .top) { SessionQueryView() }
        .navigationTitle("Sessions")
    }
    @ViewBuilder private func sessionActions(_ row: SessionRow) -> some View {
        Button("Add Packet Capture…") { model.captures.chooseFiles(for: model.captureSession(for: row)) }
        .disabled(model.captures.importing)
        Button(model.isFlagged(row.id) ? "Unflag Session" : "Flag Session") { model.toggleSessionFlag(row.id) }
        Divider()
        Button("Open in LiveKit Dashboard") { model.openDashboard(row.id) }
        .disabled(row.session == nil || model.projectId == nil)
        Button("Save Session Data…") { model.saveSessionData(row) }
        .disabled(model.savingSessions.contains(row.id))
        if model.savedFolder(row.id) != nil {
        Button("Show Saved Data in Finder") { model.showSavedFolder(row.id) }
        }
        Button("Copy Session ID") { AppModel.copy(row.id) }
        if let project = model.selectedProject?.id, let link = SessionLink(project: project, session: row.id) { Button("Copy Observer Link") { AppModel.copy(link.url.absoluteString) } }
        if let url = model.dashboardURL(for: row.id) { Button("Copy Dashboard Link") { AppModel.copy(url.absoluteString) } }
    }

}

/// The sessions that started on one calendar day, newest day first, for the list's date dividers.
struct DaySection: Identifiable {
    let id: Date?
    let rows: [SessionRow]

    var title: String {
        guard let id else { return "Unknown date" }
        let calendar = Calendar.current
        if calendar.isDateInToday(id) { return "Today" }
        if calendar.isDateInYesterday(id) { return "Yesterday" }
        let sameYear = calendar.isDate(id, equalTo: .now, toGranularity: .year)
        return id.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year(sameYear ? .omitted : .defaultDigits))
    }

    /// Groups rows by the day they started, keeping their order (newest first, undated last).
    static func group(_ rows: [SessionRow], calendar: Calendar = .current) -> [DaySection] {
        var days: [Date?] = []
        var rowsByDay: [Date?: [SessionRow]] = [:]
        for row in rows {
            let day = row.startedAt.map { calendar.startOfDay(for: $0) }
            if rowsByDay[day] == nil { days.append(day) }
            rowsByDay[day, default: []].append(row)
        }
        return days.map { DaySection(id: $0, rows: rowsByDay[$0] ?? []) }
    }
}

struct SessionRowView: View, Equatable {
    let row: SessionRow
    let agentName: String?
    let liveKitLoaded: Bool
    var flagged = false
    var noted = false
    /// Moments flagged from the lesson page.
    var lessonFlags = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if flagged { Image(systemName: "flag.fill").foregroundStyle(.orange).help("Flagged session") }
                Text(row.title).font(.headline).lineLimit(1).truncationMode(.middle)
                if noted { Image(systemName: "paperclip").foregroundStyle(.secondary).help("Has flags with notes") }
                Spacer()
                Text(Format.duration(row.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(row.startedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? row.id)
                if let agentName, !agentName.isEmpty {
                    Text("·")
                    Label(agentName, systemImage: "person.wave.2").labelStyle(.titleAndIcon)
                        .foregroundStyle(agentName.localizedCaseInsensitiveContains("dev") ? Color.orange : Color.secondary)
                        .help("LiveKit agent that ran this session")
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let badges { badges.font(.caption2).lineLimit(1) }
        }
        .padding(.vertical, 3)
    }

    /// One text layout keeps paged lists inexpensive even when every row has flags.
    private var badges: Text? {
        var labels: [Text] = []
        func append(_ title: String, _ symbol: String, _ color: Color) {
            labels.append(Text("\(Image(systemName: symbol)) \(title)").foregroundColor(color))
        }
        if row.recording != nil { append("Recording", "waveform", .green) }
        if row.session?.hasDetailData == true { append("Insights", "chart.bar.xaxis", .blue) }
        if lessonFlags > 0 { append(lessonFlags == 1 ? "1 flag" : "\(lessonFlags) flags", "flag.fill", .orange) }
        if row.session?.status == "active" { append("Live", "dot.radiowaves.left.and.right", .red) }
        if row.localCaptureSession != nil { append("Captures", "doc.richtext", .purple) }
        if row.session == nil && (liveKitLoaded || row.localCaptureSession != nil) {
            append(row.recording != nil ? "Recording only" : "Saved locally", "clock.badge.questionmark", .gray)
        }
        return labels.dropFirst().reduce(labels.first) { result, label in result.map { $0 + Text("   ") + label } }
    }
}

struct Tag: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        Label(text, systemImage: symbol).font(.caption2).labelStyle(.titleAndIcon)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct ProblemBanner: View {
    let error: LiveKitCLIError
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.message, systemImage: "exclamationmark.triangle").font(.caption)
            if error.kind == .signedOut || error.kind == .projectNotFound {
                HStack {
                    Button("Sign in to LiveKit…") { model.signIn() }.controlSize(.small)
                    Button("Settings…") { openSettings() }.controlSize(.small)
                }
                Text("Sign-in opens Terminal for `lk cloud auth --user-auth`. Refresh when it finishes.").font(.caption2).foregroundStyle(.secondary)
            } else if error.kind == .missingCLI {
                Text("Install it with `brew install livekit-cli`, or set its path in Settings.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15))
    }
}

/// Picks which `lk` project the window shows.
struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var localProjects: [String] {
        Set(model.captures.items.map { $0.session.projectName })
            .subtracting(model.projects.flatMap { [$0.name, $0.selection, $0.lkName ?? ""] }).sorted()
    }

    var body: some View {
        Menu {
            Picker("Project", selection: Binding(get: { model.project ?? "" }, set: { model.selectProject($0.isEmpty ? nil : $0) })) {
                Text("lk default project").tag("")
                ForEach(model.projects) { project in
                    Text(project.subdomain.map { "\(project.name)  (\($0))" } ?? project.name).tag(project.selection)
                }
                ForEach(localProjects, id: \.self) { name in
                    Text("\(name) (saved captures)").tag(name)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Add or Link a Project…") { openSettings() }
            Button("Reload Projects") { Task { await model.loadAccount() } }
        } label: {
            Label(model.project ?? "lk default project", systemImage: "server.rack").labelStyle(.titleAndIcon)
        }
        .help("LiveKit project")
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            LiveKitSettings().tabItem { Label("LiveKit", systemImage: "server.rack") }
            StorageSettingsView().tabItem { Label("Egress Storage", systemImage: "externaldrive") }
            CacheSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            AISettingsView().tabItem { Label("AI", systemImage: "sparkles") }
            AgentHealthSettings().tabItem { Label("Agent Health", systemImage: "waveform.path.ecg") }
        }
        .frame(width: 560)
    }
}

/// The `lk` sign-in, the project to show, and adding projects to `lk`.
struct LiveKitSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.lkKey) private var lkPath = ""
    @State private var dashboardId = ""
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Signed in as") {
                    if let user = model.signedInUser { Text(user) } else { Text("Not signed in").foregroundStyle(.orange) }
                }
                HStack {
                    Button(model.signedInUser == nil ? "Sign in…" : "Sign in as someone else…") { model.signIn() }
                    Button("Check again") { Task { await model.refresh() } }
                }
                Text("Session data (transcripts, logs, traces, metrics, and LiveKit's recordings) comes through `lk analytics` with your LiveKit Cloud sign-in. Sign-in runs `lk cloud auth --user-auth` in Terminal; `lk` keeps the credentials, not this app. Your user needs access to the project, and agent observability must be on for it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("LiveKit Cloud sign-in") }

            Section {
                Picker("Project", selection: Binding(get: { model.project ?? "" }, set: { model.selectProject($0.isEmpty ? nil : $0) })) {
                    Text("lk default project").tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.selection) }
                }
                if let project = model.selectedProject {
                    LabeledContent("URL", value: project.url).textSelection(.enabled)
                }
                TextField("Dashboard project ID", text: $dashboardId, prompt: Text(model.projectId ?? "p_… (for dashboard links)"))
                    .onSubmit { AppSettings.setDashboardProjectId(dashboardId, for: model.project); Task { await model.refresh() } }
                HStack {
                    Button("Add with API key…") { adding = true }
                    Button("Link a Cloud project…") { model.linkCloudProject() }
                        .help("Runs `lk cloud auth` in Terminal, which adds a Cloud project to lk from your browser.")
                }
                Text("Projects merge your Cloud sign-in with saved CLI project metadata. API keys and secrets are not included in the project listing.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Project") }

            Section {
                TextField("lk path", text: $lkPath, prompt: Text(LiveKitCLI.locate()?.path ?? "/opt/homebrew/bin/lk"))
            } header: { Text("LiveKit CLI") }
        }
        .formStyle(.grouped)
        .onAppear { dashboardId = AppSettings.dashboardProjectId(for: model.project) }
        .onChange(of: model.project) { dashboardId = AppSettings.dashboardProjectId(for: model.project) }
        .sheet(isPresented: $adding) { AddProjectSheet() }
    }
}

/// Saves a project in `lk` from its URL, API key, and secret.
struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("my-app"))
                TextField("URL", text: $url, prompt: Text("wss://my-app-abc123.livekit.cloud"))
                TextField("API key", text: $apiKey)
                SecureField("API secret", text: $apiSecret)
            } footer: {
                Text("Saved with `lk project add`, so other `lk` commands can use it too. Reading session data still needs a LiveKit Cloud sign-in with access to the project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : "Add Project") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await model.addProject(name: name, url: url, apiKey: apiKey, apiSecret: apiSecret)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || [name, url, apiKey, apiSecret].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Where the selected project's egress recordings are stored.
struct StorageSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = StorageSettings()
    @State private var secret = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Endpoint", text: $settings.endpoint, prompt: Text("https://nyc3.digitaloceanspaces.com (blank for AWS S3)"))
                TextField("Region", text: $settings.region, prompt: Text("us-east-1"))
                TextField("Bucket", text: $settings.bucket)
                TextField("Folder", text: $settings.prefix, prompt: Text("The egress filepath prefix, or blank for the whole bucket"))
                TextField("Access key", text: $settings.accessKey)
                SecureField("Secret", text: $secret)
                Toggle("Egress puts the user on the left channel and the agent on the right", isOn: $settings.userLeftAgentRight)
            } header: {
                Text("Egress storage for \(model.project ?? "the lk default project")")
            } footer: {
                Text("Optional. If your egress uploads to S3-compatible storage (AWS S3, Spaces, R2, MinIO, …), the app lists its manifests and plays each recording beside LiveKit's own. Read-only access is enough. The secret is kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Import from .env file…") { importEnv() }
                Spacer()
                Button("Clear") { settings = StorageSettings(); secret = ""; save() }
                Button(testing ? "Testing…" : "Test") { test() }.disabled(testing)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: model.project) { load() }
    }

    private func load() {
        settings = AppSettings.storage(for: model.project)
        secret = AppSettings.storageSecret(for: model.project)
        status = nil
    }

    private func save() {
        AppSettings.setStorage(settings, secret: secret, for: model.project)
        status = settings.isEmpty ? "Egress storage is off for this project." : "Saved."
        Task { await model.refresh() }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            defer { testing = false }
            do {
                let client = StorageClient(config: try StorageConfig(settings: settings, secret: secret))
                let found = try await client.probe()
                status = found > 0 ? "Connected. The folder has files." : "Connected, but the folder is empty. Check the folder (egress filepath prefix)."
            } catch { status = "Could not connect: \(error.localizedDescription)" }
        }
    }

    private func importEnv() {
        let panel = NSOpenPanel()
        panel.message = "Choose an env file with EGRESS_S3_* or AWS_* settings"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try StorageSettings.importing(envFile: url)
            settings = imported.settings
            if !imported.secret.isEmpty { secret = imported.secret }
            status = "Imported from \(url.lastPathComponent). Review, then Save."
        } catch { status = error.localizedDescription }
    }
}

struct CacheSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int64 = 0
    @AppStorage("summaryRetentionDays") private var summaryRetentionDays = 30
    @AppStorage("recordingCacheGB") private var recordingCacheGB = 2
    @AppStorage("decodedCacheGB") private var decodedCacheGB = 4

    var body: some View {
        Form {
            Section {
                LabeledContent("Cache", value: Format.bytes(cacheSize))
                Stepper("Downloaded recordings: \(recordingCacheGB) GB", value: $recordingCacheGB, in: 1...100)
                Stepper("Decoded audio: \(decodedCacheGB) GB", value: $decodedCacheGB, in: 1...100)
                Text("Old disposable media is evicted when another recording opens. Media in use by any window is kept and may temporarily exceed these limits. Imported captures and saved AI results are kept separately.").font(.caption).foregroundStyle(.secondary)
                Text("Recordings contain people's voices. They are cached only on this Mac, in ~/Library/Caches/LiveKitObserver.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete downloaded recordings") { model.clearCache(); cacheSize = model.cacheSize }
            }
            Section("Session summaries") {
                Picker("Keep fetched summaries", selection: $summaryRetentionDays) {
                    Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
                }
                Text("The local index stores summaries separately from media. Retention is applied on refresh and preserves indexed flagged sessions, notes and imported captures. This does not extend LiveKit's retention.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { cacheSize = model.cacheSize }
    }
}
