import Foundation
import Testing
@testable import LiveKitObserver

enum Wire {
    static func n(_ value: UInt64, _ width: Int = 4, _ little: Bool = true) -> Data {
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return Data(little ? bytes : bytes.reversed())
    }
    static func header(little: Bool = true, nano: Bool = false, snap: UInt64 = 65535, link: UInt64 = 1) -> Data {
        n(nano ? 0xa1b23c4d : 0xa1b2c3d4, 4, little) + n(2, 2, little) + n(4, 2, little)
        + n(0, 8) + n(snap, 4, little) + n(link, 4, little)
    }
    static func record(_ payload: Data, little: Bool = true, fraction: UInt64 = 123456, original: UInt64? = nil) -> Data {
        n(1_700_000_000, 4, little) + n(fraction, 4, little) + n(UInt64(payload.count), 4, little)
        + n(original ?? UInt64(payload.count), 4, little) + payload
    }
    static func block(_ type: UInt64, _ body: Data, little: Bool = true) -> Data {
        let count = UInt64(body.count + 12)
        return n(type, 4, little) + n(count, 4, little) + body + n(count, 4, little)
    }
    static func section(little: Bool = true) -> Data {
        block(0x0a0d0d0a, n(0x1a2b3c4d, 4, little) + n(1, 2, little) + n(0, 2) + n(UInt64.max, 8), little: little)
    }
    static func interface(little: Bool = true, options: Data = Data()) -> Data {
        block(1, n(1, 2, little) + n(0, 2) + n(65535, 4, little) + options, little: little)
    }
    static func enhanced(_ payload: Data, interface: UInt64 = 0, ticks: UInt64 = 1_000_000, little: Bool = true, type: UInt64 = 6) -> Data {
        let padding = Data(repeating: 0, count: (4 - payload.count % 4) % 4)
        let id = type == 2 ? n(interface, 2, little) + n(0, 2) : n(interface, 4, little)
        return block(type, id + n(ticks >> 32, 4, little) + n(ticks & 0xffff_ffff, 4, little)
                     + n(UInt64(payload.count), 4, little) + n(UInt64(payload.count), 4, little) + payload + padding, little: little)
    }
    static let sip = "INVITE sip:agent@example.com SIP/2.0\r\nVia: SIP/2.0/UDP first;branch=a\r\nVia: SIP/2.0/UDP second;branch=b\r\nCall-ID: example\r\nContent-Length: 0\r\n\r\n"
    static func udp(_ payload: Data) -> Data {
        n(5060, 2, false) + n(5061, 2, false) + n(UInt64(payload.count + 8), 2, false) + n(0, 2) + payload
    }
    static func ipv4(_ transport: Data, proto: UInt8 = 17, fragment: UInt64 = 0) -> Data {
        Data([0x45, 0]) + n(UInt64(20 + transport.count), 2, false) + n(0, 2) + n(fragment, 2, false)
        + Data([64, proto, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2]) + transport
    }
    static func ethernet(_ ip: Data) -> Data { Data(repeating: 0, count: 12) + Data([8, 0]) + ip }
    static var sipPacket: Data { ethernet(ipv4(udp(Data(sip.utf8)))) }
}

