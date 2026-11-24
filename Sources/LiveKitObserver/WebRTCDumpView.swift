import ObserverCore
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum WebRTCDumpOpener {
    /// Asks for a dump and opens each in its own window.
    @MainActor static func choose(_ open: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Open WebRTC Internals Dump"
        panel.message = "Choose a dump downloaded from chrome://webrtc-internals (WebRTC internals or rtcstats, compressed or not)."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }
}

/// A window showing one WebRTC internals or rtcstats dump.
struct WebRTCDumpWindow: View {
    let url: URL?
    @State private var loaded: Result<(WebRTCDump, WebRTCAnalysis), Error>?
    var body: some View {
        Group {
            switch loaded {
            case nil: ProgressView("Reading \(url?.lastPathComponent ?? "dump")…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error):
                ContentUnavailableView("Can't read this file", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            case .success(let (dump, analysis)): WebRTCDumpView(name: url?.lastPathComponent ?? "", dump: dump, analysis: analysis)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(url?.lastPathComponent ?? "WebRTC Internals")
        .task(id: url) {
            guard let url else { loaded = .failure(WebRTCDump.ParseError.unrecognized); return }
            loaded = await Task.detached(priority: .userInitiated) {
                Result { let dump = try WebRTCDump.load(url); return (dump, WebRTCAnalysis(dump)) }
            }.value
        }
    }
}

struct WebRTCDumpView: View {
    enum Tab: String, CaseIterable { case findings = "Findings", expert = "Expert Analysis", connection = "Connection", streams = "Streams", timeline = "Timeline", stats = "All Stats" }
    let name: String
    let dump: WebRTCDump
    let analysis: WebRTCAnalysis
    @State private var selected: String?
    @State private var tab: Tab

    init(name: String, dump: WebRTCDump, analysis: WebRTCAnalysis, tab: Tab = .findings, connection: String? = nil) {
        self.name = name; self.dump = dump; self.analysis = analysis
        _tab = State(initialValue: tab); _selected = State(initialValue: connection)
    }

    private var connection: WebRTCConnectionAnalysis? { analysis.connections.first { $0.id == selected } ?? analysis.connections.first }
    private var raw: WebRTCDump.Connection? { dump.connections.first { $0.id == connection?.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2.bold()).lineLimit(1)
                    Text([dump.format.rawValue, dump.exportedAt.map { "saved \($0.formatted(date: .abbreviated, time: .standard))" }, "\(dump.connections.count) peer connection\(dump.connections.count == 1 ? "" : "s")"]
                        .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if !dump.userAgent.isEmpty { Text(dump.userAgent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled) }
                }
                Spacer()
                if analysis.connections.count > 1 {
                    Picker("Peer connection", selection: Binding(get: { connection?.id ?? "" }, set: { selected = $0 })) {
                        ForEach(analysis.connections) { Text("\($0.title) · \($0.id)").tag($0.id) }
                    }.frame(maxWidth: 380)
                }
            }
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab == .findings && !analysis.findings.isEmpty ? "Findings (\(analysis.findings.count))" : tab.rawValue).tag(tab)
                }
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case .findings: WebRTCFindingsView(findings: analysis.findings, dump: dump, starts: Dictionary(analysis.connections.map { ($0.role, $0.start) }, uniquingKeysWith: { a, _ in a }))
                case .expert: WebRTCExpertView(name: name, dump: dump, analysis: analysis)
                case .connection: if let connection { WebRTCConnectionView(connection: connection) } else { empty }
                case .streams: if let connection { WebRTCStreamsView(connection: connection) } else { empty }
                case .timeline: if let raw { WebRTCTimelineView(connection: raw, requests: dump.mediaRequests) } else { empty }
                case .stats: if let raw { WebRTCStatsBrowser(connection: raw).id(raw.id) } else { empty }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding()
    }

    private var empty: some View { ContentUnavailableView("No peer connections", systemImage: "point.3.connected.trianglepath.dotted", description: Text("The dump has no RTCPeerConnection records. Download it while the call is still open.")) }
}

// MARK: - Findings

struct WebRTCFindingsView: View {
    let findings: [WebRTCFinding]
    let dump: WebRTCDump
    let starts: [String: Date?]
    var body: some View {
        if findings.isEmpty {
            ContentUnavailableView("No problems found", systemImage: "checkmark.seal",
                                   description: Text("The connection, route, loss, jitter, concealment, and device checks all passed. Look at Streams for the details."))
        } else {
            List(findings) { finding in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(finding.severity == .error ? .red : finding.severity == .warning ? .orange : .blue).font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(finding.title).font(.headline)
                            if !finding.connection.isEmpty { Text(finding.connection).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if let time = finding.time { Text(stamp(time, from: starts[finding.connection] ?? nil)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        Text(finding.observation).textSelection(.enabled)
                        Text(finding.explanation).font(.callout).foregroundStyle(.secondary)
                        Text("Next: " + finding.nextCheck).font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }
        }
    }
    private func stamp(_ time: Date, from start: Date?) -> String {
        let clock = time.formatted(date: .omitted, time: .standard)
        guard let start else { return clock }
        return clock + String(format: " (+%.1f s)", time.timeIntervalSince(start))
    }
}

// MARK: - Connection

struct WebRTCConnectionView: View {
    let connection: WebRTCConnectionAnalysis
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Role", connection.role + " · " + connection.id)
                    if !connection.page.isEmpty { row("Page", connection.page) }
                    if let start = connection.start, let end = connection.end {
                        row("Recorded", "\(start.formatted(date: .abbreviated, time: .standard)) for \(Format.duration(end.timeIntervalSince(start)))")
                    }
                    row("Route", connection.route?.summary ?? "No selected candidate pair in the stats")
                    if let route = connection.route, !route.localAddress.isEmpty || !route.remoteAddress.isEmpty {
                        row("Addresses", "\(route.localAddress) → \(route.remoteAddress)")
                    }
                    row("Candidates gathered", connection.candidates.isEmpty ? "None recorded" : connection.candidates.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                    if !connection.iceServers.isEmpty { row("ICE servers", connection.iceServers.joined(separator: "\n")) }
                    if !connection.iceTransportPolicy.isEmpty { row("Transport policy", connection.iceTransportPolicy) }
                }
                if let rtt = connection.roundTrip { WebRTCChart(metric: rtt, span: connection.span) }
                if let bandwidth = connection.outgoingBitrate { WebRTCChart(metric: bandwidth, span: connection.span) }
                if !connection.states.isEmpty {
                    Text("State changes").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                        ForEach(connection.states) { change in
                            GridRow {
                                Text(change.time.map { $0.formatted(date: .omitted, time: .standard) } ?? "–").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(change.kind).foregroundStyle(.secondary)
                                Text(change.state).foregroundStyle(["failed", "disconnected", "closed"].contains(change.state) ? .orange : .primary)
                            }
                        }
                    }.font(.callout)
                }
                if !connection.candidateErrors.isEmpty {
                    Text("ICE candidate errors").font(.headline)
                    ForEach(Array(connection.candidateErrors.prefix(50).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing)
        }
    }
    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}

// MARK: - Streams

struct WebRTCStreamsView: View {
    let connection: WebRTCConnectionAnalysis
    var body: some View {
        if connection.streams.isEmpty {
            ContentUnavailableView("No media streams", systemImage: "waveform.slash", description: Text("This connection has no inbound or outbound RTP stats; it may carry only data channels."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(connection.streams) { stream in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: stream.kind == "video" ? "video" : stream.sending ? "mic" : "speaker.wave.2").foregroundStyle(stream.sending ? .blue : .green)
                                Text(stream.title).font(.headline).lineLimit(1)
                                Spacer()
                                Text([stream.codec, stream.ssrc.isEmpty ? nil : "SSRC \(stream.ssrc)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            ForEach(Array(stream.facts.enumerated()), id: \.offset) { _, fact in
                                Text("\(fact.0): \(fact.1)").font(.caption).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 12) {
                                ForEach(stream.metrics) { WebRTCChart(metric: $0, span: connection.span) }
                            }
                        }
                        Divider()
                    }
                }.padding(.trailing)
            }
        }
    }
}

/// A compact line chart of one metric with its median and peak.
struct WebRTCChart: View {
    let metric: WebRTCMetric
    /// The connection's time span, so charts of the same connection line up.
    var span: ClosedRange<Date>?
    var body: some View {
        let points = Self.thin(metric.points, to: 600)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.name).font(.callout.bold())
                Spacer()
                if let median = metric.median, let peak = metric.maximum {
                    Text("median \(Self.format(median)) · peak \(Self.format(peak)) \(metric.unit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value(metric.name, point.value)).interpolationMethod(.linear)
            }
            .chartXScale(domain: span ?? (points.first?.time ?? .now)...(points.last?.time ?? .now))
            .chartYAxisLabel(metric.unit)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
            .frame(height: 110)
        }
    }
    static func format(_ value: Double) -> String { value >= 100 ? String(format: "%.0f", value) : value >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value) }
    /// Keeps charts responsive for long dumps by taking every nth point.
    static func thin(_ points: [WebRTCMetric.Point], to limit: Int) -> [WebRTCMetric.Point] {
        guard points.count > limit else { return points }
        let step = Int((Double(points.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }
}

// MARK: - Timeline

struct WebRTCTimelineView: View {
    let connection: WebRTCDump.Connection
    let requests: [WebRTCDump.MediaRequest]
    @State private var search = ""
    @State private var hideCandidates = true
    @State private var expanded: Set<Int> = []

    private var entries: [WebRTCDump.LogEntry] {
        connection.log.filter { entry in
            (!hideCandidates || !["icecandidate", "onicecandidate", "addicecandidate"].contains(entry.type.lowercased()))
                && (search.isEmpty || entry.type.localizedCaseInsensitiveContains(search) || entry.value.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search events and SDP", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Hide individual candidates", isOn: $hideCandidates).toggleStyle(.checkbox)
            }
            if !requests.isEmpty {
                DisclosureGroup("Device requests (\(requests.count))") {
                    ForEach(requests) { request in
                        Text("\(request.time.map { $0.formatted(date: .omitted, time: .standard) } ?? "–")  \(request.kind)  audio: \(request.audio.isEmpty ? "–" : request.audio)  video: \(request.video.isEmpty ? "–" : request.video)\(request.error.map { "  error: \($0)" } ?? "")")
                            .font(.caption.monospaced()).foregroundStyle(request.error == nil ? Color.primary : .red).textSelection(.enabled)
                    }
                }
            }
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.time.map { $0.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))) } ?? "–").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(entry.type).font(.callout.bold()).foregroundStyle(color(entry))
                        Text(entry.value.split(separator: "\n").first.map(String.init) ?? "").font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if entry.value.count > 80 || entry.value.contains("\n") {
                            Button { if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) } } label: {
                                Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                            }.buttonStyle(.borderless)
                        }
                    }
                    if expanded.contains(entry.id) { JSONText(entry.value.replacingOccurrences(of: "\\r\\n", with: "\n")) }
                }
            }
            Text("\(entries.count) of \(connection.log.count) events").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func color(_ entry: WebRTCDump.LogEntry) -> Color {
        let type = entry.type.lowercased(), value = entry.value.lowercased()
        if type.contains("error") || type.contains("failure") || value.contains("failed") { return .red }
        if value.contains("disconnected") { return .orange }
        if type.contains("statechange") { return .blue }
        return .primary
    }
}

