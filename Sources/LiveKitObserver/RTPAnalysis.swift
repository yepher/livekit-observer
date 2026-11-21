import Foundation

struct RTPHeader: Sendable {
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payloadType: UInt8
}

struct RTPStreamKey: Hashable, Sendable {
    let source: String
    let destination: String
    let interface: String
    let ssrc: UInt32
    let payloadType: UInt8
    init(_ packet: InspectedPacket, _ rtp: RTPHeader) {
        source = packet.decoded.source; destination = packet.decoded.destination
        interface = packet.interface; ssrc = rtp.ssrc; payloadType = rtp.payloadType
    }
    var label: String { "\(source) → \(destination) · SSRC \(String(ssrc, radix: 16)) · PT \(payloadType) · IF \(interface)" }
}

struct RTPClock: Equatable, Sendable {
    let rate: Int
    let codec: String
    let source: String
    // RFC 3551 Table 4: G.722 deliberately uses an 8 kHz RTP clock.
    static func avp(_ pt: UInt8) -> RTPClock? {
        let values: [UInt8: (String, Int)] = [0: ("PCMU", 8000), 3: ("GSM", 8000), 4: ("G723", 8000),
            5: ("DVI4", 8000), 6: ("DVI4", 16000), 7: ("LPC", 8000), 8: ("PCMA", 8000), 9: ("G722", 8000),
            10: ("L16", 44100), 11: ("L16", 44100), 12: ("QCELP", 8000), 13: ("CN", 8000),
            14: ("MPA", 90000), 15: ("G728", 8000), 16: ("DVI4", 11025), 17: ("DVI4", 22050), 18: ("G729", 8000)]
        return values[pt].map { RTPClock(rate: $0.1, codec: $0.0, source: "RTP/AVP default (verify profile)") }
    }
}

/// A bounded receive window. Gaps are counted after reordering, rather than summed
/// at every jump. Discontinuities and arrivals outside the window make gaps unknown.
struct RTPSequenceWindow: Sendable {
    private var base: Int64?
    private var highest: Int64 = 0
    private var seen: Set<Int64> = []
    private(set) var unique = 0
    private(set) var duplicates = 0
    private(set) var reordered = 0
    private(set) var discontinuities = 0
    private(set) var tooLate = 0
    var gaps: Int? {
        guard let base, discontinuities == 0, tooLate == 0 else { return nil }
        return max(0, Int(highest - base + 1) - unique)
    }
    @discardableResult mutating func add(_ sequence: UInt16) -> Bool {
        guard let start = base else {
            base = Int64(sequence); highest = Int64(sequence); seen.insert(highest); unique = 1; return false
        }
        let delta = Int64(Int16(bitPattern: sequence &- UInt16(truncatingIfNeeded: highest)))
        let value = highest + delta
        if delta > 3000 || delta < -4096 {
            discontinuities += 1; base = value; highest = value; seen = [value]; unique = 1
            return true
        }
        if seen.contains(value) { duplicates += 1; return false }
        if value < highest - 4095 { tooLate += 1; return false }
        if value < highest { reordered += 1 }
        base = min(start, value)
        unique += 1; seen.insert(value)
        if value > highest {
            let previousFloor = highest - 4095
            highest = value
            // Advance the receive window without rescanning its entire set per packet.
            for expired in previousFloor..<(highest - 4095) { seen.remove(expired) }
        }
        return false
    }
}

struct JitterBucket: Identifiable, Sendable {
    let id: UInt64
    var seconds: Double
    var jitterMS: Double?
    var gapMS: Double?
    mutating func merge(_ other: JitterBucket) {
        if let value = other.jitterMS { jitterMS = max(jitterMS ?? value, value) }
        if let value = other.gapMS { gapMS = max(gapMS ?? value, value) }
    }
}

