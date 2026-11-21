import Foundation
import Testing
@testable import LiveKitObserver

private enum AnalysisWire {
    static func capture(_ packets: [(Double, Data)]) -> Data {
        packets.reduce(Wire.header()) { data, item in
            let microseconds = UInt64((item.0 * 1_000_000).rounded())
            return data + Wire.n(microseconds / 1_000_000) + Wire.n(microseconds % 1_000_000)
                + Wire.n(UInt64(item.1.count)) + Wire.n(UInt64(item.1.count)) + item.1
        }
    }
    static func rtp(_ sequence: UInt16, _ timestamp: UInt32, pt: UInt8 = 0, ssrc: UInt32 = 1) -> Data {
        Wire.ethernet(Wire.ipv4(Wire.udp(Data([0x80, pt]) + Wire.n(UInt64(sequence), 2, false)
            + Wire.n(UInt64(timestamp), 4, false) + Wire.n(UInt64(ssrc), 4, false) + Data([0, 0, 0, 0]))))
    }
    static func sip(_ start: String, cseq: String, call: String = "example", from: String = "a", to: String = "b", body: String = "", reverse: Bool = false) -> Data {
        let text = "\(start)\r\nVia: SIP/2.0/UDP test;branch=z9hG4bK123\r\nFrom: <sip:a@example.com>;tag=\(from)\r\nTo: <sip:b@example.com>;tag=\(to)\r\nCall-ID: \(call)\r\nCSeq: \(cseq)\r\nContent-Type: application/sdp\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        var bytes = Wire.ethernet(Wire.ipv4(Wire.udp(Data(text.utf8))))
        if reverse {
            bytes.replaceSubrange(26..<34, with: [10, 0, 0, 2, 10, 0, 0, 1])
            bytes.replaceSubrange(34..<38, with: Wire.n(5061, 2, false) + Wire.n(5060, 2, false))
        }
        return bytes
    }
    static func sdp(rate: Int = 48000, port: Int = 5061, address: String = "10.0.0.2") -> String {
        "v=0\r\nc=IN IP4 \(address)\r\nm=audio \(port) RTP/AVP 111\r\na=rtpmap:111 opus/\(rate)/2\r\n"
    }
    static func scan(_ packets: [(Double, Data)]) throws -> CaptureAnalysis {
        let f = try InspectionFixture(capture(packets)); defer { f.cleanup() }
        return try CaptureAnalyzer.scan(f.file)
    }
}

@Suite struct CaptureAnalysisTests {
    @Test func jitterUpdatesOnSecondPacketAndUnwrapsRTPClocks() throws {
        let two = try AnalysisWire.scan([(0, AnalysisWire.rtp(1, 0)), (0.04, AnalysisWire.rtp(2, 160))])
        let peak = try #require(two.streams.first?.peakJitterMS)
        #expect(abs(peak - 1.25) < 0.000001)
        let wrap = try AnalysisWire.scan([(0, AnalysisWire.rtp(65534, 4294966976)), (0.02, AnalysisWire.rtp(65535, 4294967136)),
                                         (0.04, AnalysisWire.rtp(0, 0)), (0.06, AnalysisWire.rtp(1, 160))])
        #expect((wrap.streams.first?.peakJitterMS ?? 100) < 0.000001)
        #expect(wrap.streams.first?.sequence.gaps == 0)
    }

