import Foundation
import Observation
import ObserverCore

/// PCAP timestamps and audio origins both use UTC. The correction belongs to the capture,
/// not to a recording: egress's existing audio alignment has already corrected its own origin.
struct SpectrogramJitterTimeline {
    let origin: Date

    init?(overview: CaptureJitterOverview, offset: TimeInterval) {
        guard offset.isFinite, let date = overview.origin?.date else { return nil }
        origin = date.addingTimeInterval(offset)
    }

    func date(at seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
    func seconds(at date: Date) -> TimeInterval { date.timeIntervalSince(origin) }
    func range(for window: ClosedRange<Date>) -> ClosedRange<Double> {
        seconds(at: window.lowerBound)...seconds(at: window.upperBound)
    }

    static func savedOffset(for id: UUID, defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: "spectrogramCaptureOffset." + id.uuidString)
        return value.isFinite ? value : 0
    }

    static func saveOffset(_ seconds: Double, for id: UUID, defaults: UserDefaults = .standard) {
        guard seconds.isFinite else { return }
        let key = "spectrogramCaptureOffset." + id.uuidString
        if seconds == 0 { defaults.removeObject(forKey: key) }
        else { defaults.set(seconds, forKey: key) }
    }
}

/// Keeps only one bounded chart summary, never packets or full capture contents. SwiftUI's
/// task cancels the worker when the panel closes or the selected capture/session changes.
@MainActor @Observable
final class SpectrogramJitterModel {
    private(set) var captureID: UUID?
    private(set) var overview: CaptureJitterOverview?
    private(set) var running = false
    private(set) var error: String?
    private(set) var partial = false
    private(set) var offset = 0.0
    private(set) var mapping = CaptureAudioMapping()
    var selectedStream = 0
    var page = 0
    private var generation = UUID()

    var timeline: SpectrogramJitterTimeline? {
        overview.flatMap { SpectrogramJitterTimeline(overview: $0, offset: offset) }
    }
    var visibleSeries: [CaptureJitterOverview.Series] {
        guard let overview else { return [] }
        return selectedStream == 0 ? overview.page(page) : overview.series.filter { $0.number == selectedStream }
    }
    func series(for lane: CaptureAudioLane) -> [CaptureJitterOverview.Series] {
        visibleSeries.filter { lane.matches(mapping.target(for: $0)) }
    }
    func setOffset(_ seconds: Double) {
        guard let captureID, seconds.isFinite else { return }
        offset = seconds
        SpectrogramJitterTimeline.saveOffset(seconds, for: captureID)
    }
    func assign(_ target: CaptureAudioTarget, to series: CaptureJitterOverview.Series) {
        guard let captureID else { return }
        mapping.assign(target, to: series)
        mapping.save(for: captureID)
    }

    func load(_ capture: PacketCapture, store: AttachmentStore) async {
        guard !Task.isCancelled else { return }
        if captureID == capture.id, overview != nil { return }
        let token = UUID()
        generation = token
        captureID = capture.id; overview = nil; error = nil; partial = false; running = true
        offset = SpectrogramJitterTimeline.savedOffset(for: capture.id)
        mapping = CaptureAudioMapping.load(for: capture.id)
        selectedStream = 0; page = 0
        defer { if generation == token { running = false } }
        do {
            let file = await store.file(for: capture)
            let result = try await MediaResources.compute(project: capture.session.projectKey) {
                let analysis = try CaptureAnalyzer.scan(file)
                return (CaptureJitterOverview(analysis, maximumPoints: 513), !analysis.complete)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            overview = result.0; partial = result.1
        } catch is CancellationError { }
        catch { if generation == token, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
