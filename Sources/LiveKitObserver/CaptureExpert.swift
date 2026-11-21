import Foundation

struct CaptureFinding: Identifiable, Sendable {
    enum Severity: Int, Sendable { case information, warning, error }
    let rule: String
    let severity: Severity
    let title: String
    let observation: String
    let explanation: String
    let nextCheck: String
    let callID: String?
    let evidence: InspectedPacket
    var stream: RTPStreamKey?
    var id: String { "\(rule):\(evidence.id):\(observation)" }
}

enum CaptureExpert {
    static func findings(_ analysis: CaptureAnalysis, jitterThreshold: Double = 30, gapThreshold: Double = 100) -> [CaptureFinding] {
        var findings: [CaptureFinding] = []
        let calls = Dictionary(grouping: analysis.messages, by: \.callID)
        for (callID, messages) in calls {
            var seen: Set<String> = []
            for message in messages {
                if let status = message.status, status >= 400 {
                    let key = "\(status):\(message.method):\(message.packet.decoded.source)"
                    guard seen.insert(key).inserted else { continue }
                    let description: String
                    let check: String
                    let severity: CaptureFinding.Severity
                    switch status {
                    case 401, 407:
                        description = "Authentication challenge observed. A challenge is a normal part of many SIP exchanges and does not by itself mean authentication failed."
                        check = "Check for an authenticated retry and its final response."
                        severity = .information
                    case 403:
                        description = "The responding endpoint refused this request. Credentials, authorization, policy or routing can cause a refusal; the response alone does not establish which."
                        check = "Inspect the response origin and the corresponding server or trunk logs."
                        severity = .error
                    case 404:
                        description = "The responding endpoint reported that the target was not found. This does not establish that a LiveKit dispatch rule is missing."
                        check = "Check the Request-URI, called number, routing and logs at the responding hop."
                        severity = .error
                    case 408:
                        description = "A request timeout was reported by this endpoint."
                        check = "Trace the request through each hop and check responses, reachability and server logs."
                        severity = .warning
                    case 486, 600:
                        description = "The endpoint reported busy. This is an observed call outcome, not proof of a network fault."
                        check = "Check endpoint availability and call-handling policy."
                        severity = .information
                    case 487:
                        description = "The request was terminated. A successful CANCEL response is not a successful INVITE response."
                        check = "Look for the matching CANCEL or BYE and the reason the caller or intermediary ended the request."
                        severity = .information
                    case 488, 606:
                        description = "The session description was not acceptable to the responding endpoint. Codec or media constraints are possible causes."
                        check = "Compare the offered SDP with this endpoint's supported media and its rejection logs."
                        severity = .error
                    case 503:
                        description = "The responding service reported unavailability. Overload or maintenance are possible causes."
                        check = "Inspect Retry-After, service capacity, upstream dependencies and logs at this hop."
                        severity = .error
                    default:
                        description = "A final SIP failure response was observed for this transaction; another branch or later attempt may still succeed."
                        check = "Inspect the response, its CSeq method, the responding hop and any subsequent retry."
                        severity = status >= 500 ? .error : .warning
                    }
                    findings.append(CaptureFinding(rule: "sip.response.\(status)", severity: severity,
                        title: "\(status) response to \(message.method)", observation: "Observed in packet \(message.id), from \(message.packet.decoded.source).",
                        explanation: description, nextCheck: check, callID: callID, evidence: message.packet))
                }
                for media in message.media where media.kind == "audio" && (media.port == 0 || media.address == "0.0.0.0" || media.direction == "inactive" || media.direction == "sendonly") {
                    let key = "sdp:\(media.endpoint):\(media.direction)"
                    if seen.insert(key).inserted {
                        findings.append(CaptureFinding(rule: "sdp.media-state", severity: .information,
                            title: media.port == 0 ? "Audio section disabled in SDP" : "Hold or restricted media direction in SDP",
                            observation: "Observed \(media.endpoint), direction \(media.direction), in packet \(message.id).",
                            explanation: "Port zero rejects/disables a media section. Hold addresses and direction attributes can be intentional; they are not independently proof of negotiation failure.",
                            nextCheck: "Compare this offer/answer with the intended hold state and later SDP updates.", callID: callID, evidence: message.packet))
                    }
                }
            }
            let requests = messages.filter { $0.status == nil && !$0.branch.isEmpty && $0.complete && $0.packet.decoded.protocolName == "SIP" }
            let groups = Dictionary(grouping: requests) { "\($0.method)|\($0.cseq)|\($0.branch)|\($0.fromTag)|\($0.toTag)|\($0.packet.decoded.source)|\($0.packet.decoded.destination)" }
            for group in groups.values where group.count >= 3 {
                let first = group[0]
                findings.append(CaptureFinding(rule: "sip.repeated-request", severity: .warning,
                    title: "Repeated \(first.method) request", observation: "\(group.count) packets share the transaction, direction and CSeq; first seen in packet \(first.id).",
                    explanation: "Possible SIP retransmissions. Duplicate capture points or duplicate packets can look the same; repeated requests do not prove downstream loss.",
                    nextCheck: "Compare packet bytes and timing, then check whether responses reached this hop.", callID: callID, evidence: first.packet))
            }
            // Absence checks need complete UDP message coverage, matching dialog tags and
            // transaction sequence, and a visible five-second observation window.
            if analysis.complete && analysis.incompleteSIP == 0 && analysis.undecoded == 0 {
                var ackChecks: Set<String> = []
                for response in messages where response.status.map({ (200..<300).contains($0) }) == true && response.method == "INVITE" && response.complete {
                    guard !response.toTag.isEmpty, !response.fromTag.isEmpty, !response.cseq.isEmpty,
                          !analysis.nonmonotonicInterfaces.contains(response.packet.interface),
                          let time = response.packet.time, let end = analysis.interfaceEndTimes[response.packet.interface],
                          let elapsed = end.seconds(since: time), elapsed >= 5 else { continue }
                    let key = "\(response.fromTag)|\(response.toTag)|\(response.cseq)|\(response.packet.decoded.source)|\(response.packet.decoded.destination)"
                    guard ackChecks.insert(key).inserted else { continue }
                    let ack = messages.contains { message in
                        message.status == nil && message.method == "ACK" && message.cseq == response.cseq && message.fromTag == response.fromTag
                        && message.toTag == response.toTag && message.packet.decoded.source == response.packet.decoded.destination
                        && message.packet.decoded.destination == response.packet.decoded.source && message.id > response.id
                    }
                    if !ack {
                        findings.append(CaptureFinding(rule: "sip.ack-not-observed", severity: .warning,
                            title: "ACK not observed for INVITE success", observation: "No matching ACK was captured on this hop after packet \(response.id); at least five seconds of capture follow it.",
                            explanation: "Possible incomplete handshake. The ACK may take another route or be absent at this capture point; this is not proof it was never sent.",
                            nextCheck: "Check both endpoints and intermediaries using the Call-ID, dialog tags and INVITE CSeq.", callID: callID, evidence: response.packet))
                    }
                }
            }
        }
        for stream in analysis.streams where stream.count >= 2 {
            func add(_ rule: String, _ severity: CaptureFinding.Severity, _ title: String, _ observation: String, _ explanation: String, _ check: String, packet: InspectedPacket? = nil) {
                findings.append(CaptureFinding(rule: rule, severity: severity, title: title, observation: observation,
                    explanation: explanation, nextCheck: check, callID: nil, evidence: packet ?? stream.firstPacket, stream: stream.key))
            }
            if let jitter = stream.peakJitterMS, jitter > jitterThreshold {
                add("rtp.jitter", .warning, "Elevated RTP jitter", "Peak \(String(format: "%.2f", jitter)) ms exceeds the \(String(format: "%.1f", jitterThreshold)) ms review threshold.",
                    "Measured interarrival jitter at this capture point, using the selected RTP clock. This threshold is a heuristic and does not establish what a listener heard.",
                    "Verify the codec clock and compare with receiver jitter-buffer statistics and network timing.", packet: stream.peakJitterPacket)
            }
            if let gap = stream.peakGapMS, gap > gapThreshold {
                add("rtp.arrival-gap", .warning, "Long interval between RTP packets", "Largest captured arrival interval: \(String(format: "%.2f", gap)) ms (review threshold \(String(format: "%.1f", gapThreshold)) ms).",
                    "Possible delivery stall, silence suppression, stream pause or capture gap. The interval alone does not prove media loss.",
                    "Inspect surrounding packets, RTP timestamps, codec/DTX behavior and receiver logs.", packet: stream.peakGapPacket)
            }
            if let gaps = stream.sequence.gaps, gaps > 0 {
                add("rtp.sequence-gaps", .warning, "RTP sequence gaps remain", "\(gaps) sequence positions were not observed between the first and last unique packets, after accounting for reordering.",
                    "These are gaps in the capture. Network loss, capture loss or a sender sequence change can cause them; this is not a receiver loss report.",
                    "Compare another capture point and RTCP receiver reports before attributing packet loss.")
            }
            if stream.sequence.reordered > 0 || stream.sequence.duplicates > 0 {
                add("rtp.order", .information, "Reordering or duplicate sequence numbers", "\(stream.sequence.reordered) reordered and \(stream.sequence.duplicates) duplicate sequence numbers observed.",
                    "Late packets fill sequence gaps where possible. Duplicate capture points can also produce duplicate sequence numbers.",
                    "Inspect arrival order and whether this capture combines interfaces or mirrored traffic.")
            }
            if stream.unknownClockPackets > 0 || stream.timingResets > 0 || stream.sequence.gaps == nil || stream.untimedPackets > 0 || stream.clockChanges > 0 {
                add("rtp.coverage", .information, "Media timing has coverage limits", "Unknown clock: \(stream.unknownClockPackets) packets; missing timestamps: \(stream.untimedPackets); timing resets: \(stream.timingResets); clock changes: \(stream.clockChanges); sequence resets: \(stream.sequence.discontinuities).",
                    "Jitter covers only packets with usable capture timestamps and a known, stable RTP clock. Sequence discontinuities make gap totals unavailable.",
                    "Open Jitter to verify or supply the clock rate. Dynamic payload types need SDP or an explicit clock rate.")
            }
        }
        return findings.sorted { $0.severity == $1.severity ? $0.evidence.id < $1.evidence.id : $0.severity.rawValue > $1.severity.rawValue }
    }
}
