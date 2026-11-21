import Foundation

struct SDPMedia: Sendable {
    var address: String
    let port: Int
    let kind: String
    let profile: String
    let payloads: Set<UInt8>
    var clocks: [UInt8: RTPClock] = [:]
    var direction = "sendrecv"
    var endpoint: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}

struct SIPMessage: Identifiable, Sendable {
    var id: UInt64 { packet.id }
    let packet: InspectedPacket
    let callID: String
    let method: String
    let status: Int?
    let cseq: String
    let fromTag: String
    let toTag: String
    let branch: String
    let complete: Bool
    let media: [SDPMedia]
    var label: String {
        if let status { return "\(status) \(packet.decoded.summary.split(separator: " ").dropFirst(2).joined(separator: " ")) · \(method)" }
        return method
    }

    static func parse(packet: InspectedPacket, text: String) -> SIPMessage {
        let delimiter = text.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
        let parts = text.components(separatedBy: delimiter)
        let lines = parts[0].components(separatedBy: .newlines).filter { !$0.isEmpty }
        var headers: [String: String] = [:], lastName = ""
        let aliases = ["i": "call-id", "f": "from", "t": "to", "v": "via", "c": "content-type", "l": "content-length"]
        var complete = parts.count >= 2 && lines.count <= 512
        for line in lines.dropFirst().prefix(512) {
            if line.first == " " || line.first == "\t" {
                if (headers[lastName]?.count ?? 0) + line.count < 2048 { headers[lastName, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
                else { complete = false }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { complete = false; continue }
            let name = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let key = aliases[name] ?? name
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count > 2048 { complete = false }
            if headers[key] == nil { headers[key] = String(value.prefix(2048)) }
            lastName = key
        }
        let start = lines.first?.split(separator: " ") ?? []
        let status = start.first == "SIP/2.0" && start.count > 1 ? Int(start[1]) : nil
        let cseq = (headers["cseq"] ?? "").split(whereSeparator: \.isWhitespace)
        let method = status == nil ? String(start.first ?? "Unknown") : (cseq.count > 1 ? String(cseq[1]) : "Unknown")
        var body = parts.dropFirst().joined(separator: delimiter)
        if let lengthText = headers["content-length"] {
            if let length = Int(lengthText), length >= 0, length <= 65536 {
                complete = complete && body.utf8.count >= length
                body = String(decoding: body.utf8.prefix(length), as: UTF8.self)
            } else { complete = false; body = "" }
        }
        func tag(_ value: String?, _ parameter: String) -> String {
            let pattern = "(?:^|;)\\s*" + parameter + "=([^;\\s>]+)"
            guard let value, let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let result = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(result.range(at: 1), in: value) else { return "" }
            return String(value[range])
        }
        let media = complete && headers["content-type"]?.lowercased().split(separator: ";").first == "application/sdp" ? parseSDP(body) : []
        return SIPMessage(packet: packet, callID: headers["call-id"] ?? "No Call-ID · packet \(packet.id)", method: method,
                          status: status, cseq: String(cseq.first ?? ""), fromTag: tag(headers["from"], "tag"),
                          toTag: tag(headers["to"], "tag"), branch: tag(headers["via"], "branch"), complete: complete, media: media)
    }

    private static func parseSDP(_ body: String) -> [SDPMedia] {
        var address = "", sessionDirection = "sendrecv", media: [SDPMedia] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
            if line.hasPrefix("c="), words.count >= 3 {
                let ip = String(words[2].split(separator: "/").first ?? "")
                if media.isEmpty { address = ip } else { media[media.count - 1].address = ip }
            } else if line.hasPrefix("m="), words.count >= 4, media.count < 32,
                      let portText = words[1].split(separator: "/").first, let port = Int(portText), (0...65535).contains(port) {
                media.append(SDPMedia(address: address, port: port, kind: words[0], profile: words[2],
                                      payloads: Set(words.dropFirst(3).compactMap(UInt8.init)), direction: sessionDirection))
            } else if line.hasPrefix("a=rtpmap:"), let i = media.indices.last {
                let map = line.dropFirst(9).split(whereSeparator: \.isWhitespace)
                if map.count == 2, let pt = UInt8(map[0]) {
                    let codec = map[1].split(separator: "/")
                    if codec.count >= 2, let rate = Int(codec[1]), (1...1_000_000).contains(rate), media[i].payloads.contains(pt) {
                        media[i].clocks[pt] = RTPClock(rate: rate, codec: String(codec[0]), source: "SDP")
                    }
                }
            } else if ["a=sendonly", "a=recvonly", "a=inactive", "a=sendrecv"].contains(line) {
                if let i = media.indices.last { media[i].direction = String(line.dropFirst(2)) }
                else { sessionDirection = String(line.dropFirst(2)) }
            }
        }
        return media
    }
}

struct CaptureScanProgress: Sendable {
    let read: UInt64
    let size: UInt64
    let packets: UInt64
}

struct CaptureAnalysis: Sendable {
    var messages: [SIPMessage] = []
    var streams: [RTPStreamAnalysis] = []
    var processed: UInt64 = 0
    var complete = false
    var warnings: [String] = []
    var firstTime: PacketTime?
    var lastTime: PacketTime?
    var interfaceEndTimes: [String: PacketTime] = [:]
    var nonmonotonicInterfaces: Set<String> = []
    var undecoded = 0
    var incompleteSIP = 0
    var calls: [String] { Array(Set(messages.map(\.callID))).sorted() }
}

enum CaptureAnalyzer {
    static let maxMessages = 10_000
    static let maxStreams = 128

    /// One streaming pass computes signaling evidence and aggregate media metrics.
    /// Payloads stay in the attachment; only bounded summaries and chart buckets survive.
    static func scan(_ file: URL, only stream: RTPStreamKey? = nil, override: RTPClock? = nil,
                     progress: @Sendable (CaptureScanProgress) -> Void = { _ in }) throws -> CaptureAnalysis {
        var result = CaptureAnalysis(), cursor: PacketCursor?
        var streams: [RTPStreamKey: RTPStreamAnalysis] = [:]
        // Latest receive declaration per endpoint and call. Never apply session-wide SDP
        // mappings to unrelated endpoints; ambiguous mappings remain unknown.
        var declarations: [String: [String: SDPMedia]] = [:]
        var lastProgress = ContinuousClock.now
        var limited = false
        var sipBytes = 0
        repeat {
            try Task.checkCancellation()
            let page = try PacketPageReader.read(file, from: cursor)
            try autoreleasepool {
                for packet in page.packets {
                    try Task.checkCancellation()
                    result.processed += 1
                    if result.firstTime == nil { result.firstTime = packet.time }
                    if let time = packet.time {
                        guard result.interfaceEndTimes[packet.interface] != nil || result.interfaceEndTimes.count < 256 else { limited = true; break }
                        result.lastTime = time
                        if let previous = result.interfaceEndTimes[packet.interface], let delta = time.seconds(since: previous), delta < 0 {
                            result.nonmonotonicInterfaces.insert(packet.interface)
                        }
                        result.interfaceEndTimes[packet.interface] = time
                    }
                    if packet.decoded.protocolName.hasPrefix("SIP") {
                        guard result.messages.count < maxMessages else { limited = true; break }
                        let detail = try PacketPageReader.detail(file, packet: packet)
                        if let text = detail.decoded.text {
                            sipBytes += text.utf8.count
                            guard sipBytes <= 8 * 1024 * 1024 else { limited = true; break }
                            let message = SIPMessage.parse(packet: packet, text: text)
                            result.messages.append(message)
                            if !message.complete || packet.decoded.protocolName == "SIP/TCP" { result.incompleteSIP += 1 }
                            if message.complete {
                                for media in message.media where !media.address.isEmpty {
                                    declarations[media.endpoint, default: [:]][message.callID] = media
                                }
                            }
                        }
                    } else if let rtp = packet.decoded.rtp {
                        let key = RTPStreamKey(packet, rtp)
                        if let stream, stream != key { continue }
                        guard streams[key] != nil || streams.count < maxStreams else { limited = true; break }
                        let offers = declarations[key.destination]?.values.filter { $0.port != 0 && $0.payloads.contains(rtp.payloadType) } ?? []
                        let resolved: RTPClock?
                        if let override { resolved = override }
                        else if offers.count == 1, let offer = offers.first {
                            resolved = offer.clocks[rtp.payloadType] ?? (offer.profile.contains("RTP/") ? RTPClock.avp(rtp.payloadType) : nil)
                        } else if offers.isEmpty { resolved = RTPClock.avp(rtp.payloadType) }
                        else { resolved = nil }
                        if streams[key] == nil { streams[key] = RTPStreamAnalysis(packet: packet, rtp: rtp) }
                        streams[key]?.add(packet, rtp: rtp, clock: resolved)
                    } else if packet.decoded.protocolName == "Unknown" || packet.decoded.summary.contains("fragment") {
                        result.undecoded += 1
                    }
                }
            }
            cursor = page.next
            for warning in page.warnings where !warning.hasPrefix("Metadata scan paused") && !result.warnings.contains(warning) && result.warnings.count < 20 { result.warnings.append(warning) }
            if ContinuousClock.now - lastProgress > .milliseconds(250) || cursor == nil || limited {
                progress(CaptureScanProgress(read: page.readThrough, size: page.fileSize, packets: result.processed))
                lastProgress = .now
            }
            if limited {
                result.warnings.append("Analysis stopped at its evidence budget (\(maxMessages.formatted()) SIP messages, 8 MiB of SIP input, \(maxStreams) media streams, or 256 capture clock domains). Results cover only the processed portion; the Packets view can inspect the rest.")
                break
            }
            result.complete = cursor == nil && page.readThrough == page.fileSize
        } while cursor != nil
        result.streams = streams.values.sorted { $0.firstPacket.id < $1.firstPacket.id }
        if result.undecoded > 0 { result.warnings.append("\(result.undecoded.formatted()) packets had unsupported headers or IP fragments. They were not analyzed.") }
        if result.incompleteSIP > 0 { result.warnings.append("\(result.incompleteSIP.formatted()) SIP packets were incomplete or used TCP. TCP/IP reassembly is not supported; some messages may be absent.") }
        return result
    }
}
