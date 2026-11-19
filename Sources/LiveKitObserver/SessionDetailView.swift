import Charts
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", spectrogram = "Spectrogram", transcript = "Transcript", logs = "Logs", traces = "Traces", metrics = "Metrics"
    var id: String { rawValue }
}

struct SessionDetailView: View {
    let detail: SessionDetail
    @Environment(AppModel.self) private var model
    @State private var tab: DetailTab = .overview
    @State private var flagNote = ""

    /// Times are shown relative to the recording when there is one.
    var origin: Date? { model.player.origin ?? detail.row.startedAt }

    var body: some View {
        VStack(spacing: 0) {
            header
            PlayerBar(detail: detail).padding(.horizontal).padding(.bottom, 8)
            Divider()
            Picker("View", selection: $tab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(10)
            Group {
                if tab == .spectrogram {
                    SpectrogramView(detail: detail, origin: origin)
                } else if let error = detail.observabilityError, detail.transcript.isEmpty {
                    ContentUnavailableView {
                        Label("No LiveKit data", systemImage: "exclamationmark.bubble")
                    } description: { Text(error.message) } actions: {
                        Button("Try Again") { model.reloadObservability() }
                    }
                } else if detail.loadingObservability && detail.transcript.isEmpty {
                    ProgressView("Reading transcript, logs, and traces…").frame(maxHeight: .infinity)
                } else {
                    switch tab {
                    case .overview: OverviewView(detail: detail, origin: origin, showTab: { tab = $0 })
                    case .transcript: TranscriptView(detail: detail, origin: origin)
                    case .logs: LogsView(detail: detail, origin: origin)
                    case .traces: TracesView(detail: detail, origin: origin)
                    case .metrics: MetricsView(detail: detail)
                    case .spectrogram: EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(detail.row.title)
        .navigationSubtitle(detail.row.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
        .alert("Flag", isPresented: Binding(get: { model.renamingFlag != nil }, set: { if !$0 { model.renamingFlag = nil } })) {
            TextField("What's wrong here?", text: $flagNote)
            Button("Save") { if let id = model.renamingFlag { detail.renameFlag(id, to: flagNote) } }.keyboardShortcut(.defaultAction)
            Button("Remove Flag", role: .destructive) { if let id = model.renamingFlag { detail.removeFlag(id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let flag = detail.flags.first(where: { $0.id == model.renamingFlag }) {
                Text("\(Format.offset(flag.start, from: origin))–\(Format.offset(flag.end, from: origin)). Flagged moments are highlighted in every view and listed in Copy for Claude.")
            }
        }
        .onChange(of: model.renamingFlag) { _, id in flagNote = detail.flags.first { $0.id == id }?.note ?? "" }
        .toolbar {
            ToolbarItem {
                Button { model.toggleSessionFlag(detail.row.id) } label: {
                    Label(model.isFlagged(detail.row.id) ? "Unflag Session" : "Flag Session", systemImage: model.isFlagged(detail.row.id) ? "flag.fill" : "flag")
                }
                .foregroundStyle(model.isFlagged(detail.row.id) ? .orange : .primary)
                .help("Flag this session so it is easy to find in the list")
            }
            ToolbarItem { FlagsMenu(detail: detail, origin: origin) }
            ToolbarItem {
                Button { model.openDashboard(detail.row.id) } label: { Label("Open in LiveKit", systemImage: "safari") }
                    .help(model.projectId == nil ? "LiveKit project ID not found; set it in Settings" : "Open this session in the LiveKit Cloud dashboard")
                    .disabled(detail.row.session == nil || model.dashboardURL(for: detail.row.id) == nil)
            }
            ToolbarItem {
                Button { model.copyReport() } label: { Label("Copy for Claude", systemImage: "doc.on.clipboard") }
                    .help("Copy a Markdown summary of this session (transcript, latency, warnings). It contains user speech; paste it only into your own tools.")
                    .disabled(detail.insights == nil)
            }
            ToolbarItem {
                Button { model.saveSessionData(detail.row) } label: { Label("Save Session Data", systemImage: "square.and.arrow.down") }
                    .help("Save this session's transcript, logs, traces, metrics, recordings, and flags to a folder, and show it in Finder")
                    .disabled(model.savingSessions.contains(detail.row.id))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.row.roomName.isEmpty ? detail.row.id : detail.row.roomName).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(detail.row.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    if detail.row.session != nil, let url = model.dashboardURL(for: detail.row.id) {
                        Link(destination: url) { Label("LiveKit dashboard", systemImage: "arrow.up.right.square") }.font(.caption)
                    }
                }
            }
            Spacer()
            if let state = detail.dataState, state != "settled" {
                Label(state == "settling" ? "Data still arriving" : "Session in progress", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Duration", value: Format.duration(detail.row.duration)).font(.caption).fixedSize()
        }
        .padding()
    }
}

struct PlayerBar: View {
    let detail: SessionDetail
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 12) {
            if detail.loadingAudio {
                ProgressView().controlSize(.small)
                Text("Downloading recording…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if player.isLoaded {
                Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }.buttonStyle(.borderless)
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title) }
                    .buttonStyle(.borderless)
                Button { player.skip(10) } label: { Image(systemName: "goforward.10") }.buttonStyle(.borderless)
                Text("\(Format.duration(player.currentTime)) / \(Format.duration(player.duration))").font(.caption.monospacedDigit()).fixedSize()
                Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Toggle(isOn: Bindable(model.skimmer).isEnabled) { Label("Scrub", systemImage: "waveform.badge.magnifyingglass") }
                    .toggleStyle(.button)
                    .help("Hear the audio under the pointer as it moves over the spectrogram (⌥S)")
                Spacer()
                if let error = detail.audioError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
                }
            } else {
                Label(detail.audioError ?? "No recording", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 32)
    }
}

/// A clickable time that plays the recording from that moment.
struct TimeButton: View {
    let date: Date?
    let origin: Date?
    @Environment(AppModel.self) private var model

    var body: some View {
        let playable = model.player.offset(for: date) != nil
        Button { model.player.play(at: date) } label: {
            Text(Format.offset(date, from: origin)).font(.caption.monospacedDigit())
        }
        .buttonStyle(.borderless).disabled(!playable)
        .help(playable ? "Play from here" : "Not in the recording")
    }
}

// MARK: Overview

struct OverviewView: View {
    let detail: SessionDetail
    let origin: Date?
    let showTab: (DetailTab) -> Void

    var body: some View {
        ScrollView {
            if let i = detail.insights {
                VStack(alignment: .leading, spacing: 20) {
                    if !detail.flags.isEmpty { FlagsBox(detail: detail, origin: origin) }
                    findings("Possible TTS static", items: detail.ttsStaticFound.map {
                        Finding(date: $0.start, text: String(format: "%.1f s at %.0f dB  ", $0.duration, $0.level) + ($0.text.isEmpty ? "(line text not recorded)" : "“\($0.text)”"))
                    }, more: { showTab(.spectrogram) })
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            stat("Agent turns", "\(i.agentTurns)"); stat("User turns", "\(i.userTurns)"); stat("Interrupted", "\(i.interruptions)"); stat("Warnings / errors", "\(i.problems.count)")
                            stat("TTS static", detail.ttsStaticChecked ? "\(detail.ttsStaticFound.count)" : "…",
                                 color: detail.ttsStaticFound.isEmpty ? .primary : TTSStatic.color)
                                .help(detail.ttsStaticChecked ? "Stretches of the agent's TTS audio that sound like static (see the red boxes on the spectrogram)" : "Found once the recording has been analyzed")
                        }
                    }
                    GroupBox("Latency") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow { Text(""); header("Median"); header("p95"); header("Max"); header("Turns") }
                            latency("End-to-end response", i.e2e)
                            latency("LLM first token", i.llmTtft)
                            latency("TTS first byte", i.ttsTtfb)
                            latency("User end-of-turn delay", i.endOfTurn)
                            latency("Speech-to-text delay", i.transcription)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    CostBox(detail: detail)
                    if !e2ePoints.isEmpty {
                        GroupBox("Response time per agent turn") {
                            Chart(e2ePoints, id: \.0) { point in
                                BarMark(x: .value("Turn", point.0), y: .value("ms", point.1))
                                    .foregroundStyle(point.1 >= SessionInsights.slowTurnMs ? .orange : .accentColor)
                                RuleMark(y: .value("Slow", SessionInsights.slowTurnMs)).foregroundStyle(.orange.opacity(0.4)).lineStyle(.init(dash: [4]))
                            }
                            .chartXAxisLabel("Agent turn").chartYAxisLabel("ms").frame(height: 160).padding(4)
                        }
                    }
                    findings("Slow responses (≥ \(Int(SessionInsights.slowTurnMs)) ms)", items: i.slowTurns.map { Finding(date: $0.start, text: "\(Format.ms($0.e2eLatencyMs))  \($0.text)") })
                    findings("Low-confidence user speech (< \(SessionInsights.lowConfidence.formatted()))", items: i.lowConfidence.map { Finding(date: $0.start, text: String(format: "%.2f  %@", $0.confidence ?? 0, $0.text)) })
                    findings("Warnings and errors", items: i.problems.map { Finding(date: $0.timestamp, text: "\($0.level.label.uppercased())  \($0.logger.isEmpty ? "" : $0.logger + ": ")\($0.message)", detail: $0.attributes) }, more: { showTab(.logs) })
                    findings("Failed spans", items: i.failedSpans.map { Finding(date: $0.start, text: "\($0.name)  \($0.statusMessage)", detail: $0.attributes) }, more: { showTab(.traces) })
                }
                .padding()
            }
        }
    }

    private var e2ePoints: [(Int, Double)] {
        detail.transcript.filter { $0.role == .agent }.compactMap(\.e2eLatencyMs).enumerated().map { ($0 + 1, $1) }
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
    private func header(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary) }
    @ViewBuilder private func latency(_ label: String, _ s: SessionInsights.Stat?) -> some View {
        GridRow {
            Text(label)
            Text(Format.ms(s?.median)).monospacedDigit()
            Text(Format.ms(s?.p95)).monospacedDigit().foregroundStyle((s?.p95 ?? 0) >= SessionInsights.slowTurnMs ? .orange : .primary)
            Text(Format.ms(s?.max)).monospacedDigit()
            Text(s.map { "\($0.count)" } ?? "–").monospacedDigit().foregroundStyle(.secondary)
        }
    }
    struct Finding {
        let date: Date?
        let text: String
        var detail: [String: JSONValue] = [:]
    }

    /// A finding as plain text: time from recording start, the text, and any attributes.
    private func copyText(_ f: Finding, includeDetail: Bool) -> String {
        var line = "[\(Format.offset(f.date, from: origin))] \(f.text)"
        if includeDetail, !f.detail.isEmpty {
            line += "\n" + f.detail.keys.sorted().map { "    \($0): \(f.detail[$0]!.description)" }.joined(separator: "\n")
        }
        return line
    }

    @ViewBuilder private func findings(_ title: String, items: [Finding], limit: Int = 15, more: (() -> Void)? = nil) -> some View {
        if !items.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, item in
                        FindingRow(time: TimeButton(date: item.date, origin: origin), text: item.text, flag: detail.flag(at: item.date)) {
                            AppModel.copy(copyText(item, includeDetail: true))
                        }
                    }
                    if items.count > limit, let more { Button("Show all \(items.count)", action: more).buttonStyle(.link) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack {
                    Text(title).font(.headline)
                    Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { AppModel.copy(items.map { copyText($0, includeDetail: false) }.joined(separator: "\n")) } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).font(.caption).help("Copy every item in this list as text")
                }
            }
        }
    }
}

// MARK: Transcript

struct TranscriptView: View {
    let detail: SessionDetail
    let origin: Date?
    @Environment(AppModel.self) private var model
    @State private var follow = true
    @State private var onlyFlagged = false

    var body: some View {
        let current = currentItemID
        ScrollViewReader { proxy in
            List(onlyFlagged ? detail.transcript.filter { detail.flag(for: $0) != nil } : detail.transcript) { item in
                TranscriptRow(item: item, origin: origin, isCurrent: item.id == current, flag: detail.flag(for: item))
                    .id(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.player.play(at: item.start) }
                    .contextMenu {
                        if let start = item.start {
                            FlagMenuItems(detail: detail, existing: detail.flag(for: item), title: "Flag This Line") {
                                detail.addFlag(from: start, to: item.stoppedSpeakingAt ?? start.addingTimeInterval(1), note: SessionDetail.label(for: item))
                            }
                        }
                        Button("Copy Line") { AppModel.copy("[\(Format.offset(item.start, from: origin))] \(item.text)") }
                    }
            }
            .onChange(of: current) { _, id in
                if follow, model.player.isPlaying, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Follow playback", isOn: $follow).toggleStyle(.checkbox)
                Toggle("Flagged only", isOn: $onlyFlagged).toggleStyle(.checkbox).disabled(detail.flags.isEmpty && !onlyFlagged)
                Spacer()
                Text("Double-click a line to play it. Right-click to flag it.").foregroundStyle(.secondary)
            }
            .font(.caption).padding(8).background(.bar)
        }
    }

    /// The line being spoken at the playhead.
    private var currentItemID: TranscriptItem.ID? {
        guard model.player.isLoaded, let now = model.player.currentDate else { return nil }
        return detail.transcript.last { ($0.start ?? .distantFuture) <= now }?.id
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let origin: Date?
    let isCurrent: Bool
    var flag: Flag?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            FlagIcon(flag: flag)
            TimeButton(date: item.start, origin: origin).frame(width: 56, alignment: .leading)
            Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(color).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).textSelection(.enabled)
                    .font(item.kind == "message" ? .body : .callout.monospaced())
                let notes = annotations
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : flag != nil ? Flag.color.opacity(0.22) : (item.e2eLatencyMs ?? 0) >= SessionInsights.slowTurnMs ? Color.orange.opacity(0.08) : nil)
    }

