import ObserverCore
import Charts
import SwiftUI

private struct FlowEvent: Identifiable {
    var id: UInt64 { packet.id }
    let packet: InspectedPacket
    let label: String
    let color: Color
    var media = false
}

struct CaptureFlowView: View {
    let analysis: CaptureAnalysis
    let callID: String
    let inspect: (InspectedPacket) -> Void
    @State private var page = 0
    @State private var showMedia = true

    private var events: [FlowEvent] {
        var rows = analysis.messages.filter { callID.isEmpty || $0.callID == callID }.map { message in
            FlowEvent(packet: message.packet, label: message.label,
                      color: message.status.map { $0 >= 400 ? .red : ($0 >= 200 ? .green : .orange) } ?? .blue)
        }
        if showMedia {
            for stream in analysis.streams {
                if !callID.isEmpty {
                    let matches = analysis.messages.filter { message in
                        message.id < stream.firstPacket.id && message.media.contains { $0.endpoint == stream.key.destination && $0.payloads.contains(stream.key.payloadType) }
                    }
                    guard Set(matches.map(\.callID)) == [callID] else { continue }
                }
                rows.append(FlowEvent(packet: stream.firstPacket,
                                     label: "RTP starts · \(stream.clock?.codec ?? "PT \(stream.key.payloadType)") · SSRC \(String(stream.key.ssrc, radix: 16))",
                                     color: .purple, media: true))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }

    var body: some View {
        let events = events
        let rows = Array(events.dropFirst(page * 100).prefix(100))
        let endpoints = events.reduce(into: [String]()) { list, event in
            for endpoint in [event.packet.decoded.source, event.packet.decoded.destination] where !list.contains(endpoint) && list.count < 17 { list.append(endpoint) }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Signaling bounce diagram").font(.headline)
                Spacer()
                Toggle("Media starts", isOn: $showMedia).toggleStyle(.checkbox)
            }
            Text("Capture order · Times relative to the first event · Select an arrow to inspect its packet. Media matches use advertised SDP endpoints; they do not prove call ownership.")
                .font(.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                ContentUnavailableView("No visible signaling", systemImage: "arrow.left.arrow.right",
                    description: Text("No packet-local SIP messages were found for this selection. Encrypted or split messages cannot be reconstructed here. Use Jitter for captured RTP or Packets for raw evidence."))
            } else if endpoints.count > 16 {
                Text("More than 16 endpoints. Choose a call to focus the diagram; all events remain available below.").font(.caption).foregroundStyle(.orange)
                List(rows) { event in
                    Button { inspect(event.packet) } label: {
                        HStack { Text("#\(event.id)"); Text(event.label).foregroundStyle(event.color); Spacer(); Text("\(event.packet.decoded.source) → \(event.packet.decoded.destination)") }
                    }.buttonStyle(.plain)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(rows) { event in
                                BounceRow(event: event, endpoints: endpoints, origin: events.first?.packet.time) { inspect(event.packet) }
                            }
                        } header: {
                            HStack(spacing: 0) {
                                Text("Time / packet").frame(width: 125, alignment: .leading)
                                ForEach(endpoints, id: \.self) { endpoint in
                                    Text(endpoint).font(.caption.monospaced()).lineLimit(2).frame(width: 180, height: 32).help(endpoint)
                                }
                            }.font(.caption).background(.regularMaterial)
                        }
                    }.frame(width: 125 + CGFloat(endpoints.count) * 180)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text("\(events.count.formatted()) events · Requests blue · Responses green/orange/red · RTP purple").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Previous") { page -= 1 }.disabled(page == 0)
                Text("\(page + 1) / \(max(1, (events.count + 99) / 100))").font(.caption.monospacedDigit())
                Button("Next") { page += 1 }.disabled((page + 1) * 100 >= events.count)
            }
        }
        .onChange(of: callID) { _, _ in page = 0 }
        .onChange(of: showMedia) { _, _ in page = 0 }
    }
}

private struct BounceRow: View {
    let event: FlowEvent
    let endpoints: [String]
    let origin: PacketTime?
    let inspect: () -> Void

