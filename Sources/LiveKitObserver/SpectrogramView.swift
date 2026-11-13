import SwiftUI

/// Mel spectrograms of each recording, one lane per channel, lined up on the session's wall clock.
struct SpectrogramView: View {
    let detail: SessionDetail
    let origin: Date?
    @Environment(AppModel.self) private var model
    @AppStorage("spectrogramLayout") private var layout = Layout.stacked
    /// Seconds on screen; 0 is the whole session. Set by the presets or by pinching.
    @AppStorage("spectrogramSpan") private var span: Double = 30
    /// The pinch in progress; the image is stretched live and rebuilt when the pinch ends.
    @GestureState private var pinch: CGFloat = 1
    static let shortestSpan: TimeInterval = 2

    enum Layout: String, CaseIterable, Identifiable {
        case stacked = "Stacked", sideBySide = "Side by side"
        var id: String { rawValue }
    }

    /// Seconds on screen; 0 is the whole session.
    enum Zoom: Int, CaseIterable, Identifiable {
        case ten = 10, thirty = 30, twoMinutes = 120, whole = 0
        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue) }
        var label: String { self == .whole ? "Whole session" : self == .twoMinutes ? "2 min" : "\(rawValue) s" }
    }

    var body: some View {
        VStack(spacing: 8) {
            controls
            if detail.loadingAudio && detail.sources.isEmpty {
                ProgressView("Downloading recordings…").frame(maxHeight: .infinity)
            } else if detail.sources.isEmpty {
                ContentUnavailableView("No recording", systemImage: "waveform.slash", description: Text(detail.audioError ?? "This session has no egress or LiveKit recording."))
            } else {
                let window = window
                let groups = ForEach(detail.sources) { source in
                    SourceLanes(detail: detail, source: source, window: window, origin: origin, pinch: pinch, anchor: anchor(in: window))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Group {
                    if layout == .stacked { VStack(spacing: 12) { groups } } else { HStack(alignment: .top, spacing: 12) { groups } }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { span = zoomed(by: $0.magnification) }
                )
            }
        }
        .padding([.horizontal, .bottom])
        .task(id: detail.sources.map(\.id)) { await model.analyze(detail) }
    }

    private var controls: some View {
        HStack {
            Picker("Layout", selection: $layout) { ForEach(Layout.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Zoom", selection: preset) { ForEach(Zoom.allCases) { Text($0.label).tag(Optional($0)) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Pinch on the spectrogram to zoom in or out")
            if preset.wrappedValue == nil {
                Text(Format.duration(span)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Mel scale \(Int(Spectrogram.minHz)) Hz–\(Int(Spectrogram.maxHz / 1000)) kHz · \(Int(Spectrogram.floorDB)) to \(Int(Spectrogram.ceilingDB)) dBFS · click to play from there")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The preset matching the current span, or nil after a pinch to an in-between zoom.
    private var preset: Binding<Zoom?> {
        Binding(get: { Zoom.allCases.first { $0.seconds == span } }, set: { if let zoom = $0 { span = zoom.seconds } })
    }

    /// The span after a pinch: spreading the fingers shows less time. Zooming out past the session shows all of it.
    private func zoomed(by magnification: CGFloat) -> Double {
        let length = wholeWindow.upperBound.timeIntervalSince(wholeWindow.lowerBound)
        let current = span == 0 ? length : min(span, length)
        let next = current / max(Double(magnification), 0.01)
        return next >= length * 0.98 ? 0 : max(Self.shortestSpan, next.rounded())
    }

    /// Where the pinch is centered: the playhead when it is on screen, otherwise the middle.
    private func anchor(in window: ClosedRange<Date>) -> CGFloat {
        let length = window.upperBound.timeIntervalSince(window.lowerBound)
        guard let now = model.player.currentDate, window.contains(now), length > 0 else { return 0.5 }
        return now.timeIntervalSince(window.lowerBound) / length
    }

    /// Every recording, start to end, on the session's wall clock.
    private var wholeWindow: ClosedRange<Date> {
        let fallback = origin ?? Date(timeIntervalSinceReferenceDate: 0)
        let spans = detail.sources.map { source -> ClosedRange<Date> in
            let start = detail.origin(of: source) ?? fallback
            let length = detail.spectrograms[source.kind]?.duration ?? (detail.activeSource == source.kind ? model.player.duration : 0)
            return start...start.addingTimeInterval(max(length, 1))
        }
        return (spans.map(\.lowerBound).min() ?? fallback)...(spans.map(\.upperBound).max() ?? fallback.addingTimeInterval(1))
    }

    /// The span of wall-clock time on screen: the whole session, or a window that follows the playhead.
    private var window: ClosedRange<Date> {
        let whole = wholeWindow
        guard span > 0, span < whole.upperBound.timeIntervalSince(whole.lowerBound) else { return whole }
        let center = model.player.currentDate ?? whole.lowerBound
        let start = center.addingTimeInterval(-span * 0.25)
        return start...start.addingTimeInterval(span)
    }
}

/// One recording: a title, a lane per channel, and a time axis.
private struct SourceLanes: View {
    let detail: SessionDetail
    let source: RecordingSource
    let window: ClosedRange<Date>
    let origin: Date?
    let pinch: CGFloat
    let anchor: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(source.title).font(.headline)
                Text(source.detail).font(.caption).foregroundStyle(.secondary)
                if detail.activeSource == source.kind { Tag(text: "Playing", symbol: "speaker.wave.2", color: .accentColor) }
                Spacer()
                if let offset = alignmentNote { Text(offset).font(.caption).foregroundStyle(.secondary) }
            }
            if let spectrogram = detail.spectrograms[source.kind] {
                ForEach(0..<spectrogram.channels.count, id: \.self) { channel in
                    Lane(spectrogram: spectrogram, channel: channel, start: start, window: window, pinch: pinch, anchor: anchor, label: source.channelName(channel, of: spectrogram.channels.count, identical: spectrogram.identicalChannels))
                        .frame(minHeight: 60, maxHeight: .infinity)
                }
                TimeAxis(window: window, origin: origin, transcript: detail.transcript).frame(height: 22)
            } else if let error = detail.spectrogramErrors[source.kind] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Spacer()
            } else {
                ProgressView("Analyzing…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var start: Date { detail.origin(of: source) ?? origin ?? window.lowerBound }

    /// How far this recording starts from the other one, which shows whether they line up.
    private var alignmentNote: String? {
        guard let other = detail.sources.first(where: { $0.kind != source.kind }),
              let mine = detail.origin(of: source), let theirs = detail.origin(of: other) else { return nil }
        let delta = mine.timeIntervalSince(theirs)
        guard abs(delta) >= 0.05 else { return nil }
        let aligned = detail.originCorrection[source.kind] != nil ? " (aligned by audio)" : ""
        return String(format: "starts %.2f s %@ the %@ recording%@", abs(delta), delta > 0 ? "after" : "before", other.title.lowercased(), aligned)
    }
}

/// One channel's spectrogram for the visible window, with frequency labels, the playhead, and click-to-seek.
private struct Lane: View {
    let spectrogram: Spectrogram
    let channel: Int
    /// The wall-clock time of the recording's first sample.
    let start: Date
    let window: ClosedRange<Date>
    let pinch: CGFloat
    let anchor: CGFloat
    let label: String
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    private struct Key: Hashable { let from: TimeInterval; let to: TimeInterval; let columns: Int }

    var body: some View {
        GeometryReader { geo in
            let key = Key(
                from: window.lowerBound.timeIntervalSince(start), to: window.upperBound.timeIntervalSince(start),
                columns: min(4000, max(1, Int(geo.size.width * scale)))
            )
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.black.opacity(0.85))
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .scaleEffect(x: pinch, y: 1, anchor: UnitPoint(x: anchor, y: 0.5))
                }
                frequencyLabels(size: geo.size)
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
                Playhead(window: window, width: geo.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                let span = window.upperBound.timeIntervalSince(window.lowerBound)
                let date = window.lowerBound.addingTimeInterval(span * location.x / max(geo.size.width, 1))
                if let t = model.player.offset(for: date) { model.player.seek(to: t) }
            }
            .task(id: key) { image = spectrogram.image(channel: channel, from: key.from, to: key.to, columns: key.columns) }
        }
    }

    /// Frequency marks along the right edge.
    private func frequencyLabels(size: CGSize) -> some View {
        let centers = Spectrogram.bandCenters
        return ForEach([250, 1000, 4000, 8000], id: \.self) { hz in
            if let band = centers.firstIndex(where: { $0 >= Float(hz) }) {
                Text(hz >= 1000 ? "\(hz / 1000)k" : "\(hz)")
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    .position(x: size.width - 12, y: size.height * (1 - (CGFloat(band) + 0.5) / CGFloat(Spectrogram.bands)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The playback position, drawn separately so the spectrogram image is not rebuilt on every tick.
private struct Playhead: View {
    let window: ClosedRange<Date>
    let width: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        if let now = model.player.currentDate, window.contains(now) {
            let span = window.upperBound.timeIntervalSince(window.lowerBound)
            Rectangle().fill(.white).frame(width: 1)
                .offset(x: width * now.timeIntervalSince(window.lowerBound) / span)
                .allowsHitTesting(false)
        }
    }
}

/// Time labels relative to the session, with a tick where each agent (blue) or user (green) turn begins.
private struct TimeAxis: View {
    let window: ClosedRange<Date>
    let origin: Date?
    let transcript: [TranscriptItem]

    var body: some View {
        Canvas { context, size in
            let span = window.upperBound.timeIntervalSince(window.lowerBound)
            guard span > 0 else { return }
            func x(_ date: Date) -> CGFloat { size.width * date.timeIntervalSince(window.lowerBound) / span }
            for item in transcript where item.role == .agent || item.role == .user {
                guard let start = item.start, window.contains(start) else { continue }
                context.fill(Path(CGRect(x: x(start) - 1, y: 0, width: 2, height: 6)), with: .color(item.role == .agent ? .blue : .green))
            }
            let base = origin ?? window.lowerBound
            let step = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800].map(Double.init).first { span / $0 <= 10 } ?? 3600
            var t = (window.lowerBound.timeIntervalSince(base) / step).rounded(.up) * step
            while t <= window.upperBound.timeIntervalSince(base) {
                let date = base.addingTimeInterval(t)
                context.fill(Path(CGRect(x: x(date), y: 6, width: 1, height: 4)), with: .color(.secondary))
                context.draw(Text(Format.offset(date, from: base)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: x(date), y: 16))
                t += step
            }
        }
    }
}
