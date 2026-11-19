import SwiftUI

@main
struct LiveKitObserverApp: App {
    @State private var model = AppModel()

    init() { _ = Updater.shared }

    var body: some Scene {
        WindowGroup("LiveKit Observer") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await model.refresh() }
                .onAppear { model.handleSpaceBar() }
        }
        .commands {
            CheckForUpdatesCommand()
            CommandGroup(replacing: .saveItem) {
                Button("Save Session Data…") { if let row = model.detail?.row { model.saveSessionData(row) } }
                    .keyboardShortcut("s")
                    .disabled(model.detail.map { model.savingSessions.contains($0.row.id) } ?? true)
            }
            CommandMenu("Playback") {
                // Space is handled by AppModel.handleSpaceBar, so focused lists and buttons cannot swallow it
                // and text fields still get it.
                Button(model.player.isPlaying ? "Pause (Space)" : "Play (Space)") { model.player.toggle() }
                    .disabled(!model.player.isLoaded)
                Button("Back 10 Seconds") { model.player.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward 10 Seconds") { model.player.skip(10) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Toggle("Scrub", isOn: Bindable(model.skimmer).isEnabled).keyboardShortcut("s", modifiers: .option)
                Divider()
                Button("Flag Playhead") { model.flagPlayhead() }.keyboardShortcut("m", modifiers: .option)
                    .disabled(model.detail == nil || model.player.currentDate == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Sessions") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
        Settings { SettingsView().environment(model) }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if let detail = model.detail {
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
        .toolbar {
            ToolbarItem(placement: .navigation) { ProjectMenu() }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
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
            List(selection: $model.selection) {
                ForEach(DaySection.group(model.visibleRows)) { day in
                    Section(day.title) {
                        ForEach(day.rows) { row in
                            SessionRowView(row: row, agentName: model.agentNames[row.id], liveKitLoaded: model.liveKitLoaded,
                                           flagged: model.isFlagged(row.id), noted: model.hasNotes(row.id),
                                           lessonFlags: model.flaggedInLesson(row) ? max(model.lessonFlagCounts[row.id] ?? 1, 1) : 0).tag(row.id)
                                .onAppear { model.requestAgentName(for: row) }
                                .contextMenu {
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
                                    if let url = model.dashboardURL(for: row.id) { Button("Copy Dashboard Link") { AppModel.copy(url.absoluteString) } }
                                }
                        }
                    }
                }
            }
            .overlay {
                if model.loading && model.rows.isEmpty { ProgressView("Loading sessions…") }
                else if !model.loading && model.visibleRows.isEmpty { ContentUnavailableView("No sessions", systemImage: "tray") }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Only sessions with a recording", isOn: $model.onlyWithRecording)
                Toggle("Only flagged sessions", isOn: $model.onlyFlagged)
            }
            .toggleStyle(.checkbox).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .searchable(text: $model.filter, placement: .sidebar, prompt: "Room or session ID")
        .navigationTitle("Sessions")
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

struct SessionRowView: View {
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
            HStack(spacing: 6) {
                if row.recording != nil { Tag(text: "Recording", symbol: "waveform", color: .green) }
                if row.session?.hasDetailData == true { Tag(text: "Insights", symbol: "chart.bar.xaxis", color: .blue) }
                if lessonFlags > 0 { Tag(text: lessonFlags == 1 ? "1 flag" : "\(lessonFlags) flags", symbol: "flag.fill", color: .orange).help("Moments flagged from the lesson page") }
                if row.session?.status == "active" { Tag(text: "Live", symbol: "dot.radiowaves.left.and.right", color: .red) }
                if row.session == nil && liveKitLoaded { Tag(text: "Recording only", symbol: "clock.badge.questionmark", color: .gray) }
            }
        }
        .padding(.vertical, 3)
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

    var body: some View {
        Menu {
            Picker("Project", selection: Binding(get: { model.project ?? "" }, set: { model.selectProject($0.isEmpty ? nil : $0) })) {
                Text("lk default project").tag("")
                ForEach(model.projects) { project in
                    Text(project.subdomain.map { "\(project.name)  (\($0))" } ?? project.name).tag(project.name)
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
                    ForEach(model.projects) { Text($0.name).tag($0.name) }
                }
                if let project = model.projects.first(where: { $0.name == model.project }) {
                    LabeledContent("URL", value: project.url).textSelection(.enabled)
                }
                TextField("Dashboard project ID", text: $dashboardId, prompt: Text(model.projectId ?? "p_… (for dashboard links)"))
                    .onSubmit { AppSettings.setDashboardProjectId(dashboardId, for: model.project); Task { await model.refresh() } }
                HStack {
                    Button("Add with API key…") { adding = true }
                    Button("Link a Cloud project…") { model.linkCloudProject() }
                        .help("Runs `lk cloud auth` in Terminal, which adds a Cloud project to lk from your browser.")
                }
                Text("Projects are the ones saved in `lk` (`lk project list`). Linked Cloud projects include the project ID for dashboard links; for others, enter it above.")
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

    var body: some View {
        Form {
            Section {
                LabeledContent("Cache", value: Format.bytes(cacheSize))
                Text("Recordings contain people's voices. They are cached only on this Mac, in ~/Library/Caches/LiveKitObserver.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete downloaded recordings") { model.clearCache(); cacheSize = model.cacheSize }
            }
        }
        .formStyle(.grouped)
        .onAppear { cacheSize = model.cacheSize }
    }
}
