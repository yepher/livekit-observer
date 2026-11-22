import Foundation
import Testing
@testable import LiveKitObserver

@Suite struct CaptureJitterOverviewTests {
    private func time(_ seconds: Double) -> PacketTime {
        PacketTime(ticks: UInt64((seconds * 1_000_000).rounded()), unitsPerSecond: 1_000_000)
    }

    private func packet(_ id: UInt64, time: PacketTime?, destination: String = "receiver", interface: String = "0") -> InspectedPacket {
        InspectedPacket(id: id, offset: 0, capturedLength: 64, originalLength: 64, linkType: 1, interface: interface, time: time,
                        decoded: PacketHeaders(source: "sender", destination: destination, protocolName: "RTP"))
    }

    private func stream(_ id: UInt64, times: [PacketTime?], destination: String = "receiver", knownClock: Bool = true) -> RTPStreamAnalysis {
        let header = RTPHeader(sequence: 0, timestamp: 0, ssrc: UInt32(id), payloadType: 0)
        var stream = RTPStreamAnalysis(packet: packet(id, time: times[0], destination: destination), rtp: header)
        for (index, time) in times.enumerated() {
            stream.add(packet(id + UInt64(index), time: time, destination: destination),
                       rtp: RTPHeader(sequence: UInt16(index), timestamp: UInt32(index * 160), ssrc: UInt32(id), payloadType: 0),
                       clock: knownClock ? RTPClock.avp(0) : nil)
        }
        return stream
    }

    @Test func streamsFromDifferentCallsKeepTheirCaptureOffsets() throws {
        var analysis = CaptureAnalysis()
        analysis.firstTime = time(10)
        analysis.lastTime = time(20)
        analysis.streams = [stream(20, times: [time(12), time(12.04)]), stream(40, times: [time(17), time(17.06)], destination: "another receiver")]
        let overview = CaptureJitterOverview(analysis)
        let first = try #require(overview.series[0].points.last)
        let second = try #require(overview.series[1].points.last)
        #expect(abs(first.seconds - 2.04) < 1e-8)
        #expect(abs(second.seconds - 7.06) < 1e-8)
        #expect(first.jitterMS != nil && second.jitterMS != nil)
        #expect(overview.timeDomain == 0...10)
    }

    @Test func missingFirstTimestampUsesTheActualChartOrigin() throws {
        var analysis = CaptureAnalysis()
        analysis.firstTime = time(9)
        analysis.streams = [stream(1, times: [nil, time(10), time(10.04)]), stream(10, times: [nil, nil])]
        let overview = CaptureJitterOverview(analysis)
        let point = try #require(overview.series[0].points.last)
        #expect(abs(point.seconds - 1.04) < 1e-8)
        #expect(overview.series[0].timed)
        #expect(!overview.series[1].timed && overview.series[1].points.isEmpty)
        analysis.firstTime = nil
        let fallback = CaptureJitterOverview(analysis)
        #expect(fallback.origin == time(10))
    }

    @Test func differentTimestampResolutionsAndOffsetsStayAligned() throws {
        var analysis = CaptureAnalysis()
        analysis.firstTime = time(10)
        let start = PacketTime(ticks: 2048, unitsPerSecond: 1024, offsetSeconds: 10)
        let end = PacketTime(ticks: 3072, unitsPerSecond: 1024, offsetSeconds: 10)
        analysis.streams = [stream(1, times: [start, end])]
        let points = CaptureJitterOverview(analysis).series[0].points
        #expect(points.map(\.seconds) == [2, 3])
    }

    @Test func overviewPagesAndPeakBucketsStayBounded() throws {
        var analysis = CaptureAnalysis()
        analysis.firstTime = time(0)
        for index in 0..<17 {
            let times = (0..<2000).map { point in time(Double(index * 100) + Double(point) * 0.02 + (point == 1000 ? 0.5 : 0)) }
            analysis.streams.append(stream(UInt64(index * 3000 + 1), times: times))
        }
        let overview = CaptureJitterOverview(analysis)
        #expect(overview.pageCount == 3)
        let all = (0..<overview.pageCount).flatMap { overview.page($0) }
        #expect(Set(all.map(\.id)).count == 17)
        #expect(overview.page(0).count == 8 && overview.page(1).count == 8 && overview.page(2).count == 1)
        #expect(overview.page(99).map(\.id) == overview.page(2).map(\.id))
        for (series, stream) in zip(overview.series, analysis.streams) {
            #expect(series.points.count <= CaptureJitterOverview.maximumPoints)
            #expect(series.points.compactMap(\.jitterMS).max() == stream.peakJitterMS)
            #expect(series.points.compactMap(\.gapMS).max() == stream.peakGapMS)
        }
        #expect(overview.timeDomain.upperBound > 1600)
    }

    @Test func callHintsRequirePriorUnambiguousSDP() {
        func message(_ id: UInt64, call: String) -> SIPMessage {
            SIPMessage(packet: packet(id, time: time(Double(id))), callID: call, method: "INVITE", status: nil,
                       cseq: "1", fromTag: "", toTag: "", branch: "", complete: true,
                       media: [SDPMedia(address: "receiver", port: 9000, kind: "audio", profile: "RTP/AVP", payloads: [0])])
        }
        var analysis = CaptureAnalysis()
        analysis.messages = [message(1, call: "call-a"), message(20, call: "call-b")]
        analysis.streams = [stream(10, times: [time(10), time(10.02)], destination: "receiver:9000"),
                            stream(30, times: [time(30), time(30.02)], destination: "receiver:9000"),
                            stream(40, times: [time(40), time(40.02)], destination: "elsewhere")]
        let overview = CaptureJitterOverview(analysis)
        #expect(overview.series[0].call == "SDP match: call-a")
        #expect(overview.series[1].call == "Multiple possible calls")
        #expect(overview.series[2].call == "No matching call signaling")
    }

    @Test func unknownClockKeepsIntervalsWithoutInventingJitter() {
        var analysis = CaptureAnalysis()
        analysis.streams = [stream(1, times: [time(1), time(1.04)], knownClock: false)]
        let series = CaptureJitterOverview(analysis).series[0]
        #expect(series.peakJitterMS == nil && series.points.allSatisfy { $0.jitterMS == nil })
        #expect(series.peakGapMS != nil && series.points.last?.gapMS != nil)
        let domain = CaptureJitterOverview.valueDomain([0.1, 120, nil, .nan, .infinity, -1])
        #expect(domain.contains(0.1) && domain.contains(120) && domain.lowerBound >= 0)
        #expect(CaptureJitterOverview.valueDomain([0, 0]).upperBound > 0)
    }
}
