import Foundation
import Testing
@testable import LiveKitObserver

@Suite struct CaptureFlowTests {
    private func packet(_ id: UInt64, source: String, destination: String, interface: String = "0") -> InspectedPacket {
        InspectedPacket(id: id, offset: id * 64, capturedLength: 64, originalLength: 64, linkType: 1, interface: interface,
                        time: PacketTime(ticks: id * 20_000, unitsPerSecond: 1_000_000),
                        decoded: PacketHeaders(source: source, destination: destination, protocolName: "RTP"))
    }

    private func stream(_ id: UInt64, source: String = "a:8000", destination: String = "b:9000", count: Int = 2,
                        ssrc: UInt32 = 1, payload: UInt8 = 0, interface: String = "0") -> RTPStreamAnalysis {
        let first = packet(id, source: source, destination: destination, interface: interface)
        var stream = RTPStreamAnalysis(packet: first, rtp: RTPHeader(sequence: 0, timestamp: 0, ssrc: ssrc, payloadType: payload))
        for index in 0..<count {
            stream.add(packet(id + UInt64(index), source: source, destination: destination, interface: interface),
                       rtp: RTPHeader(sequence: UInt16(index), timestamp: UInt32(index * 160), ssrc: ssrc, payloadType: payload), clock: RTPClock.avp(payload))
        }
        return stream
    }

    private func message(_ id: UInt64 = 1, call: String = "call-a", address: String = "b", port: Int = 9000) -> SIPMessage {
        SIPMessage(packet: packet(id, source: "signal-a", destination: "signal-b"), callID: call, method: "INVITE", status: nil,
                   cseq: "1", fromTag: "", toTag: "", branch: "", complete: true,
                   media: [SDPMedia(address: address, port: port, kind: "audio", profile: "RTP/AVP", payloads: [0, 8, 101])])
    }

    @Test func eachDirectionGetsOneSummaryEvenWithThousandsOfPackets() throws {
        var analysis = CaptureAnalysis()
        analysis.messages = [message()]
        analysis.streams = [stream(10, count: 1000), stream(2000, source: "b:9000", destination: "a:8000", count: 500, ssrc: 2)]
        let rows = CaptureFlowEvent.make(analysis, callID: "call-a")
        #expect(rows.count == 3)
        let media = rows.filter(\.media)
        #expect(media.map(\.id) == [10, 2000])
        #expect(media.map(\.packetCount) == [1000, 500])
        #expect(media[0].packet.decoded.source == media[1].packet.decoded.destination)
        #expect(media[0].packet.decoded.destination == media[1].packet.decoded.source)
        #expect(media.map(\.label) == ["RTP 1 · PCMU", "RTP 2 · PCMU"])
        #expect(media[1].detail.contains("SSRC 2") && media[1].detail.contains("First packet #2000"))
        let overview = CaptureJitterOverview(analysis)
        #expect(overview.series.map(\.call) == ["SDP match: call-a", "SDP match: call-a"])
        #expect(overview.series.map(\.number) == [1, 2])
    }

    @Test func ssrcPayloadAndInterfaceRemainDistinctAndNumberingIsStable() {
        var analysis = CaptureAnalysis()
        analysis.messages = [message()]
        analysis.streams = [stream(40, interface: "1"), stream(30, payload: 101), stream(20, ssrc: 2), stream(10)]
        let rows = CaptureFlowEvent.make(analysis).filter(\.media)
        #expect(rows.count == 4 && Set(rows.compactMap(\.stream)).count == 4)
        #expect(rows.map(\.id) == [10, 20, 30, 40])
        #expect(rows[2].label == "RTP 3 · PT 101")
        #expect(CaptureFlowEvent.make(analysis, callID: "call-a").filter(\.media).map(\.label) == rows.map(\.label))
    }

    @Test func allCallsIncludesUnmatchedMediaAndToggleHidesOnlyMedia() {
        var analysis = CaptureAnalysis()
        analysis.messages = [message()]
        analysis.streams = [stream(10), stream(20, source: "unknown:7000", destination: "other:7001", payload: 8)]
        #expect(CaptureFlowEvent.make(analysis).filter(\.media).count == 2)
        #expect(CaptureFlowEvent.make(analysis, callID: "call-a").filter(\.media).count == 1)
        #expect(CaptureFlowEvent.make(analysis, showMedia: false).map(\.id) == [1])
        analysis.messages = []
        #expect(CaptureFlowEvent.make(analysis).count == 2)
    }

    @Test func conflictingEndpointsAndLaterSDPAreNotClaimedByACall() {
        var analysis = CaptureAnalysis()
        analysis.messages = [message(1), message(2, call: "call-b", address: "a", port: 8000)]
        analysis.streams = [stream(10)]
        #expect(CaptureMediaCallMatch.resolve(analysis)[analysis.streams[0].key] == .ambiguous)
        #expect(CaptureFlowEvent.make(analysis, callID: "call-a").allSatisfy { !$0.media })
        #expect(CaptureFlowEvent.make(analysis).filter(\.media).count == 1)
        analysis.messages = [message(20)]
        #expect(CaptureMediaCallMatch.resolve(analysis)[analysis.streams[0].key] == .unmatched)
    }
}