    var body: some View {
        let source = endpoints.firstIndex(of: event.packet.decoded.source) ?? 0
        let destination = endpoints.firstIndex(of: event.packet.decoded.destination) ?? 0
        let x1 = CGFloat(source) * 180 + 90, x2 = CGFloat(destination) * 180 + 90
        Button(action: inspect) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(origin.flatMap { start in event.packet.time?.seconds(since: start) }.map { String(format: "%+.3f s", $0) } ?? "Unknown time")
                    Text("Packet \(event.id)").foregroundStyle(.secondary)
                }.font(.caption.monospacedDigit()).frame(width: 125, alignment: .leading)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for index in endpoints.indices {
                            let x = CGFloat(index) * 180 + 90
                            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                        var line = Path(); line.move(to: CGPoint(x: x1, y: 25))
                        if source == destination {
                            line.addLine(to: CGPoint(x: x1 + 45, y: 25)); line.addLine(to: CGPoint(x: x1 + 45, y: 35)); line.addLine(to: CGPoint(x: x2, y: 35))
                        } else { line.addLine(to: CGPoint(x: x2, y: 25)) }
                        context.stroke(line, with: .color(event.color), style: StrokeStyle(lineWidth: 2, dash: event.media ? [6, 3] : []))
                        let direction: CGFloat = x2 > x1 ? 1 : -1
                        let y: CGFloat = source == destination ? 35 : 25
                        var arrow = Path(); arrow.move(to: CGPoint(x: x2 - direction * 9, y: y - 5)); arrow.addLine(to: CGPoint(x: x2, y: y)); arrow.addLine(to: CGPoint(x: x2 - direction * 9, y: y + 5))
                        context.stroke(arrow, with: .color(event.color), lineWidth: 2)
                    }
                    Text(event.label).font(.caption.weight(.medium)).foregroundStyle(event.color).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.background, in: RoundedRectangle(cornerRadius: 4))
                        .frame(width: max(160, abs(x2 - x1) - 10)).offset(x: min(x1, x2) + (source == destination ? 0 : 5), y: 2)
                }.frame(width: CGFloat(endpoints.count) * 180, height: 40)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(event.packet.decoded.source) → \(event.packet.decoded.destination) · \(event.label) · \(event.packet.time?.text ?? "Unknown time")")
        .accessibilityLabel("Packet \(event.id), \(event.label), from \(event.packet.decoded.source) to \(event.packet.decoded.destination)")
    }
}

