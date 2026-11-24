import ObserverCore
import Foundation

struct WebRTCFinding: Identifiable, Sendable {
    enum Severity: Int, Sendable, Comparable {
        case information, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    let severity: Severity
    let title: String
    let observation: String
    let explanation: String
    let nextCheck: String
    var time: Date?
    var connection: String = ""
    var id: String { "\(connection):\(title):\(observation)" }
}

struct WebRTCMetric: Identifiable, Sendable {
    struct Point: Identifiable, Sendable { let time: Date; let value: Double; var id: Date { time } }
    let name: String
    let unit: String
    let points: [Point]
    var id: String { name }
    var values: [Double] { points.map(\.value) }
    var median: Double? { Self.percentile(values, 0.5) }
    var p95: Double? { Self.percentile(values, 0.95) }
    var maximum: Double? { values.max() }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
    /// The highest-value point, for pointing at the worst moment.
    var worst: Point? { points.max { $0.value < $1.value } }
}

struct WebRTCStream: Identifiable, Sendable {
    let id: String
    let kind: String
    let sending: Bool
    let title: String
    let codec: String
    let ssrc: String
    var metrics: [WebRTCMetric]
    var facts: [(String, String)]
}

struct WebRTCConnectionAnalysis: Identifiable, Sendable {
    struct StateChange: Identifiable, Sendable { let id: Int; let time: Date?; let kind: String; let state: String }
    struct Route: Sendable {
        var local = "", remote = "", localAddress = "", remoteAddress = ""
        var protocolName = "", relayProtocol = "", networkType = ""
        var relayed: Bool { local == "relay" || remote == "relay" }
        var summary: String {
            var text = "\(local.isEmpty ? "?" : local) → \(remote.isEmpty ? "?" : remote) over \(protocolName.isEmpty ? "?" : protocolName.uppercased())"
            if !relayProtocol.isEmpty { text += " (relay reached over \(relayProtocol.uppercased()))" }
            if !networkType.isEmpty { text += " · \(networkType)" }
            return text
        }
    }
    let id: String
    var role = "Peer connection"
    var page = ""
    var iceServers: [String] = []
    var iceTransportPolicy = ""
    var states: [StateChange] = []
    var candidates: [String: Int] = [:]
    var candidateErrors: [String] = []
    var route: Route?
    var roundTrip: WebRTCMetric?
    var outgoingBitrate: WebRTCMetric?
    var streams: [WebRTCStream] = []
    var findings: [WebRTCFinding] = []
    var start: Date?, end: Date?
    /// The span the stats cover, for lining charts up.
    var span: ClosedRange<Date>? {
        let times = streams.flatMap { $0.metrics.flatMap { [$0.points.first?.time, $0.points.last?.time] } } + [roundTrip?.points.first?.time, roundTrip?.points.last?.time]
        let known = times.compactMap { $0 }
        guard let low = known.min(), let high = known.max(), high > low else { return nil }
        return low...high
    }
    var finalState: String { states.last { $0.kind == "connection" || $0.kind == "ICE" }?.state ?? "unknown" }
    var title: String { "\(role) · \(finalState)" }
}

struct WebRTCAnalysis: Sendable {
    var connections: [WebRTCConnectionAnalysis]
    var findings: [WebRTCFinding]

    init(_ dump: WebRTCDump) {
        connections = dump.connections.map(Self.analyze)
        var all = connections.flatMap(\.findings)
        for request in dump.mediaRequests where request.error != nil {
            all.append(WebRTCFinding(severity: .error, title: "Camera or microphone request failed",
                                     observation: "\(request.kind) failed: \(request.error ?? "")",
                                     explanation: "The browser could not open the device, so nothing was sent from it. NotAllowedError means permission was refused; NotFoundError or OverconstrainedError mean no device matched; NotReadableError means another app holds it.",
                                     nextCheck: "Check the browser's site permissions and the operating system's privacy settings, and close other apps using the device.", time: request.time))
        }
        findings = all.sorted { ($0.severity, $1.time ?? .distantFuture) > ($1.severity, $0.time ?? .distantFuture) }
    }

