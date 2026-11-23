import ObserverCore
import Foundation
import Observation

@MainActor @Observable
final class CaptureAnalysisModel {
    let capture: PacketCapture
    private let store: AttachmentStore
    private(set) var result: CaptureAnalysis?
    private(set) var findings: [CaptureFinding] = []
    private(set) var jitterOverview: CaptureJitterOverview?
    var jitterOverviewVisible = true
    private(set) var running = false
    private(set) var progress: CaptureScanProgress?
    private(set) var error: String?
    var selectedCall = ""
    var selectedStream: RTPStreamKey?
    var jitterThreshold = 30.0
    var gapThreshold = 100.0
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(capture: PacketCapture, store: AttachmentStore) { self.capture = capture; self.store = store }
    var stream: RTPStreamAnalysis? { result?.streams.first { $0.key == selectedStream } }

    func start() { guard result == nil, !running else { return }; scan() }
    func applyClock(_ input: String) {
        guard let selectedStream, !running else { return }
        let input = input.trimmingCharacters(in: .whitespaces)
        if input.isEmpty { scan(only: selectedStream); return }
        guard let rate = Int(input), (100...1_000_000).contains(rate) else { error = "Enter an RTP clock rate between 100 and 1,000,000 Hz, or leave it blank to use SDP/profile defaults."; return }
        scan(only: selectedStream, override: RTPClock(rate: rate, codec: "User supplied", source: "Manual override"))
    }
    func refreshFindings() {
        guard let result else { return }
        if !jitterThreshold.isFinite || jitterThreshold <= 0 { jitterThreshold = 30 }
        if !gapThreshold.isFinite || gapThreshold <= 0 { gapThreshold = 100 }
        findings = CaptureExpert.findings(result, jitterThreshold: jitterThreshold, gapThreshold: gapThreshold)
    }
    private func scan(only stream: RTPStreamKey? = nil, override: RTPClock? = nil) {
        let token = UUID(); generation = token; running = true; progress = nil; error = nil
        task = Task { [weak self, capture, store] in
            let file = await store.file(for: capture)
            do {
                let result = try await MediaResources.compute(project: capture.session.projectKey) { [model = self] in
                    try CaptureAnalyzer.scan(file, only: stream, override: override) { progress in
                        Task { @MainActor in
                            guard let model, model.generation == token, model.running else { return }
                            model.progress = progress
                        }
                    }
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if let stream, let replacement = result.streams.first, let index = self.result?.streams.firstIndex(where: { $0.key == stream }) {
                    self.result?.streams[index] = replacement
                } else if stream == nil {
                    self.result = result
                    self.selectedStream = result.streams.first?.key
                    self.selectedCall = ""
                }
                self.running = false; self.task = nil
                if let analysis = self.result { self.jitterOverview = CaptureJitterOverview(analysis) }
                self.refreshFindings()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.running = false; self.task = nil; self.error = error.localizedDescription
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; running = false
        if result == nil { error = "Analysis canceled. Start again when you're ready." }
    }
}