struct InspectionFixture {
    let directory: URL
    let file: URL
    init(_ data: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("observer-inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("sample.pcap")
        try data.write(to: file)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    var session: CaptureSession { CaptureSession(projectKey: "lk:fixture", projectName: "fixture", sessionID: "RM_fixture", roomName: "Example", startedAt: nil, endedAt: nil) }
}

@Suite struct PacketInspectionTests {
    @Test func classicFormatsPreserveExactTimestampsAndSIPBytes() throws {
        for little in [true, false] {
            for nano in [true, false] {
                let f = try InspectionFixture(Wire.header(little: little, nano: nano) + Wire.record(Wire.sipPacket, little: little, fraction: nano ? 123456789 : 123456))
                defer { f.cleanup() }
                let page = try PacketPageReader.read(f.file)
                let packet = try #require(page.packets.first)
                #expect(page.next == nil && page.warnings.isEmpty)
                #expect(packet.time?.text == "2023-11-14T22:13:20." + (nano ? "123456789Z" : "123456000Z"))
                #expect(packet.decoded.protocolName == "SIP")
                #expect(packet.decoded.source == "10.0.0.1:5060")
                #expect(packet.decoded.destination == "10.0.0.2:5061")
                #expect(packet.decoded.text == nil)
                let detail = try PacketPageReader.detail(f.file, packet: packet)
                #expect(detail.decoded.text == Wire.sip)
                #expect(detail.hex.contains("000000"))
            }
        }
    }

    @Test func pagesWithoutLosingOrDuplicatingBoundaryPackets() throws {
        let data = (0..<401).reduce(Wire.header()) { data, _ in data + Wire.record(Wire.sipPacket) }
        let f = try InspectionFixture(data); defer { f.cleanup() }
        var cursor: PacketCursor?, ids: [UInt64] = []
        repeat {
            let page = try PacketPageReader.read(f.file, from: cursor)
            #expect(page.packets.count <= 200)
            #expect(page.warnings.isEmpty)
            ids += page.packets.map(\.id)
            cursor = page.next
        } while cursor != nil
        #expect(ids == Array(1...401))
    }

    @Test func ngClocksInterfacesSectionsAndObsoletePacketBlocks() throws {
        for little in [true, false] {
            // Binary resolution of 2^-10 seconds and a signed -2 second offset.
            let options = Wire.n(9, 2, little) + Wire.n(1, 2, little) + Data([0x8a, 0, 0, 0])
                + Wire.n(14, 2, little) + Wire.n(8, 2, little) + Wire.n(UInt64(bitPattern: -2), 8, little) + Wire.n(0, 4)
            var data = Wire.section(little: little) + Wire.interface(little: little) + Wire.interface(little: little, options: options)
            data += Wire.enhanced(Wire.sipPacket, interface: 1, ticks: 3584, little: little)
            data += Wire.enhanced(Wire.sipPacket, ticks: 1_123_456, little: little, type: 2)
            data += Wire.section(little: !little) + Wire.interface(little: !little) + Wire.enhanced(Wire.sipPacket, little: !little)
            let f = try InspectionFixture(data); defer { f.cleanup() }
            let first = try PacketPageReader.read(f.file, limit: 1)
            let cursor: PacketCursor = try #require(first.next)
            let second = try PacketPageReader.read(f.file, from: cursor)
            #expect(first.packets.first?.time?.text == "1970-01-01T00:00:01.500000000Z")
            #expect(first.packets.first?.interface == "0:1")
            #expect(second.packets.map(\.interface) == ["0:0", "1:0"])
            #expect(second.packets.first?.time?.text == "1970-01-01T00:00:01.123456000Z")
            #expect(second.warnings.isEmpty && second.next == nil)
        }
    }

    @Test func ngSimplePacketsAndUnsupportedClocksRemainExplicitlyUnknown() throws {
        let payload = Data([1, 2, 3, 4])
        let options = Wire.n(9, 2) + Wire.n(1, 2) + Data([20, 0, 0, 0])
        let f = try InspectionFixture(Wire.section() + Wire.interface(options: options)
            + Wire.enhanced(payload) + Wire.block(3, Wire.n(4) + payload))
        defer { f.cleanup() }
        let page = try PacketPageReader.read(f.file)
        #expect(page.packets.count == 2)
        #expect(page.packets.allSatisfy { $0.time == nil })
        #expect(page.warnings.contains { $0.contains("unknown") })
    }

    @Test func corruptionKeepsValidEvidenceAndStopsWithVisibleWarning() throws {
        let valid = Wire.header() + Wire.record(Wire.sipPacket)
        let hugeLength = Wire.n(0, 8) + Wire.n(UInt64(UInt32.max)) + Wire.n(UInt64(UInt32.max))
        for tail in [Data([1, 2]), hugeLength, Wire.record(Wire.sipPacket, original: 1)] {
            let f = try InspectionFixture(valid + tail); defer { f.cleanup() }
            let page = try PacketPageReader.read(f.file)
            #expect(page.packets.count == 1)
            #expect(page.next == nil && page.readThrough < page.fileSize)
            #expect(page.warnings.contains { $0.hasPrefix("Stopped at byte") })
        }
        var mismatch = Wire.enhanced(Wire.sipPacket)
        mismatch[mismatch.count - 1] = 1
        for invalid in [mismatch, Wire.enhanced(Wire.sipPacket, interface: 1), Wire.section() + Wire.enhanced(Wire.sipPacket)] {
            let f = try InspectionFixture(Wire.section() + Wire.interface() + invalid); defer { f.cleanup() }
            let page = try PacketPageReader.read(f.file)
            #expect(page.packets.isEmpty && !page.warnings.isEmpty && page.next == nil)
        }
    }

    @Test func hugeSparsePacketUsesBoundedPreviewsAndDetails() throws {
        let length: UInt64 = 2_147_483_648
        let f = try InspectionFixture(Wire.header(snap: length) + Wire.n(0, 8) + Wire.n(length) + Wire.n(length))
        defer { f.cleanup() }
        let handle = try FileHandle(forWritingTo: f.file)
        try handle.truncate(atOffset: 40 + length)
        try handle.seekToEnd()
        try handle.write(contentsOf: Wire.record(Wire.sipPacket))
        try handle.close()
        let page = try PacketPageReader.read(f.file)
        #expect(page.packets.map(\.id) == [1, 2])
        #expect(page.packets[1].decoded.protocolName == "SIP")
        let detail = try PacketPageReader.detail(f.file, packet: page.packets[0])
        #expect(detail.bytes.count == 65_536)
        #expect(detail.hex.split(separator: "\n").count == 256)
        #expect(page.warnings.isEmpty)
    }

    @Test func metadataScanningAndCancellationAreBounded() async throws {
        let unknownBlocks = (0..<10_001).reduce(Data()) { data, _ in data + Wire.block(0x12345678, Data()) }
        let f = try InspectionFixture(Wire.section() + unknownBlocks + Wire.interface() + Wire.enhanced(Wire.sipPacket))
        defer { f.cleanup() }
        let page = try PacketPageReader.read(f.file)
        #expect(page.packets.isEmpty && page.next != nil)
        #expect(page.warnings.contains { $0.contains("paused") })
        let cursor: PacketCursor = try #require(page.next)
        let next = try PacketPageReader.read(f.file, from: cursor)
        #expect(next.packets.count == 1 && next.next == nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PacketPageReader.read(f.file)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func packetDecoderDistinguishesMediaCandidatesFragmentsAndUnsupportedLinks() {
        let rtp = Data([0x80, 0xe0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xde, 0xad, 0xbe, 0xef])
        let decoded = PacketHeaders.decode(Array(Wire.ethernet(Wire.ipv4(Wire.udp(rtp)))), linkType: 1)
        #expect(decoded.protocolName == "RTP?")
        #expect(decoded.fields.contains("Sequence: 65535"))
        #expect(decoded.fields.contains("RTP timestamp: 4294967295"))
        #expect(decoded.fields.contains("SSRC: 0xdeadbeef"))
        for pt: UInt8 in [200, 201, 205, 206] {
            let rtcp = Data([0x80, pt, 0, 1, 0, 0, 0, 0])
            #expect(PacketHeaders.decode(Array(Wire.ethernet(Wire.ipv4(Wire.udp(rtcp)))), linkType: 1).protocolName == "RTCP?")
        }
        let fragment = Wire.ethernet(Wire.ipv4(Wire.udp(Data(Wire.sip.utf8)), fragment: 0x2000))
        #expect(PacketHeaders.decode(Array(fragment), linkType: 1).summary.contains("reassembly"))
        #expect(PacketHeaders.decode(Array(Wire.sipPacket), linkType: 999).summary.contains("not decoded"))
        for length in 0..<Wire.sipPacket.count {
            _ = PacketHeaders.decode(Array(Wire.sipPacket.prefix(length)), linkType: 1)
        }
    }

    @Test func decodesVLANRawCookedIPv6AndTCPWithoutClaimingReassembly() {
        let ip = Wire.ipv4(Wire.udp(Data(Wire.sip.utf8)))
        let vlan = Data(repeating: 0, count: 12) + Data([0x81, 0, 0, 1, 8, 0]) + ip
        let cooked = Data(repeating: 0, count: 14) + Data([8, 0]) + ip
        let cooked2 = Data([8, 0]) + Data(repeating: 0, count: 18) + ip
        for (link, bytes): (UInt32, Data) in [(1, vlan), (101, ip), (113, cooked), (276, cooked2)] {
            #expect(PacketHeaders.decode(Array(bytes), linkType: link).protocolName == "SIP")
        }
        let udp = Wire.udp(Data(Wire.sip.utf8))
        let v6 = Data([0x60, 0, 0, 0]) + Wire.n(UInt64(udp.count), 2, false) + Data([17, 64]) + Data(repeating: 0, count: 32) + udp
        #expect(PacketHeaders.decode(Array(v6), linkType: 101).protocolName == "SIP")
        let tcp = Wire.n(5060, 2, false) + Wire.n(5061, 2, false) + Wire.n(0, 8) + Data([0x50, 0x18, 0, 0, 0, 0, 0, 0]) + Data(Wire.sip.utf8)
        let decoded = PacketHeaders.decode(Array(Wire.ipv4(tcp, proto: 6)), linkType: 101)
        #expect(decoded.protocolName == "SIP/TCP" && decoded.text == Wire.sip)
        #expect(decoded.fields.contains { $0.contains("not reassembled") })
    }

    @Test @MainActor func openRoutesToNativeViewerAndNavigationRetainsCaptureIdentity() async throws {
        let data = (0..<201).reduce(Wire.header()) { data, _ in data + Wire.record(Wire.sipPacket) }
        let f = try InspectionFixture(data); defer { f.cleanup() }
        let store = AttachmentStore(root: f.directory.appendingPathComponent("attachments"))
        let capture = try await store.importFile(f.file, session: f.session, limit: 1_000_000)
        let library = PacketCaptureModel(store: store)
        library.open(capture)
        #expect(library.openedCapture == capture)
        #expect(library.message == nil)
        let viewer = try PacketViewerModel(capture: #require(library.openedCapture), store: store)
        viewer.first()
        try await waitForViewer(viewer)
        #expect(viewer.page?.packets.count == 200 && viewer.selectedID == 1)
        #expect(viewer.contents?.decoded.text == Wire.sip)
        viewer.next()
        try await waitForViewer(viewer)
        #expect(viewer.page?.packets.count == 1 && viewer.selectedID == 201)
        #expect(viewer.capture.session == f.session && viewer.canGoBack)
        viewer.previous()
        try await waitForViewer(viewer)
        #expect(viewer.page?.packets.count == 200 && viewer.selectedID == 1)
        #expect(!viewer.canGoBack && viewer.error == nil)
        viewer.select(2)
        viewer.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewer.contents == nil && !viewer.loadingDetail)
    }

    @MainActor private func waitForViewer(_ viewer: PacketViewerModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while viewer.loading || viewer.loadingDetail {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