struct RTPStreamAnalysis: Identifiable, Sendable {
    var id: RTPStreamKey { key }
    let key: RTPStreamKey
    let firstPacket: InspectedPacket
    private(set) var lastPacket: InspectedPacket
    private(set) var count = 0
    private(set) var sequence = RTPSequenceWindow()
    private(set) var clock: RTPClock?
    private(set) var clockChanges = 0
    private(set) var unknownClockPackets = 0
    private(set) var timingResets = 0
    private(set) var untimedPackets = 0
    private(set) var peakJitterMS: Double?
    private(set) var peakJitterPacket: InspectedPacket?
    private(set) var peakGapMS: Double?
    private(set) var peakGapPacket: InspectedPacket?
    private(set) var buckets: [JitterBucket] = []
    private var bucketSize = 1
    private var bucketCount = 0
    private var pendingBucket: JitterBucket?
    private var previousTime: PacketTime?
    private var previousTimestamp: UInt32?
    private var previousClock: RTPClock?
    private var chartOrigin: PacketTime?
    private var jitter = 0.0
    private var jitterSum = 0.0
    private var jitterCount = 0
    var meanJitterMS: Double? { jitterCount > 0 ? jitterSum / Double(jitterCount) : nil }
    var duration: Double? { lastPacket.time.flatMap { end in firstPacket.time.flatMap { end.seconds(since: $0) } } }
    var chart: [JitterBucket] { buckets + (pendingBucket.map { [$0] } ?? []) }

    init(packet: InspectedPacket, rtp: RTPHeader) {
        key = RTPStreamKey(packet, rtp); firstPacket = packet; lastPacket = packet
    }

    mutating func add(_ packet: InspectedPacket, rtp: RTPHeader, clock resolved: RTPClock?) {
        count += 1; lastPacket = packet
        let restarted = sequence.add(rtp.sequence)
        if resolved == nil { unknownClockPackets += 1 }
        if let previousClock, let resolved, previousClock.rate != resolved.rate { clockChanges += 1 }
        clock = resolved
        var gap: Double?, measured: Double?
        if let time = packet.time, let previousTime, let delta = time.seconds(since: previousTime) {
            if delta >= 0 {
                gap = delta * 1000
                if gap! > (peakGapMS ?? -1) { peakGapMS = gap; peakGapPacket = packet }
                if let resolved, resolved.rate > 0, previousClock?.rate == resolved.rate,
                   let previousTimestamp, !restarted {
                    let ticks = Int32(bitPattern: rtp.timestamp &- previousTimestamp)
                    let senderDelta = Double(ticks) / Double(resolved.rate)
                    // A huge timestamp jump is a new/unknown timing segment, not enormous jitter.
                    if abs(senderDelta) <= max(60, delta + 60) {
                        let variation = abs(delta - senderDelta) * 1000
                        jitter += (variation - jitter) / 16 // RFC 3550 §6.4.1, arrival order.
                        measured = jitter; jitterSum += jitter; jitterCount += 1
                        if jitter > (peakJitterMS ?? -1) { peakJitterMS = jitter; peakJitterPacket = packet }
                    } else { timingResets += 1; jitter = 0 }
                } else { jitter = 0 }
            } else { timingResets += 1; jitter = 0 }
        }
        if packet.time == nil { untimedPackets += 1; jitter = 0 }
        previousTime = packet.time; previousTimestamp = rtp.timestamp; previousClock = resolved
        if chartOrigin == nil { chartOrigin = packet.time }
        if let time = packet.time, let firstTime = chartOrigin, let seconds = time.seconds(since: firstTime), seconds >= 0 {
            let point = JitterBucket(id: packet.id, seconds: seconds, jitterMS: measured, gapMS: gap)
            if pendingBucket == nil { pendingBucket = point } else { pendingBucket?.merge(point) }
            bucketCount += 1
            if bucketCount >= bucketSize {
                buckets.append(pendingBucket!); pendingBucket = nil; bucketCount = 0
                if buckets.count >= 512 {
                    buckets = stride(from: 0, to: buckets.count, by: 2).map { index in
                        var combined = buckets[index]; combined.merge(buckets[index + 1]); return combined
                    }
                    bucketSize *= 2
                }
            }
        }
    }
}