// MARK: - All stats

struct WebRTCStatsBrowser: View {
    let connection: WebRTCDump.Connection
    @State private var report: String?
    @State private var property: String?
    @State private var filter = ""

    private var reports: [WebRTCDump.Report] {
        connection.reports.values.filter { filter.isEmpty || $0.type.localizedCaseInsensitiveContains(filter) || $0.id.localizedCaseInsensitiveContains(filter) }
            .sorted { ($0.type, $0.id) < ($1.type, $1.id) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 6) {
                TextField("Filter by type or id", text: $filter).textFieldStyle(.roundedBorder)
                List(reports, selection: $report) { report in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.type).font(.callout)
                        Text(report.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.tag(report.id)
                }
            }.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            if let current = report.flatMap({ connection.reports[$0] }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(current.type) · \(current.id)").font(.headline).textSelection(.enabled)
                    if let name = property, let series = current.properties[name], let metric = WebRTCAnalysis.direct(series, name, "", scale: 1), !metric.points.isEmpty {
                        WebRTCChart(metric: metric)
                    }
                    List(current.properties.keys.sorted(), id: \.self, selection: $property) { name in
                        let series = current.properties[name]
                        HStack {
                            Text(name).font(.callout.monospaced())
                            Spacer()
                            Text(series?.last?.description ?? "").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                            if (series?.numbers.count ?? 0) > 1 { Image(systemName: "chart.xyaxis.line").foregroundStyle(.tertiary).help("Select to chart") }
                        }.tag(name)
                    }
                }.padding(.leading, 8).frame(minWidth: 400)
            } else {
                ContentUnavailableView("Choose a stats object", systemImage: "list.bullet.rectangle", description: Text("Select a property with a chart icon to plot it.")).frame(minWidth: 400)
            }
        }
    }
}
