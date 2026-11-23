import ObserverCore
import Foundation

struct PacketTime: Sendable, Equatable {
    let ticks: UInt64
    let unitsPerSecond: UInt64
    var offsetSeconds: Int64 = 0

    func seconds(since other: PacketTime) -> Double? {
        guard unitsPerSecond > 0, other.unitsPerSecond > 0,
              ticks / unitsPerSecond <= UInt64(Int64.max), other.ticks / other.unitsPerSecond <= UInt64(Int64.max) else { return nil }
        let a = Int64(ticks / unitsPerSecond).addingReportingOverflow(offsetSeconds)
        let b = Int64(other.ticks / other.unitsPerSecond).addingReportingOverflow(other.offsetSeconds)
        let delta = a.partialValue.subtractingReportingOverflow(b.partialValue)
        guard !a.overflow, !b.overflow, !delta.overflow else { return nil }
        return Double(delta.partialValue) + Double(ticks % unitsPerSecond) / Double(unitsPerSecond)
            - Double(other.ticks % other.unitsPerSecond) / Double(other.unitsPerSecond)
    }

    /// Absolute capture time, including PCAPNG interface resolution and timestamp offset.
    var date: Date? {
        guard let seconds = seconds(since: PacketTime(ticks: 0, unitsPerSecond: 1)),
              seconds >= -62_135_596_800, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    var text: String {
        guard unitsPerSecond > 0 else { return "Unknown timestamp resolution" }
        let whole = ticks / unitsPerSecond
        guard whole <= UInt64(Int64.max) else { return "Timestamp outside display range" }
        let (seconds, overflow) = Int64(whole).addingReportingOverflow(offsetSeconds)
        guard !overflow, seconds >= -62_135_596_800, seconds <= 253_402_300_799 else { return "Timestamp outside display range" }
        let product = (ticks % unitsPerSecond).multipliedFullWidth(by: 1_000_000_000)
        let fraction = UInt32(unitsPerSecond.dividingFullWidth(product).quotient)
        let date = Date(timeIntervalSince1970: Double(seconds)).formatted(.iso8601)
        return String(date.dropLast()) + String(format: ".%09uZ", fraction)
    }
}

struct PacketInterface: Sendable {
    let linkType: UInt32
    let snapLength: UInt32
    var unitsPerSecond: UInt64? = 1_000_000
    var offsetSeconds: Int64 = 0
}

struct PacketCursor: Sendable {
    let format: PacketCapture.Format
    var offset: UInt64
    var packetNumber: UInt64 = 0
    var littleEndian = true
    var section = -1
    var interfaces: [PacketInterface] = []
}

struct InspectedPacket: Identifiable, Sendable {
    let id: UInt64
    let offset: UInt64
    let capturedLength: UInt32
    let originalLength: UInt32
    let linkType: UInt32
    let interface: String
    let time: PacketTime?
    let decoded: PacketHeaders
}

struct PacketPage: Sendable {
    let packets: [InspectedPacket]
    let next: PacketCursor?
    let fileSize: UInt64
    let readThrough: UInt64
    let warnings: [String]
}

/// Reads just the requested page. Packet bytes stay in the managed capture, and a page
/// retains only summaries. No full-file read, scan, or packet-count-proportional allocation.
enum PacketPageReader {
    static let pageSize = 200
    static let previewBytes = 512

