import ObserverCore
import AppKit
import SwiftUI

/// Mel spectrograms of each recording, one lane per channel, lined up on the session's wall clock.
struct SpectrogramView: View {
    let detail: SessionDetail
    let origin: Date?
    @Environment(AppModel.self) private var model
    /// Seconds on screen; 0 is the whole session. Set by pinching.
    @AppStorage("spectrogramSpan") private var span: Double = 30
    /// The pinch in progress; the image is stretched live and rebuilt when the pinch ends.
    @GestureState private var pinch = Pinch()
    /// The left edge of the zoomed view once it has been placed; nil puts the playhead a quarter of the way in.
    @State private var scrollStart: Date?
    /// Whether the pointer is over the lanes, so horizontal scrolling there moves the view.
    @State private var hovering = false
    @State private var lanesWidth: CGFloat = 0
    @State private var scrollMonitor: Any?
    static let shortestSpan: TimeInterval = 2
    /// Space between recordings.
    private static let gap: CGFloat = 12

    /// How far the fingers have spread, and where they are across a lane (0 is the left edge, 1 the right).
    private struct Pinch {
        var scale: CGFloat = 1
        var anchor: CGFloat = 0.5
    }

    var body: some View {
        VStack(spacing: 8) {
            controls
            egressStatus
            if detail.loadingAudio && detail.sources.isEmpty {
                ProgressView("Downloading recordings…").frame(maxHeight: .infinity)
            } else if detail.sources.isEmpty {
                ContentUnavailableView("No recording loaded", systemImage: "waveform.slash", description: Text(model.storageConfigured && detail.row.recording == nil ? "Egress audio appears here once its recording is found in storage." : detail.audioError ?? "This session has no available LiveKit recording."))
            } else {
                let window = window
                let groups = ForEach(detail.sources) { source in
                    SourceLanes(detail: detail, source: source, window: window, origin: origin, pinch: pinch.scale, anchor: pinch.anchor, canScroll: window != wholeWindow, scrollStart: $scrollStart)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Group {
                    VStack(spacing: Self.gap) { groups }
                }
                .onHover { hovering = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lanesWidth = $0 }
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in
                            state = Pinch(scale: value.magnification, anchor: laneFraction(at: value.startAnchor.x * lanesWidth))
                        }
                        .onEnded { value in
                            // Keep the moment under the fingers where it was.
                            let old = window, fraction = laneFraction(at: value.startAnchor.x * lanesWidth)
                            let pivot = old.lowerBound.addingTimeInterval(old.upperBound.timeIntervalSince(old.lowerBound) * fraction)
                            span = zoomed(by: value.magnification)
                            scrollStart = span > 0 ? pivot.addingTimeInterval(-span * fraction) : nil
                        }
                )
            }
        }
        .padding([.horizontal, .bottom])
        .task(id: detail.audioRevision) { await model.analyze(detail) }
        .onAppear {
            if model.storageConfigured, detail.row.recording == nil { model.scanRecordings(automatic: true) }
        }
        .onChange(of: model.player.currentTime) { old, new in follow(from: old, to: new) }
        .onChange(of: detail.row.id) { scrollStart = nil }
        .onAppear { startScrollMonitor() }
        .onDisappear { stopScrollMonitor() }
    }

    @ViewBuilder private var egressStatus: some View {
        if !detail.sources.contains(where: { $0.kind == .egress }), model.storageConfigured {
            HStack(spacing: 8) {
                if model.scanningRecordings {
                    ProgressView().controlSize(.small)
                    Text("Looking for egress recordings…")
                } else if let error = detail.egressError ?? model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Try Again") {
                        if detail.row.recording != nil { model.reloadAudio() }
                        else { model.scanRecordings() }
                    }
                } else if detail.row.recording == nil {
                    Text(model.recordingScan?.complete == true ? "No egress recording found for this session in the last storage scan." : "Egress recordings are still being indexed.")
                    Spacer()
                    Button(model.recordingScan?.complete == true ? "Check Storage Again" : "Continue Finding Recordings") { model.scanRecordings() }
                } else if detail.loadingAudio {
                    ProgressView().controlSize(.small)
                    Text("Loading egress audio…")
                }
            }
            .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Two-finger swipes left and right (or a mouse's horizontal wheel) scroll a zoomed view, like dragging does.
    /// SwiftUI has no horizontal scroll gesture on macOS, so this watches the app's scroll events while the pointer
    /// is over the lanes, and takes only mostly-horizontal ones, leaving vertical scrolling alone.
    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            scroll(by: event) ? nil : event
        }
    }

    private func stopScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// Moves the view for a horizontal scroll event over the lanes; returns whether it did.
    private func scroll(by event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX
        guard hovering, dx != 0, abs(dx) > abs(event.scrollingDeltaY) else { return false }
        let view = window
        guard view != wholeWindow, lanesWidth > 0 else { return false }
        let secondsPerPoint = view.upperBound.timeIntervalSince(view.lowerBound) / max(laneWidth, 1)
        // A trackpad reports points; a mouse wheel reports lines.
        let points = event.hasPreciseScrollingDeltas ? dx : dx * 10
        // The content follows the fingers, as the system's scroll direction setting has already applied.
        scrollStart = view.lowerBound.addingTimeInterval(-points * secondsPerPoint)
        model.skimmer.end()
        return true
    }

    /// The scale legend and how much time is on screen.
    private var controls: some View {
        HStack(alignment: .firstTextBaseline) {
            legend
            Text(window == wholeWindow ? "Whole session" : Format.duration(window.upperBound.timeIntervalSince(window.lowerBound)) + " shown")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var legend: some View {
        Text("Mel scale \(Int(Spectrogram.minHz)) Hz–\(Int(Spectrogram.maxHz / 1000)) kHz · \(Int(Spectrogram.floorDB)) to \(Int(Spectrogram.ceilingDB)) dBFS · pinch to zoom · drag or swipe to scroll · hover to scrub · click to move the playhead · right-click to flag · M mutes a track, S solos it")
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
    }

    /// The span after a pinch: spreading the fingers shows less time. Zooming out past the session shows all of it.
    private func zoomed(by magnification: CGFloat) -> Double {
        let length = wholeWindow.upperBound.timeIntervalSince(wholeWindow.lowerBound)
        let current = span == 0 ? length : min(span, length)
        let next = current / max(Double(magnification), 0.01)
        return next >= length * 0.98 ? 0 : max(Self.shortestSpan, next.rounded())
    }

    /// Lanes are stacked, each the full width.
    private var laneWidth: CGFloat { lanesWidth }

    /// How far across the lanes a point `x` from their left edge is, from 0 to 1.
    private func laneFraction(at x: CGFloat) -> CGFloat {
        guard lanesWidth > 0 else { return 0.5 }
        return min(max(x / lanesWidth, 0), 1)
    }

    /// Every recording, start to end, on the session's wall clock.
    private var wholeWindow: ClosedRange<Date> {
        let fallback = origin ?? Date(timeIntervalSinceReferenceDate: 0)
        let spans = detail.sources.map { source -> ClosedRange<Date> in
            let start = detail.origin(of: source) ?? fallback
            let length = detail.spectrograms[source.kind]?.duration ?? 0
            return start...start.addingTimeInterval(max(length, 1))
        }
        return (spans.map(\.lowerBound).min() ?? fallback)...(spans.map(\.upperBound).max() ?? fallback.addingTimeInterval(1))
    }

    /// The span of wall-clock time on screen: the whole session, or a window that follows the playhead.
    private var window: ClosedRange<Date> {
        let whole = wholeWindow
        guard span > 0, span < whole.upperBound.timeIntervalSince(whole.lowerBound) else { return whole }
        // Where the view was placed, or with the playhead a quarter of the way in; never past either end.
        let wanted = scrollStart ?? (model.player.currentDate ?? whole.lowerBound).addingTimeInterval(-span * 0.25)
        let latest = whole.upperBound.addingTimeInterval(-span)
        let start = min(max(wanted, whole.lowerBound), latest)
        return start...start.addingTimeInterval(span)
    }

    /// Clicking only moves the playhead. The view turns the page when playback runs off its right edge,
    /// and jumps when the playhead is moved somewhere off screen (from the transcript, say).
    private func follow(from old: TimeInterval, to new: TimeInterval) {
        guard span > 0, let origin = model.player.origin else { return }
        if scrollStart == nil { scrollStart = window.lowerBound }
        let view = window, now = origin.addingTimeInterval(new), before = origin.addingTimeInterval(old)
        let ranOffRight = model.player.isPlaying && before < view.upperBound && now >= view.upperBound
        let jumpedAway = !model.player.isPlaying && !view.contains(now)
        if ranOffRight || jumpedAway { scrollStart = now.addingTimeInterval(-span * (ranOffRight ? 0.05 : 0.25)) }
    }
}

/// Mute and solo for one lane's track, as in a mixing desk. Soloing any track silences the ones not soloed.
private struct TrackButtons: View {
    let track: TrackID
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 2) {
            button("M", on: player.muted.contains(track), color: .orange, help: "Mute this track") { player.toggleMute(track) }
            button("S", on: player.soloed.contains(track), color: .yellow, help: "Solo this track: hear only soloed tracks") { player.toggleSolo(track) }
        }
    }

    private func button(_ title: String, on: Bool, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(on ? .black : .white)
                .frame(width: 18, height: 16)
                .background(on ? color : .black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
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
    let canScroll: Bool
    @Binding var scrollStart: Date?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(source.title).font(.headline).fixedSize()
                Text(source.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1).help(source.detail)
                Spacer(minLength: 8)
                if let offset = alignmentNote {
                    Text(offset).font(.caption).foregroundStyle(detail.alignment == .noMatch ? .orange : .secondary)
                        .lineLimit(1).truncationMode(.tail).help(offset)
                }
                if source.kind == .egress, detail.sources.count > 1 { alignMenu }
            }
            if let spectrogram = detail.spectrograms[source.kind] {
                ForEach(0..<spectrogram.channels.count, id: \.self) { channel in
                    Lane(detail: detail, spectrogram: spectrogram, channel: channel, track: TrackID(kind: source.kind, channel: channel),
                         file: detail.channelFiles[source.kind].flatMap { $0.indices.contains(channel) ? $0[channel] : nil } ?? source.file, start: start, window: window, pinch: pinch, anchor: anchor, canScroll: canScroll, scrollStart: $scrollStart, label: source.channelName(channel, of: spectrogram.channels.count, identical: spectrogram.identicalChannels),
                         ttsStatic: channel == source.agentChannel(channels: spectrogram.channels.count, identical: spectrogram.identicalChannels) ? detail.ttsStatic[source.kind] ?? [] : [])
                        .frame(minHeight: 60, maxHeight: .infinity)
                }
                TimeAxis(window: window, origin: origin, transcript: detail.transcript, flags: detail.flags, ttsStatic: detail.ttsStatic[source.kind] ?? []).frame(height: 22)
            } else if let error = detail.spectrogramErrors[source.kind] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Spacer()
            } else {
                ProgressView("Analyzing…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var start: Date { detail.origin(of: source) ?? origin ?? window.lowerBound }

    /// How far this recording starts from the other one, and how that was worked out.
    private var alignmentNote: String? {
        guard let other = detail.sources.first(where: { $0.kind != source.kind }),
              let mine = detail.origin(of: source), let theirs = detail.origin(of: other) else { return nil }
        let delta = mine.timeIntervalSince(theirs)
        let how: String = switch detail.alignment {
        case .byAudio: "matched by audio"
        case .byHand: "adjusted by hand"
        case .noMatch: "audio did not match; using reported start times"
        case .reported: "reported start times"
        }
        guard abs(delta) >= 0.05 else { return "lined up · \(how)" }
        return String(format: "starts %.2f s %@ the %@ recording · %@", abs(delta), delta > 0 ? "after" : "before", other.title.lowercased(), how)
    }

    /// Fixes for when matching by audio picks the wrong spot.
    private var alignMenu: some View {
        Menu {
            Button("Match by Audio Again") { Task { await model.alignByAudio(detail) } }
            Button("Use Reported Start Times") { model.resetAlignment(detail) }
            Divider()
            Button("Move Egress 1 s Earlier") { model.nudgeEgress(detail, by: -1) }
            Button("Move Egress 0.1 s Earlier") { model.nudgeEgress(detail, by: -0.1) }
            Button("Move Egress 0.1 s Later") { model.nudgeEgress(detail, by: 0.1) }
            Button("Move Egress 1 s Later") { model.nudgeEgress(detail, by: 1) }
        } label: {
            Image(systemName: "arrow.left.and.right")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Line the egress recording up with LiveKit's")
    }

}

/// One channel's spectrogram for the visible window, with frequency labels, the playhead, and click-to-seek.
private struct Lane: View {
    let detail: SessionDetail
    let spectrogram: Spectrogram
    let channel: Int
    /// The player's track for this channel, for mute and solo.
    let track: TrackID
    /// The channel's audio (or the whole recording until it is split), for skimming.
    let file: URL
    /// The wall-clock time of the recording's first sample.
    let start: Date
    let window: ClosedRange<Date>
    let pinch: CGFloat
    let anchor: CGFloat
    /// Whether dragging scrolls the view (zoomed in) rather than scrubbing the playhead (whole session).
    let canScroll: Bool
    @Binding var scrollStart: Date?
    let label: String
    /// Possible static on this channel, outlined in red.
    var ttsStatic: [TTSStatic] = []
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @State private var rendered: (key: Key, image: CGImage)?
    /// When a drag began: the view's left edge, or the playhead and whether it was playing.
    @State private var drag: (edge: Date, time: TimeInterval, wasPlaying: Bool)?
    /// Where the pointer is, for the context menu, which SwiftUI gives no location.
    @State private var pointer: Date?

    private struct Key: Hashable {
        let spectrogramID: UUID
        let channel: Int
        let from: TimeInterval
        let to: TimeInterval
        let columns: Int
    }

    var body: some View {
        GeometryReader { geo in
            let key = Key(
                spectrogramID: spectrogram.id, channel: channel,
                from: window.lowerBound.timeIntervalSince(start), to: window.upperBound.timeIntervalSince(start),
                columns: min(4000, max(1, Int(geo.size.width * scale)))
            )
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.black.opacity(0.85))
                if let rendered, rendered.key.spectrogramID == spectrogram.id, rendered.key.channel == channel {
                    Image(decorative: rendered.image, scale: 1).resizable().interpolation(.medium)
                        // Keep the last bitmap lined up with flags and the playhead while its
                        // replacement is rendering during a pan, zoom or alignment change.
                        .scaleEffect(x: (rendered.key.to - rendered.key.from) / (key.to - key.from), y: 1, anchor: .leading)
                        .offset(x: (rendered.key.from - key.from) / (key.to - key.from) * geo.size.width)
                        .scaleEffect(x: pinch, y: 1, anchor: UnitPoint(x: anchor, y: 0.5))
                        .opacity(model.player.isLoaded && !model.player.isAudible(track) ? 0.45 : 1)
                }
                FlagBands(flags: detail.flags, window: window, width: geo.size.width)
                SuggestedBands(ranges: detail.suggestions, window: window, width: geo.size.width)
                StaticBoxes(items: ttsStatic, window: window, width: geo.size.width)
                frequencyLabels(size: geo.size)
                HStack(spacing: 4) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    if model.player.isLoaded { TrackButtons(track: track) }
                }
                .padding(4)
                Playhead(window: window, width: geo.size.width)
                Skimline(window: window, width: geo.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .pointerStyle(drag != nil ? .grabActive : canScroll ? .grabIdle : nil)
            .onTapGesture { location in
                if let t = model.player.offset(for: date(at: location.x, width: geo.size.width)) { model.player.seek(to: t) }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let player = model.player
                        if drag == nil {
                            drag = (window.lowerBound, player.currentTime, player.isPlaying)
                            if !canScroll { player.pause() }
                            model.skimmer.end()
                        }
                        guard let drag else { return }
                        if canScroll {
                            // Grab and move the spectrogram, leaving the playhead where it is.
                            let perPoint = window.upperBound.timeIntervalSince(window.lowerBound) / max(geo.size.width, 1)
                            scrollStart = drag.edge.addingTimeInterval(-value.translation.width * perPoint)
                        } else if let t = player.offset(for: date(at: value.location.x, width: geo.size.width)) {
                            // The whole session is on screen, so dragging scrubs the playhead instead.
                            player.seek(to: t)
                        }
                    }
                    .onEnded { _ in
                        if !canScroll, drag?.wasPlaying == true { model.player.play() }
                        drag = nil
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location) where drag == nil:
                    pointer = date(at: location.x, width: geo.size.width)
                    model.skimmer.move(to: date(at: location.x, width: geo.size.width), url: file, origin: start, audible: !model.player.isPlaying)
                case .active: break
                case .ended: model.skimmer.end()
                }
            }
            .contextMenu { flagMenu }
            .task(id: key) {
                let image = await SpectrogramRenderer.shared.image(spectrogram, channel: channel, from: key.from, to: key.to, columns: key.columns)
                guard !Task.isCancelled, let image else { return }
                rendered = (key, image)
            }
        }
    }

    /// Flag the turn under the pointer, or just the moment; or edit the flag already there.
    @ViewBuilder private var flagMenu: some View {
        if let pointer {
            if let flag = detail.flag(at: pointer), flag.start.addingTimeInterval(-Flag.slack) <= pointer {
                Text(flag.note.isEmpty ? "Flagged" : flag.note)
                Button("Edit Flag Note…") { model.renamingFlag = flag.id }
                Button("Remove Flag") { detail.removeFlag(flag.id) }
            } else {
                if let turn = detail.turn(at: pointer) {
                    Button("Flag “\(turn.text.count > 30 ? turn.text.prefix(29) + "…" : Substring(turn.text))”") { model.renamingFlag = detail.addFlag(at: pointer).id }
                }
                Button("Flag This Moment") { model.renamingFlag = detail.addFlag(at: pointer, wholeTurn: false).id }
            }
            Divider()
            Button("Move Playhead Here") { if let t = model.player.offset(for: pointer) { model.player.seek(to: t) } }
        }
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        return window.lowerBound.addingTimeInterval(span * min(max(x / max(width, 1), 0), 1))
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
    let flags: [Flag]
    var ttsStatic: [TTSStatic] = []

    var body: some View {
        Canvas { context, size in
            let span = window.upperBound.timeIntervalSince(window.lowerBound)
            guard span > 0 else { return }
            func x(_ date: Date) -> CGFloat { size.width * date.timeIntervalSince(window.lowerBound) / span }
            for flag in flags where flag.end >= window.lowerBound && flag.start <= window.upperBound {
                let left = max(x(flag.start), 0), right = min(x(flag.end), size.width)
                context.fill(Path(CGRect(x: left, y: 0, width: max(right - left, 2), height: 3)), with: .color(Flag.color))
            }
            for item in ttsStatic where item.end >= window.lowerBound && item.start <= window.upperBound {
                let left = max(x(item.start), 0), right = min(x(item.end), size.width)
                context.fill(Path(CGRect(x: left, y: 3, width: max(right - left, 2), height: 3)), with: .color(TTSStatic.color))
            }
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

/// The skimmer: a red line where the pointer is, in every lane.
private struct Skimline: View {
    let window: ClosedRange<Date>
    let width: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        if let date = model.skimmer.date, model.skimmer.isEnabled, window.contains(date) {
            let span = window.upperBound.timeIntervalSince(window.lowerBound)
            Rectangle().fill(.red).frame(width: 1)
                .offset(x: width * date.timeIntervalSince(window.lowerBound) / span)
                .allowsHitTesting(false)
        }
    }
}

extension TTSStatic {
    static let color = Color.red
}

/// Possible TTS static, outlined in red, labeled when there's room.
private struct StaticBoxes: View {
    let items: [TTSStatic]
    let window: ClosedRange<Date>
    let width: CGFloat

    var body: some View {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        ZStack(alignment: .topLeading) {
            ForEach(items.filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }) { item in
                let left = max(width * item.start.timeIntervalSince(window.lowerBound) / span, 0)
                let right = min(width * item.end.timeIntervalSince(window.lowerBound) / span, width)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(TTSStatic.color, lineWidth: 2)
                    .background(TTSStatic.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .bottomLeading) {
                        if right - left >= 64 {
                            Text("TTS static").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(TTSStatic.color, in: RoundedRectangle(cornerRadius: 2))
                                .padding(3)
                        }
                    }
                    .frame(width: max(right - left, 4))
                    .offset(x: left)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Flagged stretches, shaded over the spectrogram with a bar along the top.
private struct FlagBands: View {
    let flags: [Flag]
    let window: ClosedRange<Date>
    let width: CGFloat

    var body: some View {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        ZStack(alignment: .topLeading) {
            ForEach(flags.filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }) { flag in
                let left = max(width * flag.start.timeIntervalSince(window.lowerBound) / span, 0)
                let right = min(width * flag.end.timeIntervalSince(window.lowerBound) / span, width)
                VStack(spacing: 0) {
                    Rectangle().fill(Flag.color).frame(height: 3)
                    Rectangle().fill(Flag.color.opacity(0.18))
                        .overlay(alignment: .leading) { Rectangle().fill(Flag.color.opacity(0.8)).frame(width: 1) }
                }
                .frame(width: max(right - left, 2))
                .offset(x: left)
                .help(flag.note.isEmpty ? "Flagged" : flag.note)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SuggestedBands: View {
    let ranges: [AISuggestionRange]
    let window: ClosedRange<Date>
    let width: CGFloat
    var body: some View {
        let duration = max(0.001, window.upperBound.timeIntervalSince(window.lowerBound))
        ZStack(alignment: .topLeading) {
            ForEach(ranges.filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }) { range in
                let left = max(0, range.start.timeIntervalSince(window.lowerBound) / duration * width)
                let right = min(width, range.end.timeIntervalSince(window.lowerBound) / duration * width)
                Rectangle().fill(.purple.opacity(0.06))
                    .overlay { Rectangle().strokeBorder(.purple.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                    .frame(width: max(2, right - left)).offset(x: left)
                    .help("Unaccepted AI suggestion: " + range.text)
            }
        }.allowsHitTesting(false)
    }
}