    private var speaker: String {
        switch item.role {
        case .agent: return "Agent"
        case .user: return "User"
        case .system: return "System"
        case .other: return item.kind.replacingOccurrences(of: "_", with: " ")
        }
    }
    private var color: Color { item.role == .agent ? .blue : item.role == .user ? .green : .secondary }
    private var annotations: [String] {
        var notes: [String] = []
        if let e = item.e2eLatencyMs { notes.append("response \(Format.ms(e))") }
        if let l = item.llmTtftMs { notes.append("LLM \(Format.ms(l))") }
        if let t = item.ttsTtfbMs { notes.append("TTS \(Format.ms(t))") }
        if let c = item.confidence { notes.append(String(format: "confidence %.2f", c)) }
        if let d = item.endOfTurnDelayMs { notes.append("end of turn \(Format.ms(d))") }
        if item.interrupted { notes.append("interrupted") }
        return notes
    }
}

// MARK: Logs

struct LogsView: View {
    let detail: SessionDetail
    let origin: Date?
    @State private var minimum: LogLevel = .info
    @State private var search = ""
    @State private var selected: Set<LogRecord.ID> = []
    @State private var onlyFlagged = false

    var body: some View {
        let records = detail.logs.filter { (!onlyFlagged || detail.flag(for: $0) != nil) && $0.level >= minimum && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search) || $0.logger.localizedCaseInsensitiveContains(search)) }
        VStack(spacing: 0) {
            HStack {
                Picker("Level", selection: $minimum) { ForEach(LogLevel.allCases, id: \.self) { Text("\($0.label)+").tag($0) } }.frame(width: 160)
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Flagged only", isOn: $onlyFlagged).toggleStyle(.checkbox).disabled(detail.flags.isEmpty && !onlyFlagged)
                Text("\(records.count) of \(detail.logs.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            HSplitView {
                Table(records, selection: $selected) {
                    TableColumn("") { r in FlagIcon(flag: detail.flag(for: r)) }.width(14)
                    TableColumn("Time") { r in TimeButton(date: r.timestamp, origin: origin) }.width(60)
                    TableColumn("Level") { r in Text(r.level.label).foregroundStyle(color(r.level)) }.width(50)
                    TableColumn("Logger") { r in Text(r.logger).foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                    TableColumn("Message") { r in Text(r.message).lineLimit(2) }
                }
                .contextMenu(forSelectionType: LogRecord.ID.self) { ids in
                    Button(ids.count > 1 ? "Copy \(ids.count) Lines" : "Copy") { copy(ids, from: records) }
                    Button("Copy Message Only") { AppModel.copy(records.filter { ids.contains($0.id) }.map(\.message).joined(separator: "\n")) }
                    if ids.count == 1, let record = records.first(where: { ids.contains($0.id) }), let time = record.timestamp {
                        Divider()
                        FlagMenuItems(detail: detail, existing: detail.flag(for: record), title: "Flag This Moment") {
                            detail.addFlag(at: time, wholeTurn: false)
                        }
                    }
                }
                .onCopyCommand { copy(selected, from: records); return [] }
                .frame(minWidth: 340, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                Group {
                    if selected.count == 1, let record = detail.logs.first(where: { selected.contains($0.id) }) {
                        AttributesView(title: record.message, attributes: record.attributes)
                    } else {
                        SelectionHint(text: selected.isEmpty ? "Select a line to see its attributes." : "\(selected.count) lines selected.")
                    }
                }
                .sizedBySplitView()
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 480, maxHeight: .infinity)
            }
        }
    }

    private func copy(_ ids: Set<LogRecord.ID>, from records: [LogRecord]) {
        let lines = records.filter { ids.contains($0.id) }.map { r in
            "[\(Format.offset(r.timestamp, from: origin))] \(r.level.label.uppercased()) \(r.logger.isEmpty ? "" : r.logger + ": ")\(r.message)"
        }
        if !lines.isEmpty { AppModel.copy(lines.joined(separator: "\n")) }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level { case .warn: .orange; case .error, .fatal: .red; case .debug, .trace: .secondary; default: .primary }
    }
}

