import ObserverCore
import SwiftUI

/// Controls for the per-channel overlays; there is no separate jitter plot.
struct SpectrogramJitterView: View {
    let captures: [PacketCapture]
    @Bindable var chart: SpectrogramJitterModel
    let lanes: [CaptureAudioLane]
    let wholeWindow: ClosedRange<Date>
    @Environment(AppModel.self) private var model
    @State private var selectedCapture: UUID?
    @State private var offsetInput = "0"
    @State private var offsetError: String?
    @State private var showingChannels = false

    private var capture: PacketCapture? {
        captures.first { $0.id == (selectedCapture ?? chart.captureID) } ?? captures.first
    }
    private var overview: CaptureJitterOverview? { chart.captureID == capture?.id ? chart.overview : nil }
    private var unplaced: Int {
        overview?.series.filter { row in !lanes.contains { $0.matches(chart.mapping.target(for: row)) } }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if let overview {
                alignment
                if overview.series.isEmpty {
                    Text("No RTP streams found in this capture.").foregroundStyle(.secondary)
                } else if let timeline = chart.timeline {
                    streamControls(overview)
                    if unplaced > 0 {
                        Text("Assign audio channels to place \(unplaced) RTP \(unplaced == 1 ? "stream" : "streams") on the spectrogram.")
                            .foregroundStyle(.secondary)
                    }
                    if !overview.timeDomain.overlaps(timeline.range(for: wholeWindow)) {
                        Text("Capture timestamps do not overlap this recording. Adjust the offset or align the first RTP packet to the playhead.")
                            .foregroundStyle(.orange)
                    }
                    if chart.visibleSeries.allSatisfy({ !$0.points.contains { $0.jitterMS != nil } }) {
                        Text("Jitter unavailable for these streams. A known RTP clock and at least two timed packets are required.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("This capture has no usable absolute timestamps to align with the recording.").foregroundStyle(.secondary)
                }
                if chart.partial { Text("Partial capture analysis. Open Captures for details.").foregroundStyle(.orange) }
            } else if let error = chart.error {
                Text(error).foregroundStyle(.orange)
            } else {
                ProgressView("Reading PCAP jitter…").controlSize(.small)
            }
        }
        .font(.caption)
        .task(id: capture?.id) {
            offsetError = nil
            guard let capture else { return }
            await chart.load(capture, store: model.captures.store)
            guard !Task.isCancelled else { return }
            offsetInput = String(format: "%.6f", chart.offset)
        }
    }

    private var header: some View {
        HStack {
            Text("PCAP jitter overlay").font(.headline)
            if captures.count > 1 {
                Picker("Capture", selection: Binding(get: { capture?.id }, set: { selectedCapture = $0 })) {
                    ForEach(captures) { Text($0.originalName).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 400)
            } else {
                Text(capture?.originalName ?? "").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("Good < 5").foregroundStyle(.green)
                Text("Medium 5–30").foregroundStyle(.orange)
                Text("Bad > 30 ms").foregroundStyle(.red)
            }.fixedSize()
        }
    }

    private var alignment: some View {
        HStack(spacing: 6) {
            Text("Offset (s)")
            TextField("Seconds", text: $offsetInput).frame(width: 90).onSubmit { applyInput() }
                .help("Added to packet timestamps. Positive values move jitter later; negative values move it earlier.")
            Button("Apply") { applyInput() }
            Menu("Align") {
                Button("Use Capture Timestamps") { setOffset(0) }
                Button("Align First RTP to Playhead") {
                    guard let overview, let origin = overview.origin?.date,
                          let first = overview.series.flatMap(\.points).map(\.seconds).min(), let now = model.player.currentDate else { return }
                    setOffset(now.timeIntervalSince(origin.addingTimeInterval(first)))
                }.disabled(model.player.currentDate == nil || overview?.series.flatMap(\.points).isEmpty != false)
                Divider()
                Button("Move Jitter 0.1 s Earlier") { setOffset(chart.offset - 0.1) }
                Button("Move Jitter 0.1 s Later") { setOffset(chart.offset + 0.1) }
                Button("Move Jitter 1 s Earlier") { setOffset(chart.offset - 1) }
                Button("Move Jitter 1 s Later") { setOffset(chart.offset + 1) }
            }.fixedSize()
            Text(offsetError ?? (chart.offset == 0 ? "Capture clock · verify against the audio" : "Adjusted capture clock · saved for this file"))
                .foregroundStyle(offsetError == nil ? Color.secondary : .orange).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func applyInput() {
        guard let seconds = Double(offsetInput.trimmingCharacters(in: .whitespaces)), seconds.isFinite, abs(seconds) < 1e12 else {
            offsetError = "Enter a finite offset in seconds."; return
        }
        setOffset(seconds)
    }

    private func setOffset(_ value: Double) {
        chart.setOffset(value)
        offsetInput = String(format: "%.6f", chart.offset); offsetError = nil
    }

    private func streamControls(_ overview: CaptureJitterOverview) -> some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $chart.selectedStream) {
                Text("All streams · up to 8 at once").tag(0)
                ForEach(overview.series) { row in
                    Text("RTP \(row.number) · \(CaptureAudioMapping.title(chart.mapping.target(for: row), lanes: lanes)) · \(row.key.label)").tag(row.number)
                }
            }.frame(maxWidth: 420)
            Button("Assign Audio Channels…") { showingChannels = true }
                .popover(isPresented: $showingChannels) { channelAssignments(overview) }
            Spacer(minLength: 0)
            if chart.selectedStream == 0, overview.pageCount > 1 {
                Button { chart.page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(chart.page == 0)
                Text("\(chart.page + 1)/\(overview.pageCount)")
                Button { chart.page += 1 } label: { Image(systemName: "chevron.right") }.disabled(chart.page + 1 >= overview.pageCount)
            }
        }
    }

    private func channelAssignments(_ overview: CaptureJitterOverview) -> some View {
        let directions = overview.series.reduce(into: [CaptureJitterOverview.Series]()) { rows, row in
            if !rows.contains(where: { CaptureAudioDirection($0) == CaptureAudioDirection(row) }) { rows.append(row) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Audio channels for captured directions").font(.headline)
            Text("Choose which audio each direction carries. Assignments apply to the listed streams and are saved for this capture. User and Agent apply to recordings with a known left/right layout.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(directions) { row in
                        let streams = overview.series.filter { CaptureAudioDirection($0) == CaptureAudioDirection(row) }
                        let selected = chart.mapping.target(for: row)
                        let available = CaptureAudioMapping.targets(lanes: lanes)
                        let targets = available.contains(selected) ? available : available + [selected]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(streams.map { "RTP \($0.number)" }.joined(separator: " · "))
                                .font(.caption.bold()).lineLimit(3)
                                .help(streams.map { "RTP \($0.number)" }.joined(separator: ", "))
                            Text("\(row.key.source) → \(row.key.destination)").font(.caption.monospaced()).textSelection(.enabled)
                            Text("\(row.call) · Interface \(row.key.interface)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Picker("Audio channel", selection: Binding(get: { chart.mapping.target(for: row) }, set: { chart.assign($0, to: row) })) {
                                ForEach(targets) { target in Text(CaptureAudioMapping.title(target, lanes: lanes)).tag(target) }
                            }
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 320)
            HStack { Spacer(); Button("Done") { showingChannels = false } }
        }.padding().frame(width: 520)
    }
}
