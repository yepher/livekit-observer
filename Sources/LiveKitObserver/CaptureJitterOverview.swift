import Foundation

/// A bounded, shared-clock projection of the analyzer's already bounded stream summaries.
/// Building it once per scan avoids repeating timestamp conversion and SIP matching on redraw.
struct CaptureJitterOverview: Sendable {
    static let pageSize = 8
    static let maximumPoints = 129

    struct Series: Identifiable, Sendable {
        var id: RTPStreamKey { key }
        let key: RTPStreamKey
        let number: Int
        let call: String
        let codec: String
        let points: [JitterBucket]
        let timed: Bool
        let peakJitterMS: Double?
        let peakGapMS: Double?
        var label: String { "Stream \(number)" }
    }

    let origin: PacketTime?
    let timeDomain: ClosedRange<Double>
    let series: [Series]
    var pageCount: Int { max(1, (series.count + Self.pageSize - 1) / Self.pageSize) }
    func page(_ index: Int) -> [Series] {
        Array(series.dropFirst(max(0, min(index, pageCount - 1)) * Self.pageSize).prefix(Self.pageSize))
    }

    init(_ analysis: CaptureAnalysis) {
        let streams = analysis.streams.sorted { $0.firstPacket.id < $1.firstPacket.id }
        let origin = ([analysis.firstTime] + streams.map(\.chartStart)).compactMap { $0 }.first { $0.seconds(since: $0) != nil }
        self.origin = origin
        var low = 0.0, high = 0.0
        var rows: [Series] = []

        // Resolve only endpoints present in this capture's bounded stream list, in packet order.
        // Reused/ambiguous SDP endpoints stay ambiguous rather than guessing call ownership.
        struct Endpoint: Hashable { let address: String; let payload: UInt8 }
        enum Association { case call(String), ambiguous }
        let wanted = streams.reduce(into: [String: Set<UInt8>]()) { $0[$1.key.destination, default: []].insert($1.key.payloadType) }
        var associations: [Endpoint: Association] = [:]
        let messages = analysis.messages.sorted { $0.id < $1.id }
        var nextMessage = 0
        for (index, stream) in streams.enumerated() {
            while nextMessage < messages.count, messages[nextMessage].id < stream.firstPacket.id {
                let message = messages[nextMessage]
                for media in message.media {
                    for payload in (wanted[media.endpoint] ?? []).intersection(media.payloads) {
                        let endpoint = Endpoint(address: media.endpoint, payload: payload)
                        switch associations[endpoint] {
                        case .none: associations[endpoint] = .call(message.callID)
                        case .call(let previous) where previous != message.callID: associations[endpoint] = .ambiguous
                        default: break
                        }
                    }
                }
                nextMessage += 1
            }
            let call: String
            switch associations[Endpoint(address: stream.key.destination, payload: stream.key.payloadType)] {
            case .call(let id): call = "SDP match: \(id)"
            case .ambiguous: call = "Multiple possible calls"
            case .none: call = "No matching call signaling"
            }
            let offset = origin.flatMap { origin in stream.chartStart?.seconds(since: origin) }
            let chart = stream.chart
            var points: [JitterBucket] = []
            if let offset, offset.isFinite {
                let step = max(1, (chart.count + Self.maximumPoints - 1) / Self.maximumPoints)
                for start in stride(from: 0, to: chart.count, by: step) {
                    var bucket = chart[start]
                    for index in (start + 1)..<min(start + step, chart.count) { bucket.merge(chart[index]) }
                    bucket.seconds += offset
                    guard bucket.seconds.isFinite else { continue }
                    points.append(bucket)
                    low = min(low, bucket.seconds); high = max(high, bucket.seconds)
                }
                low = min(low, offset); high = max(high, offset)
                if let end = origin.flatMap({ stream.lastPacket.time?.seconds(since: $0) }), end.isFinite {
                    low = min(low, end); high = max(high, end)
                }
            }
            rows.append(Series(key: stream.key, number: index + 1, call: call, codec: stream.clock?.codec ?? "Unknown clock",
                               points: points, timed: offset?.isFinite == true, peakJitterMS: stream.peakJitterMS, peakGapMS: stream.peakGapMS))
        }
        if let end = origin.flatMap({ analysis.lastTime?.seconds(since: $0) }), end.isFinite {
            low = min(low, end); high = max(high, end)
        }
        timeDomain = low...max(high, low + 0.001)
        series = rows
    }

    /// Autoscale around finite observations while keeping the quality thresholds fixed.
    static func valueDomain(_ values: [Double?]) -> ClosedRange<Double> {
        let values = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let span = high - low
        let padding = span > 0.001 ? max(span * 0.1, 0.001) : max(high * 0.01, 0.001)
        return max(0, low - padding)...(high + padding)
    }
}