struct AttributesView: View {
    let title: String
    let attributes: [String: JSONValue]
    var body: some View {
        List {
            Section { Text(title).textSelection(.enabled) }
            Section("Attributes") {
                ForEach(attributes.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading) {
                        Text(key).font(.caption).foregroundStyle(.secondary)
                        Text(attributes[key]!.description).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

extension View {
    /// Fills whatever width its split view pane has, without its content asking for more. Otherwise selecting a
    /// line with long attributes widened the pane, and the list beside it lost its scroll position.
    func sizedBySplitView() -> some View {
        GeometryReader { geo in
            self.frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

// MARK: Traces

struct SpanNode: Identifiable {
    let span: Span
    var children: [SpanNode]?
    var id: String { span.id }

    static func tree(_ spans: [Span]) -> [SpanNode] {
        let ids = Set(spans.map(\.id))
        let byParent = Dictionary(grouping: spans) { $0.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? "" }
        func build(_ parent: String) -> [SpanNode] {
            (byParent[parent] ?? []).sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }.map { span in
                let kids = build(span.id)
                return SpanNode(span: span, children: kids.isEmpty ? nil : kids)
            }
        }
        return build("")
    }
}

struct TracesView: View {
    let detail: SessionDetail
    let origin: Date?
    @State private var selected: Span.ID?

    var body: some View {
        HSplitView {
            // The tree is its own view, rebuilt only when the spans or flags change. Rebuilding it on every
            // selection made the outline view reload and jump away from the row that was clicked.
            SpanTree(detail: detail, spans: detail.spans, flags: detail.flags, selected: $selected)
                .equatable()
                .frame(minWidth: 340, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            // Always present, so selecting the first span does not add a pane and rebuild the split view.
            Group {
                if let span = detail.spans.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading) {
                        HStack { Text("Starts"); TimeButton(date: span.start, origin: origin) }.font(.caption).padding([.top, .horizontal])
                        AttributesView(title: span.statusMessage.isEmpty ? span.name : "\(span.name): \(span.statusMessage)", attributes: span.attributes)
                    }
                } else {
                    SelectionHint(text: "Select a span to see its attributes.")
                }
            }
            .sizedBySplitView()
            .frame(minWidth: 220, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if detail.spans.isEmpty { ContentUnavailableView("No trace spans", systemImage: "point.3.connected.trianglepath.dotted") } }
    }
}

/// The span tree. Equal when its spans and flags are, so a new selection does not rebuild it. Expansion is kept
/// in the session rather than in the list, so a rebuild (when the session's data is reread) doesn't collapse it.
private struct SpanTree: View, Equatable {
    let detail: SessionDetail
    let spans: [Span]
    let flags: [Flag]
    @Binding var selected: Span.ID?

    static func == (a: SpanTree, b: SpanTree) -> Bool { a.detail === b.detail && a.spans == b.spans && a.flags == b.flags }

    var body: some View {
        let roots = SpanNode.tree(spans)
        let start = spans.compactMap(\.start).min()
        let end = spans.compactMap(\.end).max()
        let context = SpanRowContext(
            detail: detail, marked: detail.flaggedSpans(), origin: start,
            total: max((end ?? .now).timeIntervalSince(start ?? .now), 0.001)
        )
        List(selection: $selected) {
            ForEach(roots) { SpanBranch(node: $0, context: context) }
        }
    }
}

/// What every row in the tree shares.
private struct SpanRowContext {
    let detail: SessionDetail
    let marked: (flagged: Set<Span.ID>, ancestors: Set<Span.ID>)
    let origin: Date?
    let total: TimeInterval
}

/// A span and, when expanded, its children.
private struct SpanBranch: View {
    let node: SpanNode
    let context: SpanRowContext

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(children) { SpanBranch(node: $0, context: context) }
            } label: {
                row
            }
            .tag(node.id)
        } else {
            row.tag(node.id)
        }
    }

    private var expanded: Binding<Bool> {
        let detail = context.detail, id = node.id
        return Binding(
            get: { detail.expandedSpans.contains(id) },
            set: { if $0 { detail.expandedSpans.insert(id) } else { detail.expandedSpans.remove(id) } }
        )
    }

    private var row: some View {
        let detail = context.detail
        let flag = context.marked.flagged.contains(node.id) ? detail.flag(for: node.span) : nil
        return HStack {
            Image(systemName: node.span.failed ? "xmark.octagon.fill" : "circle.fill").font(.system(size: 6)).foregroundStyle(node.span.failed ? .red : .secondary)
            Text(node.span.name).lineLimit(1)
            if flag != nil {
                FlagIcon(flag: flag)
            } else if context.marked.ancestors.contains(node.id) {
                Image(systemName: "flag").font(.caption2).foregroundStyle(Flag.color).help("Contains flagged spans")
            }
            Spacer()
            TimelineBar(start: node.span.start, duration: node.span.duration, origin: context.origin, total: context.total).frame(minWidth: 60, maxWidth: 180).frame(height: 8)
            Text(node.span.duration.map { $0 < 1 ? "\(Int($0 * 1000)) ms" : String(format: "%.2f s", $0) } ?? "–")
                .font(.caption.monospacedDigit()).foregroundStyle((node.span.duration ?? 0) >= 2 ? .orange : .secondary).frame(width: 64, alignment: .trailing)
        }
        .listRowBackground(flag != nil ? Flag.color.opacity(0.22) : nil)
        .contextMenu {
            if let spanStart = node.span.start {
                FlagMenuItems(detail: detail, existing: flag, title: "Flag This Span") {
                    detail.addFlag(from: spanStart, to: node.span.end ?? spanStart, note: node.span.name)
                }
            }
        }
    }
}

struct TimelineBar: View {
    let start: Date?
    let duration: TimeInterval?
    let origin: Date?
    let total: TimeInterval
    var body: some View {
        GeometryReader { geo in
            let x = (start.flatMap { s in origin.map { s.timeIntervalSince($0) } } ?? 0) / total
            let w = max((duration ?? 0) / total, 0.004)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * w).offset(x: geo.size.width * x)
            }
        }
    }
}

// MARK: Metrics

struct MetricsView: View {
    let detail: SessionDetail

    struct Summary: Identifiable {
        let name: String
        let unit: String
        let count: Double
        let mean: Double?
        let min: Double?
        let max: Double?
        let points: Int
        var id: String { name }
    }

    var body: some View {
        let summaries = Dictionary(grouping: detail.metrics, by: \.name).map { name, points in
            let count = points.compactMap(\.count).reduce(0, +)
            let sum = points.compactMap(\.sum).reduce(0, +)
            let values = points.compactMap(\.value)
            return Summary(
                name: name, unit: points.first?.unit ?? "", count: count,
                mean: count > 0 ? sum / count : values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                min: points.compactMap(\.min).min() ?? values.min(), max: points.compactMap(\.max).max() ?? values.max(), points: points.count
            )
        }.sorted { $0.name < $1.name }
        Table(summaries) {
            TableColumn("Metric") { s in Text(s.name).textSelection(.enabled) }.width(min: 220, ideal: 300)
            TableColumn("Unit") { s in Text(s.unit).foregroundStyle(.secondary) }.width(40)
            TableColumn("Count") { s in Text(s.count > 0 ? "\(Int(s.count))" : "–").monospacedDigit() }.width(60)
            TableColumn("Mean") { s in Text(value(s.mean, s.unit)).monospacedDigit() }.width(80)
            TableColumn("Min") { s in Text(value(s.min, s.unit)).monospacedDigit() }.width(80)
            TableColumn("Max") { s in Text(value(s.max, s.unit)).monospacedDigit() }.width(80)
            TableColumn("Points") { s in Text("\(s.points)").monospacedDigit().foregroundStyle(.secondary) }.width(50)
        }
        .overlay { if detail.metrics.isEmpty { ContentUnavailableView("No metrics", systemImage: "chart.xyaxis.line") } }
    }

    private func value(_ v: Double?, _ unit: String) -> String {
        guard let v else { return "–" }
        return unit == "s" ? "\(Int((v * 1000).rounded())) ms" : v.formatted(.number.precision(.significantDigits(4)))
    }
}

/// What the session cost at the chosen plan's overage rates.
struct CostBox: View {
    let detail: SessionDetail
    @AppStorage("pricePlan") private var planId = PricePlan.scale.id
    @AppStorage("noiseCancellation") private var noiseCancellation = false

    var body: some View {
        let plan = PricePlan.named(planId)
        let lines = SessionCost.lines(plan: plan, room: detail.room, spans: detail.spans, metrics: detail.metrics, logs: detail.logs,
                                      transcriptItems: detail.transcript.count, noiseCancellation: noiseCancellation)
        let total = lines.compactMap(\.cost).reduce(0, +)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(CostLine.Group.allCases, id: \.self) { group in
                        let rows = lines.filter { $0.group == group }
                        if !rows.isEmpty {
                            GridRow {
                                Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text("Used").font(.caption).foregroundStyle(.secondary)
                                Text("Rate").font(.caption).foregroundStyle(.secondary)
                                Text("Cost").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            }
                            ForEach(rows) { line in
                                GridRow {
                                    Text(line.item).textSelection(.enabled)
                                    Text(line.quantity).monospacedDigit().foregroundStyle(.secondary)
                                    Text(line.rate).foregroundStyle(.secondary)
                                    Text(line.cost.map(Format.dollars) ?? "–").monospacedDigit()
                                }
                            }
                        }
                    }
                    Divider()
                    GridRow {
                        Text("Total").font(.headline)
                        Text(Format.duration(detail.row.duration)).foregroundStyle(.secondary)
                        Text(detail.row.duration.map { $0 > 0 ? "\(Format.dollars(total / ($0 / 60)))/min" : "" } ?? "").foregroundStyle(.secondary)
                        Text(Format.dollars(total)).font(.headline.monospacedDigit())
                    }
                }
                Text("At \(plan.name) overage rates, so this is what the session costs once the month's included usage runs out; before that it is covered by the plan. \(plan.note) Lines marked “billed by” use your own provider keys and are not LiveKit charges.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if detail.room == nil && !detail.loadingObservability {
                    Text("LiveKit didn't return participant times for this session, so connection costs are missing.").font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: {
            HStack {
                Text("Cost").font(.headline)
                Text(Format.dollars(total)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Krisp noise cancellation", isOn: $noiseCancellation).toggleStyle(.checkbox).font(.caption)
                    .help("Turn on if your agent uses LiveKit's noise cancellation (BVC/NC). LiveKit doesn't report it per session.")
                Picker("Plan", selection: $planId) { ForEach(PricePlan.all) { Text($0.name).tag($0.id) } }
                    .labelsHidden().fixedSize().controlSize(.small)
            }
        }
    }
}

/// One overview finding: selectable text, with a copy button on hover and in the context menu.
struct FindingRow: View {
    let time: TimeButton
    let text: String
    var flag: Flag?
    let copy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            FlagIcon(flag: flag)
            time.frame(width: 56, alignment: .leading)
            Text(text).lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy this line and its details")
                .opacity(hovering || copied ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Copy", action: copy) }
    }
}

// MARK: Flags

extension Flag {
    static let color = Color.yellow
}

/// A flag beside a flagged row, with the flag's note as its tooltip; blank space otherwise so rows line up.
struct FlagIcon: View {
    let flag: Flag?
    var body: some View {
        Image(systemName: "flag.fill").font(.caption).foregroundStyle(Flag.color)
            .opacity(flag == nil ? 0 : 1)
            .help(flag.map { $0.note.isEmpty ? "Flagged" : $0.note } ?? "")
            .accessibilityHidden(flag == nil)
            .accessibilityLabel(flag.map { "Flagged: \($0.note)" } ?? "")
    }
}

/// Context-menu items that flag something, or edit or remove the flag it already has.
struct FlagMenuItems: View {
    let detail: SessionDetail
    let existing: Flag?
    let title: String
    let add: () -> Flag
    @Environment(AppModel.self) private var model

    var body: some View {
        if let existing {
            Button("Edit Flag Note…") { model.renamingFlag = existing.id }
            Button("Remove Flag") { detail.removeFlag(existing.id) }
        } else {
            Button(title) { model.renamingFlag = add().id }
        }
    }
}

/// The toolbar's list of flags: choosing one moves the playhead there.
struct FlagsMenu: View {
    let detail: SessionDetail
    let origin: Date?
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Flag Playhead") { model.flagPlayhead() }.disabled(model.player.currentDate == nil)
            if !detail.flags.isEmpty {
                Section("Go to") {
                    ForEach(detail.flags) { flag in
                        Button("\(Format.offset(flag.start, from: origin))  \(flag.note.isEmpty ? "Flag" : flag.note)") { model.player.play(at: flag.start, leadIn: 0.5) }
                    }
                }
                Divider()
                Button("Remove All Flags", role: .destructive) { for flag in detail.flags { detail.removeFlag(flag.id) } }
            }
        } label: {
            Label(detail.flags.isEmpty ? "Flags" : "Flags (\(detail.flags.count))", systemImage: detail.flags.isEmpty ? "flag" : "flag.fill")
        }
        .help("Flag a moment to highlight it in every view (⌥M flags the playhead; right-click in any view)")
    }
}

/// The session's flags at the top of the overview.
struct FlagsBox: View {
    let detail: SessionDetail
    let origin: Date?
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(detail.flags) { flag in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(Flag.color)
                        TimeButton(date: flag.start, origin: origin).frame(width: 56, alignment: .leading)
                        Text(flag.note.isEmpty ? "No note" : flag.note).foregroundStyle(flag.note.isEmpty ? .secondary : .primary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f s", flag.end.timeIntervalSince(flag.start))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Edit Flag Note…") { model.renamingFlag = flag.id }
                        Button("Remove Flag") { detail.removeFlag(flag.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack { Text("Flagged").font(.headline); Text("\(detail.flags.count)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A quiet note in an empty side pane. Unlike ContentUnavailableView it has no large ideal size,
/// which pushed the split view wider than the window.
struct SelectionHint: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}