    @Test func reorderedCompleteSequenceDoesNotReportLossAndDuplicatesDoNotFillGaps() throws {
        let result = try AnalysisWire.scan([(0, AnalysisWire.rtp(1, 0)), (0.04, AnalysisWire.rtp(3, 320)),
                                           (0.041, AnalysisWire.rtp(2, 160)), (0.06, AnalysisWire.rtp(4, 480)), (0.061, AnalysisWire.rtp(4, 480))])
        let stream = try #require(result.streams.first)
        #expect(stream.sequence.unique == 4 && stream.sequence.gaps == 0)
        #expect(stream.sequence.reordered == 1 && stream.sequence.duplicates == 1)
        #expect(!CaptureExpert.findings(result).contains { $0.rule == "rtp.sequence-gaps" })
        let gaps = try AnalysisWire.scan([(0, AnalysisWire.rtp(1, 0)), (0.04, AnalysisWire.rtp(3, 320)), (0.05, AnalysisWire.rtp(3, 320))])
        #expect(gaps.streams.first?.sequence.gaps == 1)
        #expect(CaptureExpert.findings(gaps).contains { $0.rule == "rtp.sequence-gaps" })
    }

    @Test func dynamicClockUsesMatchingSDPAndDoesNotLeakBetweenCalls() throws {
        let offer = AnalysisWire.sip("INVITE sip:b@example.com SIP/2.0", cseq: "1 INVITE", body: AnalysisWire.sdp())
        let result = try AnalysisWire.scan([(0, offer), (1, AnalysisWire.rtp(1, 0, pt: 111)), (1.04, AnalysisWire.rtp(2, 960, pt: 111))])
        #expect(result.streams.first?.clock?.rate == 48000)
        #expect(abs((result.streams.first?.peakJitterMS ?? 0) - 1.25) < 0.000001)
        #expect(RTPClock.avp(9)?.rate == 8000)
        let other = AnalysisWire.sip("INVITE sip:b@example.com SIP/2.0", cseq: "1 INVITE", call: "other", body: AnalysisWire.sdp(rate: 8000))
        let ambiguous = try AnalysisWire.scan([(0, offer), (0.5, other), (1, AnalysisWire.rtp(1, 0, pt: 111)), (1.04, AnalysisWire.rtp(2, 960, pt: 111))])
        #expect(ambiguous.streams.first?.clock == nil && ambiguous.streams.first?.peakJitterMS == nil)
        let unrelated = AnalysisWire.sip("INVITE sip:b@example.com SIP/2.0", cseq: "1 INVITE", body: AnalysisWire.sdp(address: "192.0.2.1"))
        let unmatched = try AnalysisWire.scan([(0, unrelated), (1, AnalysisWire.rtp(1, 0, pt: 111)), (1.04, AnalysisWire.rtp(2, 960, pt: 111))])
        #expect(unmatched.streams.first?.clock == nil)
    }

    @Test func unknownClocksCanBeExplicitlyReanalyzedAndSSRCsRemainSeparate() throws {
        let packets = [(0.0, AnalysisWire.rtp(1, 0, pt: 111)), (0.01, AnalysisWire.rtp(1, 0, pt: 111, ssrc: 2)),
                       (0.04, AnalysisWire.rtp(2, 960, pt: 111)), (0.05, AnalysisWire.rtp(2, 320, pt: 111, ssrc: 2))]
        let f = try InspectionFixture(AnalysisWire.capture(packets)); defer { f.cleanup() }
        let result = try CaptureAnalyzer.scan(f.file)
        #expect(result.streams.count == 2 && result.streams.allSatisfy { $0.peakJitterMS == nil })
        let selected = try #require(result.streams.first?.key)
        let override = RTPClock(rate: 48000, codec: "Manual", source: "Manual override")
        let updated = try CaptureAnalyzer.scan(f.file, only: selected, override: override)
        #expect(updated.streams.count == 1 && updated.streams.first?.count == 2)
        #expect(abs((updated.streams.first?.peakJitterMS ?? 0) - 1.25) < 0.000001)
    }