    // MARK: Connection

    static func analyze(_ connection: WebRTCDump.Connection) -> WebRTCConnectionAnalysis {
        var result = WebRTCConnectionAnalysis(id: connection.id)
        result.page = sanitize(url: connection.url)
        result.iceServers = iceServers(connection.configuration)
        if let match = connection.configuration.range(of: #"iceTransportPolicy\W+(\w+)"#, options: .regularExpression) {
            result.iceTransportPolicy = String(connection.configuration[match]).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.last ?? ""
        }
        let inbound = connection.reports("inbound-rtp"), outbound = connection.reports("outbound-rtp")
        result.role = !outbound.isEmpty && inbound.isEmpty ? "Publisher (sends)" : !inbound.isEmpty && outbound.isEmpty ? "Subscriber (receives)" : "Peer connection"

        for entry in connection.log {
            let type = entry.type.lowercased(), value = entry.value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let kind: String? = switch type {
            case "iceconnectionstatechange": "ICE"
            case "connectionstatechange": "connection"
            case "icegatheringstatechange": "gathering"
            case "signalingstatechange": "signaling"
            default: nil
            }
            if let kind { result.states.append(.init(id: entry.id, time: entry.time, kind: kind, state: value)) }
            if type == "icecandidate" || type == "onicecandidate", let candidate = candidate(entry.value) { result.candidates[candidate, default: 0] += 1 }
            if type.contains("icecandidateerror") { result.candidateErrors.append(entry.value) }
        }
        if result.candidates.isEmpty {
            for report in connection.reports("local-candidate") {
                let type = report.text("candidateType") ?? "?", proto = report.text("protocol") ?? "?"
                result.candidates["\(type) \(proto)", default: 0] += 1
            }
        }
        let times = connection.log.compactMap(\.time) + connection.reports.values.flatMap { $0.properties.values.flatMap { [$0.times.first, $0.times.last].compactMap { $0 } } }
        result.start = times.min(); result.end = times.max()

        // The selected route: the transport's chosen pair, or else the nominated pair that carried the most.
        let pairs = connection.reports("candidate-pair")
        let selectedID = connection.reports("transport").compactMap { $0.text("selectedCandidatePairId") }.first
        let pair = pairs.first { $0.id == selectedID }
            ?? pairs.filter { $0.properties["nominated"]?.last?.bool == true }.max { ($0.number("bytesReceived") ?? 0) + ($0.number("bytesSent") ?? 0) < ($1.number("bytesReceived") ?? 0) + ($1.number("bytesSent") ?? 0) }
        if let pair {
            var route = WebRTCConnectionAnalysis.Route()
            if let local = pair.text("localCandidateId").flatMap({ connection.reports[$0] }) {
                route.local = local.text("candidateType") ?? ""; route.protocolName = local.text("protocol") ?? ""
                route.relayProtocol = local.text("relayProtocol") ?? ""; route.networkType = local.text("networkType") ?? ""
                route.localAddress = [local.text("address") ?? local.text("ip"), local.text("port")].compactMap { $0 }.joined(separator: ":")
            }
            if let remote = pair.text("remoteCandidateId").flatMap({ connection.reports[$0] }) {
                route.remote = remote.text("candidateType") ?? ""
                route.remoteAddress = [remote.text("address") ?? remote.text("ip"), remote.text("port")].compactMap { $0 }.joined(separator: ":")
            }
            result.route = route
            result.roundTrip = direct(pair.properties["currentRoundTripTime"], "Round trip", "ms", scale: 1000)
            result.outgoingBitrate = direct(pair.properties["availableOutgoingBitrate"], "Available send bandwidth", "kbps", scale: 0.001)
        }

        let codecs = Dictionary(connection.reports("codec").map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteInbound = connection.reports("remote-inbound-rtp")
        for report in inbound + outbound {
            result.streams.append(stream(report, sending: report.type == "outbound-rtp", codecs: codecs, connection: connection,
                                         remote: remoteInbound.first { $0.text("localId") == report.id || ($0.text("ssrc") != nil && $0.text("ssrc") == report.text("ssrc")) }))
        }
        result.streams.sort { ($0.sending ? 1 : 0, $0.kind, $0.title) < ($1.sending ? 1 : 0, $1.kind, $1.title) }
        result.findings = findings(result).map { var finding = $0; finding.connection = result.role; return finding }
        return result
    }

    // MARK: Streams

    private static func stream(_ report: WebRTCDump.Report, sending: Bool, codecs: [String: WebRTCDump.Report],
                               connection: WebRTCDump.Connection, remote: WebRTCDump.Report?) -> WebRTCStream {
        let kind = report.text("kind") ?? report.text("mediaType") ?? "audio"
        let codec = report.text("codecId").flatMap { codecs[$0] }.map { [$0.text("mimeType"), $0.number("clockRate").map { "\(Int($0)) Hz" }].compactMap { $0 }.joined(separator: " · ") } ?? ""
        let ssrc = report.text("ssrc") ?? ""
        let label = report.text("trackIdentifier") ?? report.text("mid").map { "mid \($0)" } ?? ssrc
        let p = report.properties
        var metrics: [WebRTCMetric?] = [rate(p[sending ? "bytesSent" : "bytesReceived"], "Bitrate", "kbps", scale: 8 / 1000)]
        var facts: [(String, String)] = []
        if !sending {
            metrics.append(ratio(p["packetsLost"], over: [p["packetsLost"], p["packetsReceived"]], "Packet loss", "%", scale: 100))
            metrics.append(direct(p["jitter"], "Jitter", "ms", scale: 1000))
            if kind == "audio" {
                metrics.append(ratio(p["jitterBufferDelay"], over: [p["jitterBufferEmittedCount"]], "Jitter buffer delay", "ms", scale: 1000))
                metrics.append(ratio(p["concealedSamples"], over: [p["totalSamplesReceived"]], "Concealment", "%", scale: 100))
                metrics.append(direct(p["audioLevel"], "Audio level", "", scale: 1))
            } else {
                metrics.append(direct(p["framesPerSecond"], "Frame rate", "fps", scale: 1))
                metrics.append(direct(p["frameHeight"], "Frame height", "px", scale: 1))
            }
            if let lost = report.number("packetsLost"), let received = report.number("packetsReceived") {
                facts.append(("Packets", "\(Int(received)) received · \(Int(lost)) lost (\(percent(lost, of: lost + received)))"))
            }
            if let concealed = report.number("concealedSamples"), let total = report.number("totalSamplesReceived"), total > 0 {
                facts.append(("Concealed audio", percent(concealed, of: total)))
            }
            if let freezes = report.number("freezeCount"), freezes > 0 {
                facts.append(("Freezes", "\(Int(freezes)) · \(String(format: "%.1f", report.number("totalFreezesDuration") ?? 0)) s frozen"))
            }
        } else {
            if let remote {
                metrics.append(direct(remote.properties["fractionLost"], "Loss at receiver", "%", scale: 100))
                metrics.append(direct(remote.properties["roundTripTime"], "Round trip (RTCP)", "ms", scale: 1000))
                metrics.append(direct(remote.properties["jitter"], "Jitter at receiver", "ms", scale: 1000))
            }
            if kind == "audio", let source = report.text("mediaSourceId").flatMap({ connection.reports[$0] }) {
                metrics.append(direct(source.properties["audioLevel"], "Microphone level", "", scale: 1))
            }
            if kind == "video" {
                metrics.append(direct(p["framesPerSecond"], "Frame rate", "fps", scale: 1))
                metrics.append(direct(p["frameHeight"], "Frame height", "px", scale: 1))
                if let reasons = p["qualityLimitationReason"]?.values.compactMap(\.string), !reasons.isEmpty {
                    let counts = Dictionary(grouping: reasons, by: { $0 }).mapValues(\.count)
                    facts.append(("Quality limited by", counts.sorted { $0.value > $1.value }.map { "\($0.key) \(percent(Double($0.value), of: Double(reasons.count)))" }.joined(separator: ", ")))
                }
            }
            if let sent = report.number("packetsSent") { facts.append(("Packets sent", "\(Int(sent))")) }
            if let retransmitted = report.number("retransmittedPacketsSent"), retransmitted > 0 { facts.append(("Retransmitted", "\(Int(retransmitted))")) }
        }
        let title = "\(kind.capitalized) \(sending ? "sent" : "received") · \(label)"
        return WebRTCStream(id: report.id, kind: kind, sending: sending, title: title, codec: codec, ssrc: ssrc, metrics: metrics.compactMap { $0 }.filter { !$0.points.isEmpty }, facts: facts)
    }

    private static func points(_ series: WebRTCDump.Series?) -> [(Date, Double)] { series?.numbers ?? [] }

    static func direct(_ series: WebRTCDump.Series?, _ name: String, _ unit: String, scale: Double) -> WebRTCMetric? {
        let values = points(series)
        guard !values.isEmpty else { return nil }
        return WebRTCMetric(name: name, unit: unit, points: values.map { .init(time: $0.0, value: $0.1 * scale) })
    }

    /// Per-second rate of a counter; drops intervals where the counter went backwards.
    static func rate(_ series: WebRTCDump.Series?, _ name: String, _ unit: String, scale: Double) -> WebRTCMetric? {
        let values = points(series)
        guard values.count > 1 else { return nil }
        let result = zip(values, values.dropFirst()).compactMap { a, b -> WebRTCMetric.Point? in
            let seconds = b.0.timeIntervalSince(a.0), change = b.1 - a.1
            guard seconds > 0, change >= 0 else { return nil }
            return .init(time: b.0, value: change / seconds * scale)
        }
        return WebRTCMetric(name: name, unit: unit, points: result)
    }

    /// Change in a counter over the change in the sum of other counters, per interval
    /// (for example packets lost over packets lost plus received).
    static func ratio(_ numerator: WebRTCDump.Series?, over denominators: [WebRTCDump.Series?], _ name: String, _ unit: String, scale: Double) -> WebRTCMetric? {
        let top = points(numerator), bottoms = denominators.map(points)
        let count = ([top.count] + bottoms.map(\.count)).min() ?? 0
        guard count > 1 else { return nil }
        let a = Array(top.suffix(count)), b = bottoms.map { Array($0.suffix(count)) }
        let result = (1..<count).compactMap { index -> WebRTCMetric.Point? in
            let up = a[index].1 - a[index - 1].1
            let down = b.reduce(0) { $0 + $1[index].1 - $1[index - 1].1 }
            guard down > 0, up >= 0 else { return nil }
            return .init(time: a[index].0, value: up / down * scale)
        }
        return WebRTCMetric(name: name, unit: unit, points: result)
    }

    static func percent(_ part: Double, of whole: Double) -> String {
        whole > 0 ? String(format: "%.1f%%", part / whole * 100) : "–"
    }

    // MARK: Configuration

    /// "candidate:… typ relay … tcptype …" becomes "relay udp".
    static func candidate(_ text: String) -> String? {
        guard let type = text.range(of: #"typ (\w+)"#, options: .regularExpression) else { return nil }
        let proto = text.range(of: #"candidate:\S+ \d+ (udp|tcp|UDP|TCP)"#, options: .regularExpression).map { String(text[$0]).split(separator: " ").last.map(String.init)?.lowercased() ?? "" } ?? ""
        return "\(text[type].dropFirst(4)) \(proto)".trimmingCharacters(in: .whitespaces)
    }

    /// STUN and TURN server URLs, without the usernames and credentials beside them.
    static func iceServers(_ configuration: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"(?:stuns?|turns?):[^\s,\]\}"'\\]+"#)
        let matches = pattern.matches(in: configuration, range: NSRange(configuration.startIndex..., in: configuration))
        var seen = Set<String>()
        return matches.compactMap { Range($0.range, in: configuration).map { String(configuration[$0]) } }.filter { seen.insert($0).inserted }
    }

    /// The page, without its query or fragment, which can carry access tokens.
    static func sanitize(url: String) -> String {
        guard var parts = URLComponents(string: url), parts.scheme != nil else { return url.components(separatedBy: "?").first ?? url }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string ?? url
    }

    // MARK: Findings

    static func findings(_ c: WebRTCConnectionAnalysis) -> [WebRTCFinding] {
        var findings: [WebRTCFinding] = []
        let connectionStates = c.states.filter { $0.kind == "connection" || $0.kind == "ICE" }
        let connected = connectionStates.contains { $0.state == "connected" || $0.state == "completed" }
        let relayGathered = c.candidates.keys.contains { $0.hasPrefix("relay") }

        if let failed = connectionStates.first(where: { $0.state == "failed" }) {
            let recovered = connectionStates.contains { ($0.time ?? .distantPast) > (failed.time ?? .distantFuture) && $0.state == "connected" }
            findings.append(.init(severity: .error, title: "Connection failed", observation: "The \(failed.kind) state reached failed\(recovered ? " and later recovered" : "").",
                                  explanation: "ICE found no working route between the browser and the server, or lost every route it had." + (relayGathered ? "" : " The browser gathered no TURN relay candidates, so it had no fallback through restrictive firewalls or proxies."),
                                  nextCheck: relayGathered ? "Check the selected route before the failure and the network at that time (VPN, Wi-Fi change, sleep)." : "Check that TURN is configured and reachable (LiveKit Cloud provides it), and whether a firewall blocks UDP.", time: failed.time))
        } else if !connected, !connectionStates.isEmpty {
            findings.append(.init(severity: .error, title: "Never connected", observation: "The connection ended in “\(c.finalState)” without reaching connected.",
                                  explanation: "Signaling ran, but ICE never found a working route, or the page closed the connection first.",
                                  nextCheck: "Look at the candidates gathered and any ICE candidate errors.", time: connectionStates.last?.time))
        }
        let disconnects = connectionStates.filter { $0.state == "disconnected" && $0.kind == "ICE" }
        let drops = disconnects.isEmpty ? connectionStates.filter { $0.state == "disconnected" } : disconnects
        if !drops.isEmpty {
            findings.append(.init(severity: .warning, title: "Connection interrupted", observation: "Disconnected \(drops.count) time\(drops.count == 1 ? "" : "s").",
                                  explanation: "ICE stopped receiving from the server for a few seconds. Audio stops during the gap; LiveKit restarts ICE or reconnects if it doesn't recover.",
                                  nextCheck: "Compare the times with the bitrate and round-trip charts, and with Wi-Fi or VPN changes on the client.", time: drops.first?.time))
        }
        if !c.candidateErrors.isEmpty {
            let codes = Set(c.candidateErrors.compactMap { text in text.range(of: #"errorCode\W+\d+"#, options: .regularExpression).map { String(text[$0]).filter(\.isNumber) } })
            findings.append(.init(severity: .warning, title: "ICE candidate errors", observation: "\(c.candidateErrors.count) error\(c.candidateErrors.count == 1 ? "" : "s")\(codes.isEmpty ? "" : ": " + codes.sorted().joined(separator: ", ")).",
                                  explanation: "The browser couldn't reach a STUN or TURN server, or the server rejected it. Error 701 means the server didn't answer on that address; these are harmless when another route worked.",
                                  nextCheck: "Matters only if the connection failed or was relayed: check that the listed servers are reachable from the client's network."))
        }
        if let route = c.route, route.relayed {
            let tcp = ["tcp", "tls"].contains(route.relayProtocol.lowercased())
            findings.append(.init(severity: tcp ? .warning : .information, title: tcp ? "Relayed over TCP" : "Relayed through TURN",
                                  observation: route.summary,
                                  explanation: tcp ? "Media goes through a TURN server over TCP or TLS, usually because UDP is blocked. A lost packet then holds up the ones behind it, which shows up as jitter and choppy audio." : "Media goes through a TURN server instead of straight to LiveKit, usually because of a restrictive firewall or NAT. It adds a little latency.",
                                  nextCheck: "Check whether the client's network blocks UDP to LiveKit."))
        }
        if let rtt = c.roundTrip, let median = rtt.median, median > 250 || (rtt.maximum ?? 0) > 1000 {
            findings.append(.init(severity: .warning, title: "High round-trip time", observation: String(format: "Median %.0f ms, worst %.0f ms.", median, rtt.maximum ?? 0),
                                  explanation: "Long round trips delay everything the agent hears and says, and slow recovery from loss.",
                                  nextCheck: "Check the client's distance from the LiveKit region it connected to, and congestion on its network.", time: rtt.worst?.time))
        }
        if let bandwidth = c.outgoingBitrate, let start = bandwidth.points.first?.time {
            let settled = bandwidth.points.filter { $0.time.timeIntervalSince(start) > 5 }
            if let low = settled.min(by: { $0.value < $1.value }), low.value < 100 {
                findings.append(.init(severity: .warning, title: "Low send bandwidth", observation: String(format: "The browser estimated %.0f kbps available to send.", low.value),
                                      explanation: "Congestion control found little room on the uplink, so the browser lowers what it sends.",
                                      nextCheck: "Check uplink congestion (uploads, other calls) on the client's network.", time: low.time))
            }
        }
        for stream in c.streams { findings += streamFindings(stream) }
        return findings
    }

    private static func metric(_ stream: WebRTCStream, _ name: String) -> WebRTCMetric? { stream.metrics.first { $0.name == name } }

    private static func streamFindings(_ s: WebRTCStream) -> [WebRTCFinding] {
        var findings: [WebRTCFinding] = []
        let name = s.title
        if !s.sending {
            if let loss = metric(s, "Packet loss"), let mean = loss.values.isEmpty ? nil : loss.values.reduce(0, +) / Double(loss.values.count), mean >= 2 || (loss.maximum ?? 0) >= 15 {
                findings.append(.init(severity: mean >= 5 ? .error : .warning, title: "Packet loss receiving \(s.kind)",
                                      observation: String(format: "%@: average %.1f%%, worst %.0f%% in one interval.", name, mean, loss.maximum ?? 0),
                                      explanation: "Packets from the server didn't arrive. Audio covers small losses with concealment, which sounds robotic or choppy as loss grows.",
                                      nextCheck: "Look for Wi-Fi or mobile network problems on the client at the worst moment.", time: loss.worst?.time))
            }
            if let jitter = metric(s, "Jitter"), let p95 = jitter.p95, p95 > 50 {
                findings.append(.init(severity: .warning, title: "High jitter receiving \(s.kind)", observation: String(format: "%@: 95th percentile %.0f ms.", name, p95),
                                      explanation: "Packets arrive unevenly, so the jitter buffer grows to smooth them out, which adds delay, or plays gaps when it can't keep up.",
                                      nextCheck: "Check for congestion or a TCP relay on the client's network.", time: jitter.worst?.time))
            }
            if let buffer = metric(s, "Jitter buffer delay"), let median = buffer.median, median > 250 {
                findings.append(.init(severity: .warning, title: "Large jitter buffer", observation: String(format: "%@: median %.0f ms.", name, median),
                                      explanation: "The browser holds audio this long before playing it, adding to the delay before the user hears the agent.",
                                      nextCheck: "Usually follows jitter or loss; fix those first.", time: buffer.worst?.time))
            }
            if let concealment = metric(s, "Concealment"), let mean = concealment.values.isEmpty ? nil : concealment.values.reduce(0, +) / Double(concealment.values.count), mean > 3 {
                findings.append(.init(severity: mean > 10 ? .error : .warning, title: "Audio concealment", observation: String(format: "%@: %.1f%% of audio was concealed on average, worst %.0f%%.", name, mean, concealment.maximum ?? 0),
                                      explanation: "The browser made up audio to cover missing or late packets. Listeners hear it as robotic, stretched, or choppy speech.",
                                      nextCheck: "Compare with the packet loss and jitter charts at the same time.", time: concealment.worst?.time))
            }
            if let bitrate = metric(s, "Bitrate") {
                let gaps = gaps(bitrate.points)
                if let first = gaps.first {
                    findings.append(.init(severity: .warning, title: "Gaps receiving \(s.kind)", observation: "\(name): nothing arrived for \(gaps.map { String(format: "%.0f s", $0.1) }.joined(separator: ", ")).",
                                          explanation: "The stream stopped delivering data. It can be the network, or the sender pausing (muted, or not speaking with DTX and an SFU that drops silence).",
                                          nextCheck: "Check whether the sender was muted then, and the connection state at those times.", time: first.0))
                }
            }
            if s.facts.contains(where: { $0.0 == "Freezes" }) {
                findings.append(.init(severity: .warning, title: "Video froze", observation: "\(name): " + (s.facts.first { $0.0 == "Freezes" }?.1 ?? ""),
                                      explanation: "Frames stopped arriving or decoding for long enough to see.", nextCheck: "Compare with packet loss and frame rate."))
            }
        } else {
            if let level = metric(s, "Microphone level"), level.points.count >= 5, (level.maximum ?? 0) < 0.0005,
               let bitrate = metric(s, "Bitrate"), (bitrate.median ?? 0) > 0 {
                findings.append(.init(severity: .warning, title: "Microphone is silent", observation: "\(name): the microphone level stayed at zero while audio was being sent.",
                                      explanation: "The browser sent audio, but it was silence: the wrong input device, a hardware mute switch, or an OS-level mute.",
                                      nextCheck: "Check the selected input device and the operating system's input level.", time: level.points.first?.time))
            }
            if let loss = metric(s, "Loss at receiver"), let p95 = loss.p95, let mean = loss.values.isEmpty ? nil : loss.values.reduce(0, +) / Double(loss.values.count), mean > 2 || p95 > 5 {
                findings.append(.init(severity: .warning, title: "Upstream packet loss", observation: String(format: "%@: the server reported losing %.1f%% on average, %.0f%% at the 95th percentile, of what the browser sent.", name, mean, p95),
                                      explanation: "Packets leaving the client don't all reach LiveKit, so the agent hears gaps or concealment in the user's speech.",
                                      nextCheck: "Check the client's uplink, which is often weaker than its downlink.", time: loss.worst?.time))
            }
            if let limit = s.facts.first(where: { $0.0 == "Quality limited by" }), !limit.1.hasPrefix("none") {
                findings.append(.init(severity: .information, title: "Video quality limited", observation: "\(name): \(limit.1).",
                                      explanation: "The browser lowered resolution or frame rate because of bandwidth or CPU.", nextCheck: "Bandwidth: check the uplink. CPU: check load on the client."))
            }
        }
        return findings
    }

    /// Stretches of at least 3 s where a rate stayed at zero, as (start, seconds).
    static func gaps(_ points: [WebRTCMetric.Point]) -> [(Date, TimeInterval)] {
        var result: [(Date, TimeInterval)] = [], start: Date?, last: Date?
        for point in points {
            if point.value <= 0 { if start == nil { start = last ?? point.time } }
            else if let begin = start { if point.time.timeIntervalSince(begin) >= 3 { result.append((begin, point.time.timeIntervalSince(begin))) }; start = nil }
            last = point.time
        }
        if let begin = start, let end = points.last?.time, end.timeIntervalSince(begin) >= 3 { result.append((begin, end.timeIntervalSince(begin))) }
        return result
    }
}
