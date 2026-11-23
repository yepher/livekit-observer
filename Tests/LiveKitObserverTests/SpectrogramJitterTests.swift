import Foundation
import ObserverCore
import Testing
@testable import LiveKitObserver

@Suite struct SpectrogramJitterTests {
    private let epoch = 1_700_000_000.0

    private func stream(_ number: UInt32, start: Double, count: Int = 3, clock: RTPClock? = RTPClock.avp(0)) -> RTPStreamAnalysis {
        func packet(_ index: Int) -> InspectedPacket {
            InspectedPacket(id: UInt64(number) * 10_000 + UInt64(index), offset: 0, capturedLength: 64, originalLength: 64,
                            linkType: 1, interface: "0", time: PacketTime(ticks: UInt64(((start + Double(index) * 0.04) * 1e6).rounded()), unitsPerSecond: 1_000_000),
                            decoded: PacketHeaders(source: "a:8000", destination: "b:9000", protocolName: "RTP"))
        }
        func rtp(_ index: Int) -> RTPHeader { RTPHeader(sequence: UInt16(index), timestamp: UInt32(index * 160), ssrc: number, payloadType: 0) }
        var result = RTPStreamAnalysis(packet: packet(0), rtp: rtp(0))
        for index in 0..<count { result.add(packet(index), rtp: rtp(index), clock: clock) }
        return result
    }

    @Test func absoluteTimeSupportsFractionalResolutionAndInterfaceOffsets() throws {
        let time = PacketTime(ticks: 1_700_000_000 * 1024 + 512, unitsPerSecond: 1024, offsetSeconds: -17)
        #expect(try #require(time.date).timeIntervalSince1970 == epoch - 16.5)
        let nanos = PacketTime(ticks: 1_700_000_000_123_456_789, unitsPerSecond: 1_000_000_000)
        #expect(abs(try #require(nanos.date).timeIntervalSince1970 - (epoch + 0.123456789)) < 1e-6)
        #expect(PacketTime(ticks: 0, unitsPerSecond: 0).date == nil)
        #expect(PacketTime(ticks: .max, unitsPerSecond: 1).date == nil)
        #expect(PacketTime(ticks: 1, unitsPerSecond: 1, offsetSeconds: .max).date == nil)
    }

    @Test func preservesStreamDelaysAndMapsToRecordingClockWithOneCorrection() throws {
        var analysis = CaptureAnalysis()
        analysis.firstTime = PacketTime(ticks: UInt64(epoch * 1e6), unitsPerSecond: 1_000_000)
        analysis.streams = [stream(1, start: epoch + 2), stream(2, start: epoch + 7)]
        let data = CaptureJitterOverview(analysis, maximumPoints: 513)
        let timeline = try #require(SpectrogramJitterTimeline(overview: data, offset: -0.5))
        let first = try #require(data.series[0].points.first)
        let second = try #require(data.series[1].points.first)
        #expect(abs(second.seconds - first.seconds - 5) < 1e-6)
        #expect(abs(timeline.date(at: first.seconds).timeIntervalSince1970 - (epoch + 1.5)) < 1e-6)
        // A corrected egress origin is simply another Date on this same timeline.
        let recordingStart = Date(timeIntervalSince1970: epoch + 1)
        let window = recordingStart...recordingStart.addingTimeInterval(30)
        #expect(timeline.range(for: window) == 1.5...31.5)
        #expect(abs(timeline.date(at: first.seconds).timeIntervalSince(recordingStart) - 0.5) < 1e-6)
        let pan = recordingStart.addingTimeInterval(10)
        #expect(timeline.range(for: pan...pan.addingTimeInterval(2)) == 11.5...13.5)
        #expect(timeline.date(at: timeline.seconds(at: pan)) == pan)
        let shifted = try #require(SpectrogramJitterTimeline(overview: data, offset: 60))
        #expect(!data.timeDomain.overlaps(shifted.range(for: window)))
    }

    @Test func chartsStayBoundedAndUnknownMeasurementsRemainUnknown() throws {
        var analysis = CaptureAnalysis()
        analysis.streams = (1...12).map { stream(UInt32($0), start: epoch + Double($0), count: 1600) }
        let data = CaptureJitterOverview(analysis, maximumPoints: 513)
        #expect(data.page(0).count == 8 && data.page(1).count == 4)
        #expect(data.series.allSatisfy { $0.points.count <= 513 })
        #expect(data.series[0].points.count > 129)
        #expect(data.series[0].points.compactMap(\.jitterMS).max() == analysis.streams[0].peakJitterMS)
        #expect(data.page(1).first?.points.first?.seconds == 8)
        analysis.streams = [stream(1, start: epoch, clock: nil)]
        let unknown = CaptureJitterOverview(analysis)
        #expect(unknown.series[0].points.allSatisfy { $0.jitterMS == nil })
        #expect(SpectrogramJitterTimeline(overview: CaptureJitterOverview(CaptureAnalysis()), offset: 0) == nil)
        #expect(SpectrogramJitterTimeline(overview: data, offset: .nan) == nil)
    }

    @Test func offsetIsSavedPerCaptureAndResettable() throws {
        let name = "spectrogram-jitter-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let a = UUID(), b = UUID()
        #expect(SpectrogramJitterTimeline.savedOffset(for: a, defaults: defaults) == 0)
        SpectrogramJitterTimeline.saveOffset(-1.234567, for: a, defaults: defaults)
        #expect(SpectrogramJitterTimeline.savedOffset(for: a, defaults: defaults) == -1.234567)
        #expect(SpectrogramJitterTimeline.savedOffset(for: b, defaults: defaults) == 0)
        SpectrogramJitterTimeline.saveOffset(.infinity, for: a, defaults: defaults)
        #expect(SpectrogramJitterTimeline.savedOffset(for: a, defaults: defaults) == -1.234567)
        SpectrogramJitterTimeline.saveOffset(0, for: a, defaults: defaults)
        #expect(SpectrogramJitterTimeline.savedOffset(for: a, defaults: defaults) == 0)
    }

    @Test @MainActor func analysisIsOnDemandCancellableAndReusesOnlyTheSelectedCapture() async throws {
        let fixture = try InspectionFixture(Wire.header())
        defer { fixture.cleanup() }
        let store = AttachmentStore(root: fixture.directory.appendingPathComponent("attachments"))
        let capture = try await store.importFile(fixture.file, session: fixture.session, limit: 1_000_000)
        let model = SpectrogramJitterModel()
        #expect(model.captureID == nil && model.overview == nil && !model.running)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(capture, store: store)
        }
        await canceled.value
        #expect(model.captureID == nil && model.overview == nil && !model.running)
        await model.load(capture, store: store)
        #expect(model.captureID == capture.id && model.overview != nil && !model.running && model.error == nil)
        // Reopening the panel reuses its summary, even if the original backing file is gone.
        try await store.remove(capture)
        await model.load(capture, store: store)
        #expect(model.overview != nil && model.error == nil)
        let other = PacketCapture(id: UUID(), session: fixture.session, originalName: "missing.pcap", format: .pcap,
                                  byteCount: 0, sha256: "", importedAt: Date(), source: "test")
        await model.load(other, store: store)
        #expect(model.captureID == other.id && model.overview == nil && model.error != nil && !model.running)
    }
}
