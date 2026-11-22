import ObserverCore
import Observation
import SwiftUI

@MainActor @Observable
final class PacketViewerModel {
    let capture: PacketCapture
    private let store: AttachmentStore
    private(set) var page: PacketPage?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var selectedID: UInt64?
    private(set) var contents: PacketContents?
    private(set) var detailError: String?
    private(set) var loadingDetail = false
    private(set) var selectedPacket: InspectedPacket?
    private var current: PacketCursor?
    private var history: [PacketCursor?] = []
    private var pageTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var generation = UUID()
    private var detailGeneration = UUID()

    init(capture: PacketCapture, store: AttachmentStore) {
        self.capture = capture
        self.store = store
    }

    var canGoBack: Bool { !history.isEmpty && !loading }

    func first() { load(from: nil, history: []) }
    func next() {
        guard !loading, let cursor = page?.next else { return }
        // Keep navigation bounded even when browsing millions of packets.
        load(from: cursor, history: Array((history + [current]).suffix(32)))
    }
    func previous() {
        guard canGoBack else { return }
        var previous = history
        let cursor = previous.removeLast()
        load(from: cursor, history: previous)
    }

    private func load(from cursor: PacketCursor?, history proposedHistory: [PacketCursor?]) {
        pageTask?.cancel()
        select(nil)
        let token = UUID()
        generation = token
        loading = true
        error = nil
        pageTask = Task { [weak self, capture, store] in
            let file = await store.file(for: capture)
            let worker = Task.detached(priority: .userInitiated) { try PacketPageReader.read(file, from: cursor) }
            do {
                let page = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.page = page
                self.current = cursor
                self.history = proposedHistory
                self.loading = false
                self.pageTask = nil
                self.select(page.packets.first?.id)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.loading = false
                self.pageTask = nil
            }
        }
    }

    func select(_ id: UInt64?) {
        inspect(page?.packets.first { $0.id == id })
    }

    func inspect(_ packet: InspectedPacket?) {
        detailTask?.cancel()
        let token = UUID()
        detailGeneration = token
        selectedID = packet?.id
        selectedPacket = packet
        contents = nil
        detailError = nil
        loadingDetail = false
        guard let packet else { return }
        loadingDetail = true
        detailTask = Task { [weak self, store, capture] in
            let file = await store.file(for: capture)
            let worker = Task.detached(priority: .userInitiated) { try PacketPageReader.detail(file, packet: packet) }
            do {
                let contents = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.detailGeneration == token, !Task.isCancelled else { return }
                self.contents = contents
                self.loadingDetail = false
                self.detailTask = nil
            } catch {
                guard let self, self.detailGeneration == token, !Task.isCancelled else { return }
                self.detailError = error.localizedDescription
                self.loadingDetail = false
                self.detailTask = nil
            }
        }
    }

    func cancel() {
        generation = UUID()
        detailGeneration = UUID()
        pageTask?.cancel()
        detailTask?.cancel()
        pageTask = nil
        detailTask = nil
        loading = false
        loadingDetail = false
    }
}

