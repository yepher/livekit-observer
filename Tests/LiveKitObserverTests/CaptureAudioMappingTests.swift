import Foundation
import Testing
@testable import LiveKitObserver

@Suite struct CaptureAudioMappingTests {
    private func row(_ number: Int, reverse: Bool = false, interface: String = "0", call: String = "call-a", payload: UInt8 = 0) -> CaptureJitterOverview.Series {
        let packet = InspectedPacket(id: UInt64(number), offset: 0, capturedLength: 64, originalLength: 64, linkType: 1, interface: interface, time: nil,
                                     decoded: PacketHeaders(source: reverse ? "b:9000" : "a:8000", destination: reverse ? "a:8000" : "b:9000", protocolName: "RTP"))
        let key = RTPStreamKey(packet, RTPHeader(sequence: 1, timestamp: 0, ssrc: UInt32(number), payloadType: payload))
        return CaptureJitterOverview.Series(key: key, number: number, call: call, codec: "PCMU", points: [], timed: true, peakJitterMS: nil, peakGapMS: nil)
    }
    private func lane(_ kind: RecordingSource.Kind, _ channel: Int, count: Int = 2, identical: Bool = false, routed: Bool = false) -> CaptureAudioLane {
        let source = RecordingSource(kind: kind, file: URL(fileURLWithPath: "/tmp/unused.wav"), origin: nil, userLeftAgentRight: routed)
        return CaptureAudioLane(source: source, channel: channel, count: count, identical: identical)
    }

    @Test func neverGuessesOwnershipFromPacketDirection() {
        let mapping = CaptureAudioMapping()
        #expect(mapping.target(for: row(1)) == .unassigned)
        #expect(mapping.target(for: row(2, reverse: true)) == .unassigned)
        #expect(!lane(.observability, 0).matches(.unassigned))
    }

    @Test func assignmentsFollowSSRCChangesButSeparateDirectionsInterfacesAndCalls() {
        var mapping = CaptureAudioMapping()
        mapping.assign(.agent, to: row(1))
        #expect(mapping.target(for: row(2, payload: 8)) == .agent)
        #expect(mapping.target(for: row(3, reverse: true)) == .unassigned)
        #expect(mapping.target(for: row(4, interface: "1")) == .unassigned)
        #expect(mapping.target(for: row(5, call: "call-b")) == .unassigned)
        mapping.assign(.user, to: row(3, reverse: true))
        #expect(mapping.target(for: row(6, reverse: true)) == .user)
        mapping.assign(.unassigned, to: row(2))
        #expect(mapping.target(for: row(1)) == .unassigned)
        #expect(mapping.target(for: row(3, reverse: true)) == .user)
    }

    @Test func rolesApplyOnlyToKnownSeparatedRecordingLayouts() {
        #expect(lane(.observability, 0).matches(.user))
        #expect(!lane(.observability, 0).matches(.agent))
        #expect(lane(.observability, 1).matches(.agent))
        #expect(lane(.egress, 0, routed: true).matches(.user))
        #expect(lane(.egress, 1, routed: true).matches(.agent))
        #expect(!lane(.egress, 0).matches(.user))
        #expect(!lane(.egress, 1).matches(.agent))
        #expect(!lane(.observability, 0, count: 1).matches(.user))
        #expect(!lane(.observability, 0, identical: true).matches(.user))
        #expect(!lane(.egress, 1, identical: true, routed: true).matches(.agent))
        let target = CaptureAudioTarget.channel(recording: "egress", index: 1)
        #expect(lane(.egress, 1).matches(target))
        #expect(!lane(.egress, 0).matches(target))
        #expect(!lane(.observability, 1).matches(target))
    }

    @Test func choicesReflectAvailableAudioWithoutInventingRolesForMixedOrUnknownChannels() {
        let unknown = [lane(.egress, 0), lane(.egress, 1)]
        #expect(CaptureAudioMapping.targets(lanes: unknown) == [.unassigned] + unknown.map(\.id))
        let known = unknown + [lane(.observability, 0), lane(.observability, 1)]
        #expect(CaptureAudioMapping.targets(lanes: known).prefix(3) == [.unassigned, .user, .agent])
        #expect(CaptureAudioMapping.title(.channel(recording: "egress", index: 1), lanes: known) == "Egress · Right")
        #expect(CaptureAudioMapping.title(.channel(recording: "egress", index: 4), lanes: known) == "Unavailable recording channel")
    }

    @Test func mappingsSurviveReopenAndRemainCaptureScoped() throws {
        let name = "capture-channel-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), other = UUID()
        var mapping = CaptureAudioMapping()
        mapping.assign(.user, to: row(1))
        mapping.assign(.channel(recording: "egress", index: 1), to: row(2, reverse: true))
        mapping.save(for: first, defaults: defaults)
        let saved = CaptureAudioMapping.load(for: first, defaults: defaults)
        #expect(saved.target(for: row(3)) == .user)
        #expect(saved.target(for: row(4, reverse: true)) == .channel(recording: "egress", index: 1))
        #expect(CaptureAudioMapping.load(for: other, defaults: defaults).target(for: row(1)) == .unassigned)
        mapping.assign(.unassigned, to: row(1)); mapping.assign(.unassigned, to: row(2, reverse: true))
        mapping.save(for: first, defaults: defaults)
        #expect(CaptureAudioMapping.load(for: first, defaults: defaults).target(for: row(1)) == .unassigned)
    }
}