    static func read(_ file: URL, from cursor: PacketCursor? = nil, limit: Int = pageSize) throws -> PacketPage {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var state: PacketCursor
        if let cursor { state = cursor }
        else {
            let format = try CaptureHeader.inspect(file)
            state = PacketCursor(format: format, offset: format == .pcap ? 24 : 0)
            if format == .pcap {
                let h = try bytes(handle, at: 0, count: 24)
                state.littleEndian = h[0] == 0xd4 || h[0] == 0x4d
                let nano = h[0] == 0x4d || h[2] == 0x3c
                state.interfaces = [PacketInterface(linkType: UInt32(number(h, 20, 4, state.littleEndian)) & 0xffff,
                                                    snapLength: UInt32(number(h, 16, 4, state.littleEndian)),
                                                    unitsPerSecond: nano ? 1_000_000_000 : 1_000_000)]
            }
        }
        var packets: [InspectedPacket] = [], warnings: [String] = []
        var failed = false, blocks = 0
        do {
            guard state.offset <= size else { throw CaptureError.message("The capture has changed or was truncated. Reopen it to start again.") }
            while state.offset < size && packets.count < min(200, max(1, limit)) && blocks < 10_000 {
                try Task.checkCancellation()
                blocks += 1
                // Drain Foundation's temporary buffers once per record, including skipped blocks.
                try autoreleasepool {
                    if state.format == .pcap {
                        guard size - state.offset >= 16 else { throw CaptureError.message("Truncated PCAP packet header.") }
                        let h = try bytes(handle, at: state.offset, count: 16)
                        let sec = number(h, 0, 4, state.littleEndian), fraction = number(h, 4, 4, state.littleEndian)
                        let cap = UInt32(number(h, 8, 4, state.littleEndian)), original = UInt32(number(h, 12, 4, state.littleEndian))
                        let interface = state.interfaces[0], units = interface.unitsPerSecond!
                        guard fraction < units else { throw CaptureError.message("Invalid PCAP timestamp fraction.") }
                        let payload = state.offset + 16
                        try validate(cap, original, interface.snapLength, available: size - payload)
                        state.packetNumber += 1
                        packets.append(try packet(handle, number: state.packetNumber, offset: payload, cap: cap, original: original,
                                                  interface: interface, label: "0", time: PacketTime(ticks: sec * units + fraction, unitsPerSecond: units)))
                        state.offset = payload + UInt64(cap)
                        return
                    }

                    // PCAPNG block lengths are interpreted with the section's byte order.
                    // A new section establishes its own byte order before its length is read.
                    guard size - state.offset >= 12 else { throw CaptureError.message("Truncated PCAPNG block header.") }
                    let h = try bytes(handle, at: state.offset, count: 12)
                    let section = h.prefix(4).elementsEqual([0x0a, 0x0d, 0x0d, 0x0a])
                    if section {
                        let bom = Array(h[8..<12])
                        guard bom == [0x4d, 0x3c, 0x2b, 0x1a] || bom == [0x1a, 0x2b, 0x3c, 0x4d] else {
                            throw CaptureError.message("Invalid PCAPNG byte-order marker.")
                        }
                        state.littleEndian = bom[0] == 0x4d
                    }
                    let little = state.littleEndian
                    let type = number(h, 0, 4, little), length = number(h, 4, 4, little)
                    guard length >= 12, length % 4 == 0, length <= size - state.offset else {
                        throw CaptureError.message("Invalid or truncated PCAPNG block length.")
                    }
                    let end = state.offset + length
                    guard try number(bytes(handle, at: end - 4, count: 4), 0, 4, little) == length else {
                        throw CaptureError.message("PCAPNG block lengths do not match.")
                    }
                    if section {
                        guard length >= 28 else { throw CaptureError.message("Truncated PCAPNG section.") }
                        let version = try bytes(handle, at: state.offset + 12, count: 4)
                        guard number(version, 0, 2, little) == 1, number(version, 2, 2, little) == 0 else {
                            throw CaptureError.message("Unsupported PCAPNG section version.")
                        }
                        state.section += 1
                        state.interfaces = []
                    } else if type == 1 {
                        guard length >= 20, state.interfaces.count < 256 else {
                            throw CaptureError.message("Invalid interface block or more than 256 interfaces in a section.")
                        }
                        let b = try bytes(handle, at: state.offset + 8, count: 8)
                        var interface = PacketInterface(linkType: UInt32(number(b, 0, 2, little)), snapLength: UInt32(number(b, 4, 4, little)))
                        var option = state.offset + 16, optionCount = 0
                        while option < end - 4 {
                            try Task.checkCancellation()
                            guard end - 4 - option >= 4, optionCount < 4096 else { throw CaptureError.message("Invalid or excessive PCAPNG interface options.") }
                            optionCount += 1
                            let o = try bytes(handle, at: option, count: 4)
                            let code = number(o, 0, 2, little), count = number(o, 2, 2, little)
                            option += 4
                            if code == 0 {
                                guard count == 0 else { throw CaptureError.message("Invalid end-of-options marker.") }
                                break
                            }
                            let padded = (count + 3) & ~UInt64(3)
                            guard padded <= end - 4 - option else { throw CaptureError.message("Truncated interface option.") }
                            if code == 9 {
                                guard count == 1 else { throw CaptureError.message("Invalid timestamp-resolution option.") }
                                let resolution = try bytes(handle, at: option, count: 1)[0]
                                let power = Int(resolution & 0x7f)
                                if resolution & 0x80 != 0 { interface.unitsPerSecond = power < 64 ? UInt64(1) << power : nil }
                                else if power <= 19 { interface.unitsPerSecond = (0..<power).reduce(UInt64(1)) { n, _ in n * 10 } }
                                else { interface.unitsPerSecond = nil }
                            } else if code == 14 {
                                guard count == 8 else { throw CaptureError.message("Invalid timestamp-offset option.") }
                                interface.offsetSeconds = Int64(bitPattern: try number(bytes(handle, at: option, count: 8), 0, 8, little))
                            }
                            option += padded
                        }
                        state.interfaces.append(interface)
                    } else if type == 6 || type == 2 {
                        guard length >= 32 else { throw CaptureError.message("Truncated PCAPNG packet block.") }
                        let b = try bytes(handle, at: state.offset + 8, count: 20)
                        let index = Int(number(b, 0, type == 2 ? 2 : 4, little))
                        guard state.interfaces.indices.contains(index) else { throw CaptureError.message("Packet references an unknown capture interface.") }
                        let interface = state.interfaces[index]
                        let ticks = (number(b, 4, 4, little) << 32) | number(b, 8, 4, little)
                        let cap = UInt32(number(b, 12, 4, little)), original = UInt32(number(b, 16, 4, little))
                        try validate(cap, original, interface.snapLength, available: length - 32)
                        guard ((UInt64(cap) + 3) & ~UInt64(3)) <= length - 32 else { throw CaptureError.message("Truncated packet padding.") }
                        let time = interface.unitsPerSecond.map { PacketTime(ticks: ticks, unitsPerSecond: $0, offsetSeconds: interface.offsetSeconds) }
                        state.packetNumber += 1
                        packets.append(try packet(handle, number: state.packetNumber, offset: state.offset + 28, cap: cap, original: original,
                                                  interface: interface, label: "\(state.section):\(index)", time: time))
                    } else if type == 3 {
                        guard length >= 16, let interface = state.interfaces.first else { throw CaptureError.message("Simple packet block has no interface or is truncated.") }
                        let original = UInt32(number(h, 8, 4, little))
                        let cap = interface.snapLength == 0 ? original : min(original, interface.snapLength)
                        guard ((UInt64(cap) + 3) & ~UInt64(3)) == length - 16 else { throw CaptureError.message("Invalid simple packet block length.") }
                        state.packetNumber += 1
                        packets.append(try packet(handle, number: state.packetNumber, offset: state.offset + 12, cap: cap, original: original,
                                                  interface: interface, label: "\(state.section):0", time: nil))
                    }
                    state.offset = end
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { failed = true; warnings.append("Stopped at byte \(state.offset): \(error.localizedDescription)") }
        if packets.contains(where: { $0.time == nil }) { warnings.append("Some packets have no supported capture timestamp; their times are unknown.") }
        if blocks == 10_000 && packets.count < limit { warnings.append("Metadata scan paused after 10,000 blocks. Next continues from this position.") }
        return PacketPage(packets: packets, next: !failed && state.offset < size ? state : nil,
                          fileSize: size, readThrough: state.offset, warnings: warnings)
    }

    static func detail(_ file: URL, packet: InspectedPacket) throws -> PacketContents {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try bytes(handle, at: packet.offset, count: min(Int(packet.capturedLength), 65_536))
        return PacketContents(bytes: data, decoded: PacketHeaders.decode(data, linkType: packet.linkType), capturedLength: packet.capturedLength)
    }

    private static func validate(_ cap: UInt32, _ original: UInt32, _ snap: UInt32, available: UInt64) throws {
        guard cap <= original, (snap == 0 || cap <= snap), UInt64(cap) <= available else {
            throw CaptureError.message("Invalid or truncated captured packet length.")
        }
    }

    private static func packet(_ handle: FileHandle, number: UInt64, offset: UInt64, cap: UInt32, original: UInt32,
                               interface: PacketInterface, label: String, time: PacketTime?) throws -> InspectedPacket {
        let data = try bytes(handle, at: offset, count: min(Int(cap), previewBytes))
        let decoded = PacketHeaders.decode(data, linkType: interface.linkType, includeText: false)
        return InspectedPacket(id: number, offset: offset, capturedLength: cap, originalLength: original,
                               linkType: interface.linkType, interface: label, time: time, decoded: decoded)
    }

    private static func bytes(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CaptureError.message("The capture ended before the requested bytes could be read.") }
        return Array(data)
    }

    static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int, _ little: Bool = false) -> UInt64 {
        let range = offset..<(offset + count)
        return (little ? Array(range.reversed()) : Array(range)).reduce(0) { ($0 << 8) | UInt64(bytes[$1]) }
    }
}

struct PacketContents: Sendable {
    let bytes: [UInt8]
    let decoded: PacketHeaders
    let capturedLength: UInt32
    var hex: String {
        stride(from: 0, to: min(bytes.count, 4096), by: 16).map { start in
            let line = Array(bytes[start..<min(start + 16, bytes.count)])
            let hex = line.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(line.map { $0 >= 32 && $0 <= 126 ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%06x  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
}

struct PacketHeaders: Sendable {
    var source = "—"
    var destination = "—"
    var protocolName = "Unknown"
    var summary = "Unsupported or incomplete packet header"
    var fields: [String] = []
    var text: String?
    var rtp: RTPHeader?

    /// Packet-level inspection only. TCP/IP reassembly and dialog-wide diagnosis are separate work.
    static func decode(_ b: [UInt8], linkType: UInt32, includeText: Bool = true) -> PacketHeaders {
        var out = PacketHeaders()
        func n(_ i: Int, _ count: Int = 2) -> UInt64 { PacketPageReader.number(b, i, count) }
        var ip = 0, etherType: UInt64 = 0
        switch linkType {
        case 1:
            guard b.count >= 14 else { return out }
            ip = 14; etherType = n(12)
            for _ in 0..<2 where etherType == 0x8100 || etherType == 0x88a8 {
                guard b.count >= ip + 4 else { return out }
                etherType = n(ip + 2); ip += 4
            }
        case 113:
            guard b.count >= 16 else { return out }; ip = 16; etherType = n(14)
        case 276:
            guard b.count >= 20 else { return out }; ip = 20; etherType = n(0)
        case 0, 108:
            guard b.count >= 5 else { return out }; ip = 4
        case 101, 12, 228, 229: break
        default: out.summary = "Link type \(linkType) is not decoded"; return out
        }
        guard etherType == 0 || etherType == 0x0800 || etherType == 0x86dd else {
            out.protocolName = etherType == 0x0806 ? "ARP" : "Link"
            out.summary = String(format: "EtherType 0x%04x", UInt32(etherType)); return out
        }
        guard b.count > ip else { return out }
        var transport: Int, proto: UInt64, end: Int
        if b[ip] >> 4 == 4 {
            guard b.count >= ip + 20 else { return out }
            let ihl = Int(b[ip] & 0x0f) * 4, length = Int(n(ip + 2))
            guard ihl >= 20, length >= ihl, b.count >= ip + ihl else { return out }
            out.source = b[(ip + 12)..<(ip + 16)].map(String.init).joined(separator: ".")
            out.destination = b[(ip + 16)..<(ip + 20)].map(String.init).joined(separator: ".")
            out.protocolName = "IPv4"
            guard n(ip + 6) & 0x3fff == 0 else { out.summary = "IP fragment; reassembly required"; return out }
            transport = ip + ihl; proto = UInt64(b[ip + 9]); end = min(b.count, ip + length)
        } else if b[ip] >> 4 == 6 {
            guard b.count >= ip + 40 else { return out }
            func address(_ i: Int) -> String { stride(from: i, to: i + 16, by: 2).map { String(n($0), radix: 16) }.joined(separator: ":") }
            out.source = address(ip + 8); out.destination = address(ip + 24); out.protocolName = "IPv6"
            transport = ip + 40; proto = UInt64(b[ip + 6]); end = min(b.count, ip + 40 + Int(n(ip + 4)))
            for _ in 0..<8 where [0, 43, 60, 51].contains(proto) {
                guard transport + 2 <= end else { return out }
                let length = proto == 51 ? (Int(b[transport + 1]) + 2) * 4 : (Int(b[transport + 1]) + 1) * 8
                guard transport + length <= end else { return out }
                proto = UInt64(b[transport]); transport += length
            }
            if proto == 44 { out.summary = "IPv6 fragment; reassembly required"; return out }
        } else { return out }
        out.summary = "IP protocol \(proto)"
        guard proto == 17 || proto == 6 else { return out }
        guard transport + (proto == 17 ? 8 : 20) <= end else { out.summary = "Truncated transport header"; return out }
        let src = n(transport), dst = n(transport + 2)
        out.source = out.source.contains(":") ? "[\(out.source)]:\(src)" : "\(out.source):\(src)"
        out.destination = out.destination.contains(":") ? "[\(out.destination)]:\(dst)" : "\(out.destination):\(dst)"
        var payload: Int
        if proto == 17 {
            let length = Int(n(transport + 4))
            guard length >= 8 else { return out }
            end = min(end, transport + length); payload = transport + 8
            out.protocolName = "UDP"; out.summary = "UDP \(src) → \(dst)"
        } else {
            let length = Int(b[transport + 12] >> 4) * 4
            guard length >= 20, transport + length <= end else { return out }
            payload = transport + length; out.protocolName = "TCP"
            out.summary = "TCP seq \(n(transport + 4, 4)) · ack \(n(transport + 8, 4))"
            out.fields.append("TCP packet payload only; messages split across packets are not reassembled.")
        }
        guard payload < end else { return out }
        // Avoid UTF-8 decoding and regex work for every media packet during a scan.
        if (65...90).contains(b[payload]) {
            let text = String(decoding: b[payload..<end], as: UTF8.self)
            let firstLine = String(text.prefix(while: { !$0.isNewline }))
            let response = firstLine.range(of: #"^SIP/2\.0 [1-6][0-9]{2}( |$)"#, options: .regularExpression) != nil
            let request = firstLine.range(of: #"^[A-Z]{3,12} \S+ SIP/2\.0$"#, options: .regularExpression) != nil
            if response || request {
                out.protocolName = proto == 17 ? "SIP" : "SIP/TCP"
                out.summary = String(firstLine.prefix(160))
                if includeText { out.text = text }
                out.fields.append("SIP/SDP bytes from this packet; no dialog-wide conclusions are inferred.")
                return out
            }
        }
        guard proto == 17, end - payload >= 4, b[payload] >> 6 == 2 else { return out }
        if (192...223).contains(b[payload + 1]) {
            out.protocolName = "RTCP?"; out.summary = "RTCP header candidate · type \(b[payload + 1])"
            out.fields.append("RTCP block length: \((n(payload + 2) + 1) * 4) bytes")
            return out
        }
        guard end - payload >= 12 else { return out }
        let headerLength = 12 + Int(b[payload] & 0x0f) * 4
        guard end - payload >= headerLength else { return out }
        let pt = b[payload + 1] & 0x7f, seq = n(payload + 2), timestamp = n(payload + 4, 4), ssrc = n(payload + 8, 4)
        out.rtp = RTPHeader(sequence: UInt16(seq), timestamp: UInt32(timestamp), ssrc: UInt32(ssrc), payloadType: pt)
        out.protocolName = "RTP?"
        out.summary = "PT \(pt) · seq \(seq) · SSRC " + String(format: "0x%08x", UInt32(ssrc))
        out.fields += ["RTP header candidate; codec and media association require negotiated SDP.",
                       "Payload type: \(pt)", "Sequence: \(seq)", "RTP timestamp: \(timestamp)",
                       "SSRC: " + String(format: "0x%08x", UInt32(ssrc)), "Marker: \(b[payload + 1] & 0x80 != 0 ? "yes" : "no")"]
        return out
    }
}