struct CaptureJitterView: View {
    @Bindable var model: CaptureAnalysisModel
    let inspect: (InspectedPacket) -> Void
    @State private var clockInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Jitter view", selection: $model.jitterOverviewVisible) {
                Text("All calls").tag(true)
                Text("One stream").tag(false)
            }.pickerStyle(.segmented).frame(maxWidth: 340)
            if model.jitterOverviewVisible, let overview = model.jitterOverview {
                CaptureJitterOverviewView(overview: overview) { key in
                    model.selectedStream = key
                    model.jitterOverviewVisible = false
                }
            } else {
                streamDetail
            }
        }
    }

    private var streamDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let streams = model.result?.streams, !streams.isEmpty {
                Picker("RTP stream", selection: $model.selectedStream) {
                    ForEach(streams) { stream in Text(stream.key.label).tag(Optional(stream.key)) }
                }
                if let stream = model.stream {
                    HStack {
                        Text("\(stream.count.formatted()) packets · \(stream.clock?.codec ?? "Unknown codec") · \(stream.clock.map { "\($0.rate) Hz · \($0.source)" } ?? "Unknown RTP clock")").font(.caption)
                        Spacer()
                        TextField("Clock Hz (blank = auto)", text: $clockInput).frame(width: 180)
                        Button("Apply Clock") { model.applyClock(clockInput) }.disabled(model.running)
                    }
                    Text("Measurements apply to this captured direction and SSRC. Dynamic payload types need matching SDP or a clock rate you supply. Encrypted payload contents are not inspected.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                timingMetric("Peak jitter", stream.peakJitterMS, guide: .peak)
                                timingMetric("Mean jitter", stream.meanJitterMS, guide: .mean)
                                timingMetric("Longest interval", stream.peakGapMS, guide: .interval)
                                metric("Sequence gaps", stream.sequence.gaps.map(String.init) ?? "Unknown")
                                metric("Reordered / duplicate", "\(stream.sequence.reordered) / \(stream.sequence.duplicates)")
                            }
                            Text("Color ranges follow Holmes as a review guide, not a guarantee of audible quality. Expert review thresholds below are independently adjustable.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Jitter over time").font(.headline)
                            qualityLegend(.peak)
                            if stream.peakJitterMS == nil {
                                Text("Jitter is unavailable until two usable packets share a known RTP clock. Supply the clock above if SDP is missing.").foregroundStyle(.secondary)
                            } else {
                                let domain = chartDomain(stream.chart.map(\.jitterMS))
                                Chart {
                                    qualityBands(.peak, domain: domain)
                                    ForEach(stream.chart) { bucket in
                                        if let jitter = bucket.jitterMS {
                                            LineMark(x: .value("Seconds", bucket.seconds), y: .value("Jitter (ms)", jitter)).foregroundStyle(.blue)
                                        }
                                    }
                                    if model.jitterThreshold.isFinite, model.jitterThreshold > 0, domain.contains(model.jitterThreshold) {
                                        RuleMark(y: .value("Expert review threshold", model.jitterThreshold))
                                            .foregroundStyle(.secondary.opacity(0.6)).lineStyle(StrokeStyle(dash: [4]))
                                    }
                                }.chartYScale(domain: domain)
                                    .chartXAxisLabel("Seconds since this stream began").chartYAxisLabel("Jitter (ms)").frame(height: 180)
                            }
                            Text("Packet arrival intervals").font(.headline)
                            qualityLegend(.interval)
                            if stream.peakGapMS == nil {
                                Text("Arrival intervals are unavailable until two packets have usable capture timestamps.").foregroundStyle(.secondary)
                            } else {
                                let domain = chartDomain(stream.chart.map(\.gapMS))
                                Chart {
                                    qualityBands(.interval, domain: domain)
                                    ForEach(stream.chart) { bucket in
                                        if let gap = bucket.gapMS {
                                            LineMark(x: .value("Seconds", bucket.seconds), y: .value("Arrival interval (ms)", gap)).foregroundStyle(.purple)
                                        }
                                    }
                                }.chartYScale(domain: domain)
                                    .chartXAxisLabel("Seconds since this stream began").chartYAxisLabel("Interval (ms)").frame(height: 150)
                            }
                            Text("Axes automatically fit the selected stream’s data; color bands keep their fixed thresholds. Charts retain peak values in at most 513 buckets. Summary metrics use every analyzed packet. Sequence gaps are capture observations, not a receiver loss percentage.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if let packet = stream.peakJitterPacket { Button("Inspect Peak Jitter · #\(packet.id)") { inspect(packet) } }
                                if let packet = stream.peakGapPacket { Button("Inspect Longest Interval · #\(packet.id)") { inspect(packet) } }
                            }
                            if stream.unknownClockPackets > 0 || stream.timingResets > 0 || stream.untimedPackets > 0 || stream.clockChanges > 0 {
                                Label("Timing coverage: \(stream.unknownClockPackets) packets without a known clock, \(stream.untimedPackets) without capture time, \(stream.timingResets) timing resets, \(stream.clockChanges) clock changes.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Text("Expert review thresholds (ms):").font(.caption)
                                TextField("Jitter", value: $model.jitterThreshold, format: .number).frame(width: 75)
                                Text("jitter").font(.caption)
                                TextField("Arrival interval", value: $model.gapThreshold, format: .number).frame(width: 75)
                                Text("arrival interval").font(.caption)
                                Button("Update Findings") { model.refreshFindings() }
                            }
                        }.padding(8)
                    }
                }
            } else {
                ContentUnavailableView("No RTP streams found", systemImage: "waveform.path",
                    description: Text("The capture may contain only signaling, unsupported framing or media that is not recognizable as RTP."))
            }
        }.onChange(of: model.selectedStream) { _, _ in clockInput = "" }
    }

    private func timingMetric(_ title: String, _ value: Double?, guide: JitterGuide) -> some View {
        let quality = guide.quality(value)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.2f ms", $0) : nil } ?? "Unknown")
                .font(.headline.monospacedDigit()).foregroundStyle(quality.color)
            Label(quality.rawValue, systemImage: quality.symbol).font(.caption.weight(.semibold)).foregroundStyle(quality.color)
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(quality.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(quality.color.opacity(0.3)))
        .help(guide.explanation)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline.monospacedDigit()) }
            .padding(10).frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private func qualityLegend(_ guide: JitterGuide) -> some View {
    HStack(spacing: 20) {
        Label("Good < \(guide.medium.formatted()) ms", systemImage: JitterQuality.good.symbol).foregroundStyle(JitterQuality.good.color)
        Label("Medium \(guide.medium.formatted())–\(guide.bad.formatted()) ms", systemImage: JitterQuality.medium.symbol).foregroundStyle(JitterQuality.medium.color)
        Label("Bad > \(guide.bad.formatted()) ms", systemImage: JitterQuality.bad.symbol).foregroundStyle(JitterQuality.bad.color)
    }.font(.caption)
}

private func chartDomain(_ samples: [Double?]) -> ClosedRange<Double> { CaptureJitterOverview.valueDomain(samples) }

