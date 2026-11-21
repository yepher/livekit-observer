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
                                    Text(endpoint).font(.caption.monospaced()).lineLimit(2).frame(width: 180, height: 52).help(endpoint)
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
                VStack(alignment: .leading, spacing: 4) {
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
                        var line = Path(); line.move(to: CGPoint(x: x1, y: 42))
                        if source == destination {
                            line.addLine(to: CGPoint(x: x1 + 45, y: 42)); line.addLine(to: CGPoint(x: x1 + 45, y: 58)); line.addLine(to: CGPoint(x: x2, y: 58))
                        } else { line.addLine(to: CGPoint(x: x2, y: 42)) }
                        context.stroke(line, with: .color(event.color), style: StrokeStyle(lineWidth: 2, dash: event.media ? [6, 3] : []))
                        let direction: CGFloat = x2 > x1 ? 1 : -1
                        let y: CGFloat = source == destination ? 58 : 42
                        var arrow = Path(); arrow.move(to: CGPoint(x: x2 - direction * 9, y: y - 5)); arrow.addLine(to: CGPoint(x: x2, y: y)); arrow.addLine(to: CGPoint(x: x2 - direction * 9, y: y + 5))
                        context.stroke(arrow, with: .color(event.color), lineWidth: 2)
                    }
                    Text(event.label).font(.caption.weight(.medium)).foregroundStyle(event.color).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 3).background(.background, in: RoundedRectangle(cornerRadius: 4))
                        .frame(width: max(160, abs(x2 - x1) - 10)).offset(x: min(x1, x2) + (source == destination ? 0 : 5), y: 10)
                }.frame(width: CGFloat(endpoints.count) * 180, height: 74)
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

    private func qualityLegend(_ guide: JitterGuide) -> some View {
        HStack(spacing: 20) {
            Label("Good < \(guide.medium.formatted()) ms", systemImage: JitterQuality.good.symbol).foregroundStyle(JitterQuality.good.color)
            Label("Medium \(guide.medium.formatted())–\(guide.bad.formatted()) ms", systemImage: JitterQuality.medium.symbol).foregroundStyle(JitterQuality.medium.color)
            Label("Bad > \(guide.bad.formatted()) ms", systemImage: JitterQuality.bad.symbol).foregroundStyle(JitterQuality.bad.color)
        }.font(.caption)
    }

    private func chartDomain(_ samples: [Double?]) -> ClosedRange<Double> {
        let values = samples.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        // Fit every observed value, including spikes. A small minimum padding keeps
        // constant/zero series readable without magnifying floating-point noise.
        let span = high - low
        let padding = span > 0.001 ? max(span * 0.1, 0.001) : max(high * 0.01, 0.001)
        return max(0, low - padding)...(high + padding)
    }

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