    @Test func timingAndSequenceDiscontinuitiesDoNotFabricateHugeJitterOrLoss() throws {
        let result = try AnalysisWire.scan([(1, AnalysisWire.rtp(1, 0)), (1.02, AnalysisWire.rtp(4000, 160)),
                                           (0.9, AnalysisWire.rtp(4001, 320)), (1.1, AnalysisWire.rtp(4002, 2_000_000_000))])
        let stream = try #require(result.streams.first)
        #expect(stream.sequence.gaps == nil && stream.sequence.discontinuities == 1)
        #expect(stream.peakJitterMS == nil && stream.timingResets == 2)
        #expect(CaptureExpert.findings(result).contains { $0.rule == "rtp.coverage" })
    }

    @Test func chartsStayBoundedAndRetainTimingPeaks() throws {
        let packets: [(Double, Data)] = (0..<10_000).map { index in
            let arrival = Double(index) * 0.02 + (index == 2000 ? 0.5 : 0.0)
            let bytes = AnalysisWire.rtp(UInt16(index), UInt32(index * 160))
            return (arrival, bytes)
        }
        let result = try AnalysisWire.scan(packets)
        let stream = try #require(result.streams.first)
        #expect(stream.count == 10_000 && stream.chart.count <= 513)
        #expect(stream.chart.compactMap(\.jitterMS).max() == stream.peakJitterMS)
        #expect(stream.chart.compactMap(\.gapMS).max() == stream.peakGapMS)
        #expect(stream.peakGapPacket?.id == 2001)
        #expect(CaptureExpert.findings(result, jitterThreshold: 1).contains { $0.rule == "rtp.jitter" && $0.evidence.id == stream.peakJitterPacket?.id })
    }

    @Test func cancelSuccessDoesNotBecomeInviteSuccessAndChallengesAreInformational() throws {
        let result = try AnalysisWire.scan([
            (0, AnalysisWire.sip("INVITE sip:b@example.com SIP/2.0", cseq: "1 INVITE")),
            (1, AnalysisWire.sip("CANCEL sip:b@example.com SIP/2.0", cseq: "1 CANCEL")),
            (2, AnalysisWire.sip("SIP/2.0 200 OK", cseq: "1 CANCEL", reverse: true)),
            (3, AnalysisWire.sip("SIP/2.0 487 Request Terminated", cseq: "1 INVITE", reverse: true)),
            (10, AnalysisWire.sip("SIP/2.0 401 Unauthorized", cseq: "2 INVITE", reverse: true))])
        let findings = CaptureExpert.findings(result)
        #expect(result.messages[2].method == "CANCEL")
        #expect(findings.contains { $0.rule == "sip.response.487" && $0.severity == .information })
        #expect(findings.contains { $0.rule == "sip.response.401" && $0.severity == .information })
        #expect(!findings.contains { $0.rule == "sip.ack-not-observed" })
    }

    @Test func missingACKNeedsMatchingDialogAndEnoughCompleteCoverage() throws {
        let invite = AnalysisWire.sip("INVITE sip:b@example.com SIP/2.0", cseq: "1 INVITE")
        let response = AnalysisWire.sip("SIP/2.0 200 OK", cseq: "1 INVITE", reverse: true)
        let ack = AnalysisWire.sip("ACK sip:b@example.com SIP/2.0", cseq: "1 ACK")
        let tail = AnalysisWire.rtp(1, 0)
        let good = try AnalysisWire.scan([(0, invite), (1, response), (1.1, ack), (10, tail)])
        #expect(!CaptureExpert.findings(good).contains { $0.rule == "sip.ack-not-observed" })
        let absent = try AnalysisWire.scan([(0, invite), (1, response), (10, tail)])
        #expect(CaptureExpert.findings(absent).contains { $0.rule == "sip.ack-not-observed" && $0.evidence.id == 2 })
        let short = try AnalysisWire.scan([(0, invite), (1, response), (2, tail)])
        #expect(!CaptureExpert.findings(short).contains { $0.rule == "sip.ack-not-observed" })
        let forkAck = AnalysisWire.sip("ACK sip:b@example.com SIP/2.0", cseq: "1 ACK", to: "other-fork")
        let fork = try AnalysisWire.scan([(0, invite), (1, response), (1.1, forkAck), (10, tail)])
        #expect(CaptureExpert.findings(fork).contains { $0.rule == "sip.ack-not-observed" })
        let f = try InspectionFixture(AnalysisWire.capture([(0, invite), (1, response), (10, tail)]) + Data([1, 2]))
        defer { f.cleanup() }
        let partial = try CaptureAnalyzer.scan(f.file)
        #expect(!partial.complete && !partial.warnings.isEmpty)
        #expect(!CaptureExpert.findings(partial).contains { $0.rule == "sip.ack-not-observed" })
    }

