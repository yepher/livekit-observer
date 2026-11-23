import Foundation

/// A media endpoint can send as well as receive. Keep ambiguous/reused endpoints unassigned.
enum CaptureMediaCallMatch: Equatable, Sendable {
    case unmatched, call(String), ambiguous

    var label: String {
        switch self {
        case .unmatched: "No matching call signaling"
        case .call(let id): "SDP match: \(id)"
        case .ambiguous: "Multiple possible calls"
        }
    }

    private func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.unmatched, _): other
        case (_, .unmatched): self
        case (.call(let a), .call(let b)) where a == b: self
        default: .ambiguous
        }
    }

    static func resolve(_ analysis: CaptureAnalysis) -> [RTPStreamKey: Self] {
        struct Endpoint: Hashable { let address: String; let payload: UInt8 }
        let streams = analysis.streams.sorted { $0.firstPacket.id < $1.firstPacket.id }
        let wanted = streams.reduce(into: [String: Set<UInt8>]()) { endpoints, stream in
            endpoints[stream.key.source, default: []].insert(stream.key.payloadType)
            endpoints[stream.key.destination, default: []].insert(stream.key.payloadType)
        }
        var declarations: [Endpoint: Self] = [:]
        let messages = analysis.messages.sorted { $0.id < $1.id }
        var nextMessage = 0
        var matches: [RTPStreamKey: Self] = [:]
        for stream in streams {
            while nextMessage < messages.count, messages[nextMessage].id < stream.firstPacket.id {
                let message = messages[nextMessage]
                for media in message.media {
                    for payload in (wanted[media.endpoint] ?? []).intersection(media.payloads) {
                        let endpoint = Endpoint(address: media.endpoint, payload: payload)
                        declarations[endpoint] = (declarations[endpoint] ?? .unmatched).merging(.call(message.callID))
                    }
                }
                nextMessage += 1
            }
            let source = declarations[Endpoint(address: stream.key.source, payload: stream.key.payloadType)] ?? .unmatched
            let destination = declarations[Endpoint(address: stream.key.destination, payload: stream.key.payloadType)] ?? .unmatched
            matches[stream.key] = source.merging(destination)
        }
        return matches
    }
}

/// One signaling message or one whole directional RTP stream, placed at its first packet.
struct CaptureFlowEvent: Identifiable, Sendable {
    var id: UInt64 { packet.id }
    let packet: InspectedPacket
    let label: String
    var status: Int?
    var stream: RTPStreamKey?
    var packetCount: Int?
    var duration: Double?
    var media: Bool { stream != nil }
    var packetLabel: String { packetCount.map { "\($0.formatted()) packets" } ?? "Packet \(id)" }
    var detail: String {
        var text = "\(packet.decoded.source) → \(packet.decoded.destination) · \(label)"
        if let stream {
            text += "\nSSRC \(String(stream.ssrc, radix: 16)) · PT \(stream.payloadType) · IF \(stream.interface) · \(packetLabel)"
            if let duration, duration.isFinite, duration >= 0 { text += String(format: " · %.2f s", duration) }
            text += "\nFirst packet #\(id)"
        }
        return text + " · " + (packet.time?.text ?? "Unknown time")
    }

    static func make(_ analysis: CaptureAnalysis, callID: String = "", showMedia: Bool = true) -> [Self] {
        var rows = analysis.messages.filter { callID.isEmpty || $0.callID == callID }.map {
            Self(packet: $0.packet, label: $0.label, status: $0.status)
        }
        if showMedia {
            let matches = callID.isEmpty ? [:] : CaptureMediaCallMatch.resolve(analysis)
            for (index, stream) in analysis.streams.sorted(by: { $0.firstPacket.id < $1.firstPacket.id }).enumerated() {
                guard callID.isEmpty || matches[stream.key] == .call(callID) else { continue }
                rows.append(Self(packet: stream.firstPacket,
                                 label: "RTP \(index + 1) · \(stream.clock?.codec ?? "PT \(stream.key.payloadType)")",
                                 stream: stream.key, packetCount: stream.count, duration: stream.duration))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }
}