struct PacketCaptureViewer: View {
    @State private var viewer: PacketViewerModel
    @State private var analysis: CaptureAnalysisModel
    @State private var tab = "Call Flow"
    @State private var explaining = false
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(capture: PacketCapture, store: AttachmentStore) {
        _viewer = State(initialValue: PacketViewerModel(capture: capture, store: store))
        _analysis = State(initialValue: CaptureAnalysisModel(capture: capture, store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "network").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewer.capture.originalName).font(.title2).lineLimit(1).truncationMode(.middle)
                    Text("\(viewer.capture.session.projectName) · \(viewer.capture.session.sessionID) · \(viewer.capture.format.rawValue.uppercased()) · \(Format.bytes(viewer.capture.byteCount))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if !analysis.findings.isEmpty, app.detail?.row.id == viewer.capture.session.sessionID {
                    Button("Explain findings…", systemImage: "sparkles") { explaining = true }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Capture view", selection: $tab) {
                Text("Call Flow").tag("Call Flow")
                Text("Jitter").tag("Jitter")
                Text("Expert Analysis (\(analysis.findings.count))").tag("Expert Analysis")
                Text("Packets").tag("Packets")
            }.pickerStyle(.segmented)
            if analysis.running {
                HStack {
                    ProgressView(value: analysis.progress.map { Double($0.read) / Double(max(1, $0.size)) })
                    Text("Analyzing \((analysis.progress?.packets ?? 0).formatted()) packets…").font(.caption).fixedSize()
                    Button("Cancel") { analysis.cancel() }
                }
            }
            if let error = analysis.error {
                HStack { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    if analysis.result == nil { Button("Start Analysis") { analysis.start() }.disabled(analysis.running) }
                }
            }
            if let result = analysis.result {
                HStack {
                    Text("\(result.processed.formatted()) packets analyzed · \(result.calls.count) \(result.calls.count == 1 ? "call" : "calls") · \(result.streams.count) RTP candidates\(result.complete ? "" : " · Partial capture coverage")")
                        .font(.caption).foregroundStyle(result.complete ? Color.secondary : .orange)
                    Spacer()
                    if tab == "Call Flow" || tab == "Expert Analysis" {
                        Picker("Call", selection: $analysis.selectedCall) {
                            Text("All calls").tag("")
                            ForEach(result.calls, id: \.self) { call in Text(String(call.prefix(100))).tag(call) }
                        }.frame(maxWidth: 400)
                    }
                }
                if !result.warnings.isEmpty {
                    DisclosureGroup("Analysis coverage (\(result.warnings.count) notes)") {
                        ForEach(result.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
                    }.font(.caption)
                }
            }
            if let error = viewer.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                Button("Retry") { viewer.first() }
            }
            if tab == "Packets", let page = viewer.page {
                ForEach(page.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            if tab == "Packets" {
                packetTable
                    .overlay { if viewer.loading { ProgressView("Reading packets…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
                navigation
            } else if let result = analysis.result {
                switch tab {
                case "Jitter": CaptureJitterView(model: analysis) { viewer.inspect($0) }
                case "Expert Analysis":
                    CaptureFindingsView(findings: analysis.findings.filter { analysis.selectedCall.isEmpty || $0.callID == nil || $0.callID == analysis.selectedCall },
                                        complete: result.complete, inspect: { viewer.inspect($0) }, jitter: { analysis.selectedStream = $0; analysis.jitterOverviewVisible = false; tab = "Jitter" })
                default: CaptureFlowView(analysis: result, callID: analysis.selectedCall) { viewer.inspect($0) }
                }
            } else {
                ContentUnavailableView(analysis.running ? "Reading signaling and media" : "Capture analysis", systemImage: "arrow.left.arrow.right",
                    description: Text("The bounce diagram, jitter metrics and expert findings are built locally. Raw packets remain available while analysis runs."))
            }
            if viewer.selectedPacket != nil {
                Divider()
                HStack {
                    Text("Packet evidence").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close Details", systemImage: "xmark") { viewer.inspect(nil) }.labelStyle(.iconOnly).buttonStyle(.plain)
                }
                packetDetail.frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 210)
            }
        }
        .padding(20)
        .frame(minWidth: 980, idealWidth: 1200, minHeight: 740, idealHeight: 860)
        .task { analysis.start() }
        .sheet(isPresented: $explaining) {
            if let detail = app.detail, let project = app.selectedProject {
                AIReviewView(detail: detail, project: project, captureEvidence: captureEvidence)
            }
        }
        .onChange(of: tab) { _, new in if new == "Packets", viewer.page == nil { viewer.first() } }
        .onDisappear { viewer.cancel(); analysis.cancel() }
    }

    private var captureEvidence: [AIEvidence] {
        [AIEvidence(id: "capture-coverage", kind: "Capture limitations", text: "Capture clock is not aligned with the session. Packet timestamps must not be treated as transcript timestamps. " + (analysis.result?.warnings.joined(separator: " ") ?? "Coverage unknown."), date: nil)]
        + analysis.findings.filter { analysis.selectedCall.isEmpty || $0.callID == nil || $0.callID == analysis.selectedCall }.prefix(30).enumerated().map { index, finding in
            AIEvidence(id: "capture-finding-\(index)-packet-\(finding.evidence.id)", kind: "Local packet finding: " + finding.rule,
                       text: AIReviewView.redacted(String((finding.title + "\n" + finding.observation + "\n" + finding.explanation + "\nNext check: " + finding.nextCheck).prefix(2000))), date: nil)
        }
    }

    private var packetTable: some View {
        Table(viewer.page?.packets ?? [], selection: Binding(get: { viewer.selectedID }, set: { viewer.select($0) })) {
            TableColumn("No.") { packet in Text(packet.id.formatted()).monospacedDigit() }.width(55)
            TableColumn("Time (UTC)") { packet in
                Text(packet.time.map { String($0.text.split(separator: "T").last ?? "Unknown") } ?? "Unknown")
                    .monospacedDigit().help(packet.time?.text ?? "No capture timestamp")
            }.width(min: 130, ideal: 150)
            TableColumn("Source") { Text($0.decoded.source).help($0.decoded.source) }.width(min: 120, ideal: 170)
            TableColumn("Destination") { Text($0.decoded.destination).help($0.decoded.destination) }.width(min: 120, ideal: 170)
            TableColumn("Protocol") { Text($0.decoded.protocolName) }.width(65)
            TableColumn("Bytes") { Text($0.capturedLength.formatted()).monospacedDigit() }.width(55)
            TableColumn("Info") { Text($0.decoded.summary).help($0.decoded.summary) }.width(min: 150, ideal: 240)
        }
        .frame(minHeight: 200, idealHeight: 280)
        .disabled(viewer.loading)
        .overlay {
            if !viewer.loading, viewer.page?.packets.isEmpty == true {
                Text(viewer.page?.next == nil ? "No packets on this page" : "No packets in this metadata segment. Choose Next to continue.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navigation: some View {
        HStack {
            if let page = viewer.page {
                VStack(alignment: .leading, spacing: 2) {
                    if let first = page.packets.first, let last = page.packets.last {
                        Text("Packets \(first.id.formatted())–\(last.id.formatted())\(page.next == nil && page.readThrough == page.fileSize ? " · End of capture" : "")")
                    }
                    Text("Read through \(Format.bytes(Int64(clamping: page.readThrough))) of \(Format.bytes(Int64(clamping: page.fileSize))) · Up to 200 packets per page")
                        .foregroundStyle(.secondary)
                }.font(.caption)
            }
            Spacer()
            Button("First") { viewer.first() }.disabled(viewer.loading)
            Button("Previous") { viewer.previous() }.disabled(!viewer.canGoBack)
                .help("Go back through the last 32 pages; First returns to the start")
            Button("Next") { viewer.next() }.disabled(viewer.loading || viewer.page?.next == nil)
        }
    }

    @ViewBuilder private var packetDetail: some View {
        if let packet = viewer.selectedPacket {
            VStack(alignment: .leading, spacing: 8) {
                Text("Packet \(packet.id.formatted()) · \(packet.time?.text ?? "Unknown capture time")").font(.headline).textSelection(.enabled)
                Text("\(packet.capturedLength) captured / \(packet.originalLength) original bytes · Interface \(packet.interface) · Link type \(packet.linkType) · File offset \(packet.offset)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let contents = viewer.contents {
                    PacketContentsView(contents: contents).id(packet.id)
                } else if let error = viewer.detailError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if viewer.loadingDetail { ProgressView("Reading packet…") }
            }
        } else {
            ContentUnavailableView("Select a packet", systemImage: "list.bullet.rectangle",
                                   description: Text("Inspect its decoded headers and captured bytes."))
        }
    }
}

private struct PacketContentsView: View {
    let contents: PacketContents
    @State private var showBytes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Packet details", selection: $showBytes) {
                Text("Decoded headers").tag(false)
                Text("Hex / ASCII").tag(true)
            }.pickerStyle(.segmented).frame(width: 280)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                    if showBytes {
                        Text(contents.hex).font(.system(.caption, design: .monospaced))
                        if contents.capturedLength > 4096 { Text("Showing the first 4,096 captured bytes.").foregroundStyle(.secondary) }
                    } else {
                        Text("\(contents.decoded.source) → \(contents.decoded.destination)").font(.headline)
                        Text(contents.decoded.summary)
                        ForEach(Array(contents.decoded.fields.enumerated()), id: \.offset) { _, field in
                            Text(field).font(.caption).foregroundStyle(.secondary)
                        }
                        if let text = contents.decoded.text {
                            Divider()
                            Text(text).font(.system(.caption, design: .monospaced))
                        }
                        if contents.capturedLength > contents.bytes.count {
                            Text("Decoding is limited to the first 65,536 captured bytes.").foregroundStyle(.secondary)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