@ChartContentBuilder private func qualityBands(_ guide: JitterGuide, domain: ClosedRange<Double>) -> some ChartContent {
    if domain.lowerBound < guide.medium {
        RectangleMark(yStart: .value("Range start", domain.lowerBound), yEnd: .value("Range end", min(domain.upperBound, guide.medium)))
            .foregroundStyle(JitterQuality.good.color.opacity(0.12)).accessibilityHidden(true)
    }
    if domain.upperBound > guide.medium, domain.lowerBound < guide.bad {
        RectangleMark(yStart: .value("Range start", max(domain.lowerBound, guide.medium)), yEnd: .value("Range end", min(domain.upperBound, guide.bad)))
            .foregroundStyle(JitterQuality.medium.color.opacity(0.12)).accessibilityHidden(true)
    }
    if domain.upperBound > guide.bad {
        RectangleMark(yStart: .value("Range start", max(domain.lowerBound, guide.bad)), yEnd: .value("Range end", domain.upperBound))
            .foregroundStyle(JitterQuality.bad.color.opacity(0.10)).accessibilityHidden(true)
    }
}

/// All calls share the capture's timestamp axis; only a bounded page is drawn at once.
private struct CaptureJitterOverviewView: View {
    let overview: CaptureJitterOverview
    let select: (RTPStreamKey) -> Void
    @State private var page = 0
    @State private var measure = Measure.jitter

    private enum Measure: String, CaseIterable {
        case jitter = "Jitter", interval = "Arrival intervals"
        var guide: JitterGuide { self == .jitter ? .peak : .interval }
        var axisLabel: String { self == .jitter ? "Jitter (ms)" : "Interval (ms)" }
        func value(_ point: JitterBucket) -> Double? { self == .jitter ? point.jitterMS : point.gapMS }
        func peak(_ series: CaptureJitterOverview.Series) -> Double? { self == .jitter ? series.peakJitterMS : series.peakGapMS }
    }

    private var visible: [CaptureJitterOverview.Series] { overview.page(page) }
    private let colors: [Color] = [.blue, .purple, .cyan, .pink, .indigo, .brown, .teal, .primary]
    private func color(_ series: CaptureJitterOverview.Series) -> Color { colors[(series.number - 1) % colors.count] }