    @Test func expertUsesObservedResponsesWithoutInventingRootCausesOrOpusEchoRequirements() throws {
        let body = AnalysisWire.sdp() + "a=fmtp:111 useinbandfec=1;stereo=1\r\n"
        let invite = AnalysisWire.sip("INVITE sip:b@example.com SIP/2.0", cseq: "1 INVITE", body: body)
        let answer = AnalysisWire.sip("SIP/2.0 200 OK", cseq: "1 INVITE", body: AnalysisWire.sdp(), reverse: true)
        let good = try AnalysisWire.scan([(0, invite), (1, answer)])
        #expect(!CaptureExpert.findings(good).contains { $0.rule.contains("fmtp") })
        for code in [403, 404, 408, 486, 488, 503] {
            let result = try AnalysisWire.scan([(0, invite), (1, AnalysisWire.sip("SIP/2.0 \(code) Example", cseq: "1 INVITE", reverse: true))])
            let finding = try #require(CaptureExpert.findings(result).first { $0.rule == "sip.response.\(code)" })
            #expect(finding.evidence.id == 2 && !finding.nextCheck.isEmpty)
        }
    }

    @Test func streamLimitIsVisibleAndCancellationDoesNotReturnReadyPartialResults() async throws {
        let packets = (1...129).map { index in (Double(index), AnalysisWire.rtp(1, 0, ssrc: UInt32(index))) }
        let f = try InspectionFixture(AnalysisWire.capture(packets)); defer { f.cleanup() }
        let result = try CaptureAnalyzer.scan(f.file)
        #expect(result.streams.count == 128 && !result.complete)
        #expect(result.warnings.contains { $0.contains("evidence budget") })
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try CaptureAnalyzer.scan(f.file) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test @MainActor func evidenceInspectionWorksOutsideTheCurrentPacketPage() async throws {
        let f = try InspectionFixture(AnalysisWire.capture([(0, AnalysisWire.rtp(1, 0)), (0.04, AnalysisWire.rtp(2, 160))]))
        defer { f.cleanup() }
        let store = AttachmentStore(root: f.directory.appendingPathComponent("attachments"))
        let capture = try await store.importFile(f.file, session: f.session, limit: 1_000_000)
        let analysis = try CaptureAnalyzer.scan(await store.file(for: capture))
        let packet = try #require(analysis.streams.first?.peakJitterPacket)
        let viewer = PacketViewerModel(capture: capture, store: store)
        viewer.inspect(packet)
        let deadline = ContinuousClock.now + .seconds(5)
        while viewer.loadingDetail {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(viewer.page == nil && viewer.selectedPacket?.id == 2)
        #expect(viewer.contents?.decoded.rtp?.sequence == 2)
    }

    @Test func unlimitedNGSectionsCannotGrowClockHistoryWithoutBound() throws {
        var bytes = Data()
        for _ in 0..<257 { bytes += Wire.section() + Wire.interface() + Wire.enhanced(Data([1, 2, 3, 4])) }
        let f = try InspectionFixture(bytes); defer { f.cleanup() }
        let result = try CaptureAnalyzer.scan(f.file)
        #expect(!result.complete && result.interfaceEndTimes.count == 256)
        #expect(result.warnings.contains { $0.contains("256 capture clock domains") })
    }
}