    var body: some View {
        if overview.series.isEmpty {
            ContentUnavailableView("No RTP streams found", systemImage: "waveform.path",
                description: Text("The capture may contain only signaling or unrecognizable media."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Time-aligned media").font(.headline)
                    Spacer()
                    Picker("Measure", selection: $measure) {
                        ForEach(Measure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 270)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        qualityLegend(measure.guide)
                        plot
                        Text("Line colors identify streams; background bands show quality ranges. Select a stream below for its clock settings, metrics and packet evidence.")
                            .font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                            ForEach(visible) { series in streamButton(series) }
                        }
                        Text("All streams use capture timestamps, including their start offsets. Interface clocks are assumed synchronized. Each overview line retains peaks in at most \(CaptureJitterOverview.maximumPoints) time buckets; open a stream for more detail. SDP matches are hints, not proof of call ownership.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack {
                    Text("Showing streams \(visible.first?.number ?? 0)–\(visible.last?.number ?? 0) of \(overview.series.count) · Up to \(CaptureJitterOverview.pageSize) at once")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Previous") { page -= 1 }.disabled(page <= 0)
                    Text("\(min(page + 1, overview.pageCount)) / \(overview.pageCount)").font(.caption.monospacedDigit())
                    Button("Next") { page += 1 }.disabled(page + 1 >= overview.pageCount)
                }
            }
            .onChange(of: overview.pageCount) { _, count in page = min(page, count - 1) }
        }
    }

    private var plot: some View {
        let domain = chartDomain(visible.flatMap { $0.points.map(measure.value) })
        let measured = visible.filter { $0.points.contains { measure.value($0) != nil } }
        return VStack(alignment: .leading, spacing: 4) {
            Chart {
                qualityBands(measure.guide, domain: domain)
                ForEach(visible) { series in
                    let points = series.points.filter { measure.value($0) != nil }
                    ForEach(points) { point in
                        if let value = measure.value(point) {
                            if points.count == 1 {
                                PointMark(x: .value("Capture seconds", point.seconds), y: .value(measure.axisLabel, value))
                                    .foregroundStyle(by: .value("Stream", series.label))
                            } else {
                                LineMark(x: .value("Capture seconds", point.seconds), y: .value(measure.axisLabel, value))
                                    .foregroundStyle(by: .value("Stream", series.label))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                    }
                }
            }
            .chartXScale(domain: overview.timeDomain)
            .chartYScale(domain: domain)
            .chartForegroundStyleScale(domain: visible.map(\.label), range: visible.map(color))
            .chartLegend(.hidden)
            .chartXAxisLabel("Seconds from first captured timestamp")
            .chartYAxisLabel(measure.axisLabel)
            .frame(height: 250)
            .overlay {
                if measured.isEmpty {
                    Text(measure == .jitter ? "No jitter estimates on this page. Open a stream to check its RTP clock, or view arrival intervals." : "No timed arrival intervals on this page.")
                        .font(.callout).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if measured.count < visible.count {
                Text("\(visible.count - measured.count) streams have no plottable \(measure.rawValue.lowercased()) on the shared timeline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func streamButton(_ series: CaptureJitterOverview.Series) -> some View {
        Button { select(series.key) } label: {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(color(series)).frame(width: 8, height: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(series.label) · \(series.codec)").fontWeight(.semibold)
                        Spacer()
                        Text(measure.peak(series).map { String(format: "Peak %.2f ms", $0) } ?? "Unknown")
                            .foregroundStyle(measure.guide.quality(measure.peak(series)).color)
                    }
                    Text("\(series.key.source) → \(series.key.destination)").lineLimit(1).truncationMode(.middle)
                    Text("SSRC \(String(series.key.ssrc, radix: 16)) · PT \(series.key.payloadType) · IF \(series.key.interface) · \(series.timed ? series.call : "No capture time")")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.font(.caption)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("\(series.key.label)\n\(series.call)\nOpen stream details")
    }
}

private enum JitterQuality: String {
    case good = "Good", medium = "Medium", bad = "Bad", unknown = "Unknown"
    var color: Color {
        switch self {
        case .good: .green
        case .medium: .orange
        case .bad: .red
        case .unknown: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .medium: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Match Holmes' maxJitterSeverity, meanJitterSeverity and maxDeltaSeverity.
/// The upper boundary is inclusive in Medium, and unknown never means Good.
private struct JitterGuide {
    let medium: Double
    let bad: Double
    static let peak = JitterGuide(medium: 5, bad: 30)
    static let mean = JitterGuide(medium: 2, bad: 10)
    static let interval = JitterGuide(medium: 50, bad: 100)

    func quality(_ value: Double?) -> JitterQuality {
        guard let value, value.isFinite, value >= 0 else { return .unknown }
        if value > bad { return .bad }
        return value >= medium ? .medium : .good
    }
    var explanation: String { "Holmes guide: Good < \(medium.formatted()) ms; Medium \(medium.formatted())–\(bad.formatted()) ms; Bad > \(bad.formatted()) ms. Unknown measurements are not graded." }
}

struct CaptureFindingsView: View {
    let findings: [CaptureFinding]
    let complete: Bool
    let inspect: (InspectedPacket) -> Void
    let jitter: (RTPStreamKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Expert analysis").font(.headline)
            Text("Local evidence-based checks. Media findings cover all captured streams; SIP findings follow the call filter. Missing evidence and possible causes are distinguished from observed responses.")
                .font(.caption).foregroundStyle(.secondary)
            if findings.isEmpty {
                ContentUnavailableView("No common issues flagged", systemImage: "checklist",
                    description: Text(complete ? "The implemented rules did not flag this evidence. This does not establish end-to-end call quality; encrypted or unreassembled messages are outside these checks." : "Analysis coverage is incomplete. No finding is not a clean bill of health."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(finding.title, systemImage: finding.severity == .information ? "info.circle" : "exclamationmark.triangle")
                                    .font(.headline).foregroundStyle(finding.severity == .error ? Color.red : finding.severity == .warning ? .orange : .blue)
                                Text(finding.observation).font(.callout.weight(.medium))
                                Text(finding.explanation).font(.callout)
                                Text("Next check: " + finding.nextCheck).font(.callout).foregroundStyle(.secondary)
                                if let call = finding.callID { Text("Call-ID: " + call).font(.caption.monospaced()).lineLimit(2) }
                                if let stream = finding.stream { Text(stream.label).font(.caption.monospaced()).lineLimit(2) }
                                HStack {
                                    Button("Inspect Packet #\(finding.evidence.id)") { inspect(finding.evidence) }
                                    if let stream = finding.stream { Button("Open Jitter") { jitter(stream) } }
                                    Spacer()
                                    Text(finding.rule).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }.textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(4)
                }
            }
        }
    }
}
