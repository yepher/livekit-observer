import Foundation
import Testing
@testable import LiveKitObserver

/// Builds a classic WebRTC internals dump the way Chrome's dump_creator.js writes it:
/// series keyed "<stats id>-<property>", values as a JSON string, ISO start and end times.
private func internalsDump(connection: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["getUserMedia": [["origin": "https://app.example", "request_type": "getUserMedia", "audio": "{}", "timestamp": 1_700_000_000_000.0,
                                                                  "error": "NotAllowedError", "error_message": "Permission denied"]],
                                                "PeerConnections": ["1-1": connection], "UserAgent": "Mozilla/5.0 Test", "timestamp": 1_700_000_100_000.0])
}

private func series(_ type: String, _ values: [Any], start: Double = 1_700_000_000_000, step: Double = 1000) -> [String: Any] {
    let iso = ISO8601DateFormatter.fractional
    let data = try! JSONSerialization.data(withJSONObject: values)
    return ["statsType": type, "startTime": iso.string(from: Date(timeIntervalSince1970: start / 1000)),
            "endTime": iso.string(from: Date(timeIntervalSince1970: (start + step * Double(values.count - 1)) / 1000)),
            "values": String(decoding: data, as: UTF8.self)]
}

private func sampleConnection() -> [String: Any] {
    let count = 10
    let received = (0..<count).map { Double($0 * 50) }                  // 50 packets/s
    let lost = (0..<count).map { Double($0 * 5) }                       // 5 lost/s ≈ 9%
    let bytes = (0..<count).map { Double($0 * 4000) }                   // 32 kbps
    let stamps = (0..<count).map { 1_700_000_000_000 + Double($0) * 1000 }
    return [
        "url": "https://meet.example/room?token=secret-token#x",
        "rtcConfiguration": "{ iceServers: [turn:turn.example:443?transport=tcp, stun:stun.example:3478], iceTransportPolicy: all, credential: hunter2 }",
        "updateLog": [
            ["timestamp": 1_700_000_000_000.0, "type": "createOffer", "value": "offerToReceiveAudio: true"],
            ["timestamp": 1_700_000_000_100.0, "type": "icecandidate", "value": "sdpMid: 0, candidate: candidate:1 1 udp 2122 192.168.1.2 5000 typ host"],
            ["timestamp": 1_700_000_000_200.0, "type": "icecandidate", "value": "sdpMid: 0, candidate: candidate:2 1 udp 41885 203.0.113.9 6000 typ relay raddr 0.0.0.0"],
            ["timestamp": 1_700_000_000_300.0, "type": "icecandidateerror", "value": "url: stun:stun.example:3478, errorCode: 701, errorText: STUN host lookup received error."],
            ["timestamp": 1_700_000_001_000.0, "type": "iceconnectionstatechange", "value": "connected"],
            ["timestamp": 1_700_000_005_000.0, "type": "iceconnectionstatechange", "value": "disconnected"],
            ["timestamp": 1_700_000_008_000.0, "type": "iceconnectionstatechange", "value": "failed"],
        ],
        "stats": [
            "IT01A-1-timestamp": series("inbound-rtp", stamps),
            "IT01A-1-kind": series("inbound-rtp", Array(repeating: "audio", count: count)),
            "IT01A-1-ssrc": series("inbound-rtp", Array(repeating: 1234, count: count)),
            "IT01A-1-codecId": series("inbound-rtp", Array(repeating: "CIT01_111", count: count)),
            "IT01A-1-packetsReceived": series("inbound-rtp", received),
            "IT01A-1-packetsLost": series("inbound-rtp", lost),
            "IT01A-1-bytesReceived": series("inbound-rtp", bytes),
            "IT01A-1-jitter": series("inbound-rtp", Array(repeating: 0.012, count: count)),
            "CIT01_111-mimeType": series("codec", ["audio/opus"]),
            "CIT01_111-clockRate": series("codec", [48000]),
            "OT01A-kind": series("outbound-rtp", Array(repeating: "audio", count: count)),
            "OT01A-bytesSent": series("outbound-rtp", bytes),
            "OT01A-mediaSourceId": series("outbound-rtp", Array(repeating: "SA1", count: count)),
            "SA1-audioLevel": series("media-source", Array(repeating: 0, count: count)),
            "T01-selectedCandidatePairId": series("transport", ["CPa_b"]),
            "CPa_b-localCandidateId": series("candidate-pair", ["Ia"]),
            "CPa_b-remoteCandidateId": series("candidate-pair", ["Ib"]),
            "CPa_b-currentRoundTripTime": series("candidate-pair", Array(repeating: 0.08, count: count)),
            "Ia-candidateType": series("local-candidate", ["relay"]),
            "Ia-protocol": series("local-candidate", ["udp"]),
            "Ia-relayProtocol": series("local-candidate", ["tcp"]),
            "Ib-candidateType": series("remote-candidate", ["host"]),
        ],
    ]
}

@Suite struct WebRTCDumpTests {
    @Test func readsAnInternalsDumpWithExactSampleTimes() throws {
        let dump = try WebRTCDump.parse(internalsDump(connection: sampleConnection()))
        #expect(dump.format == .internals && dump.userAgent == "Mozilla/5.0 Test")
        let connection = try #require(dump.connections.first)
        #expect(connection.log.count == 7)
        // A stats id containing a hyphen still splits at the last one.
        let inbound = try #require(connection.reports["IT01A-1"])
        #expect(inbound.type == "inbound-rtp")
        let received = try #require(inbound.properties["packetsReceived"])
        #expect(received.times.count == 10)
        #expect(received.times[3] == Date(timeIntervalSince1970: 1_700_000_003))
        #expect(dump.mediaRequests.first?.error == "NotAllowedError: Permission denied")
    }

    @Test func findsTheProblemsInTheDump() throws {
        let dump = try WebRTCDump.parse(internalsDump(connection: sampleConnection()))
        let analysis = WebRTCAnalysis(dump)
        let connection = try #require(analysis.connections.first)
        #expect(connection.role == "Peer connection")
        #expect(connection.route?.relayed == true && connection.route?.relayProtocol == "tcp")
        #expect(connection.candidates == ["host udp": 1, "relay udp": 1])
        #expect(connection.page == "https://meet.example/room")
        #expect(connection.iceServers == ["turn:turn.example:443?transport=tcp", "stun:stun.example:3478"])
        let stream = try #require(connection.streams.first { !$0.sending })
        #expect(stream.codec == "audio/opus · 48000 Hz")
        let loss = try #require(stream.metrics.first { $0.name == "Packet loss" })
        #expect(abs((loss.median ?? 0) - 100.0 * 5 / 55) < 0.01)
        let bitrate = try #require(stream.metrics.first { $0.name == "Bitrate" })
        #expect(bitrate.median == 32)
        let titles = Set(analysis.findings.map(\.title))
        for expected in ["Connection failed", "Connection interrupted", "ICE candidate errors", "Relayed over TCP", "Packet loss receiving audio",
                         "Microphone is silent", "Camera or microphone request failed"] {
            #expect(titles.contains(expected), "missing \(expected)")
        }
        #expect(analysis.findings.first?.severity == .error)
        #expect(!titles.contains("High round-trip time"))
    }

    @Test func readsAnRTCStatsDumpIncludingCompressedOnes() throws {
        let lines = [
            "RTCStatsDump", #"{"fileFormat":3}"#,
            #"["navigator.mediaDevices.getUserMedia","7-0",{"audio":"echoCancellation: true"},"getUserMedia-7-1-1","https://app.example/?token=x",1700000000000]"#,
            #"["navigator.mediaDevices.getUserMediaOnFailure","7-0",{"error":"NotAllowedError","error_message":"Permission denied"},"getUserMedia-7-1-1",0]"#,
            #"["create","PC_0",{"iceServers":[{"urls":["turn:t.example"],"username":"u","credential":"c"}]},"https://app.example/room?token=x",0]"#,
            #"["iceconnectionstatechange","PC_0","connected",500]"#,
            #"["getStats","PC_0",{"IN1":{"type":"inbound-rtp","kind":"audio","timestamp":1700000001000,"bytesReceived":0,"packetsReceived":0,"packetsLost":0}},500]"#,
            #"["getStats","PC_0",{"IN1":{"type":"inbound-rtp","kind":"audio","timestamp":1700000002000,"bytesReceived":4000,"packetsReceived":50,"packetsLost":0}},1000]"#,
        ]
        let dump = try WebRTCDump.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(dump.format == .rtcstats)
        #expect(dump.connections.count == 1)
        #expect(dump.mediaRequests.map(\.kind) == ["getUserMedia", "getUserMedia"])
        #expect(dump.mediaRequests.last?.error == "NotAllowedError: Permission denied")
        let connection = try #require(dump.connections.first)
        #expect(WebRTCAnalysis.sanitize(url: connection.url) == "https://app.example/room")
        #expect(connection.log.first?.time == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(connection.reports["IN1"]?.properties["bytesReceived"]?.values.count == 2)
        #expect(WebRTCAnalysis.iceServers(connection.configuration) == ["turn:t.example"])
        #expect(WebRTCAnalysis(dump).connections.first?.streams.first?.metrics.first?.points.first?.value == 32)

        let gzip = try #require(Data(base64Encoded: "H4sIADyqBWsAAwsKcQ4uSSwpdinNLeCqVkrLzEl1yy/KTSxRsjKu5YpWSi5KTSxJVdJRCnCON1DSqVbKTE4NTi0qSy0qVrKKjq3VMTQ3QIBYkI78vLzU5JLM/LxioMGpyRmJeekIA2DSqSlKOoamIB0ABAZCgYIAAAA="))
        let compressed = try WebRTCDump.parse(gzip)
        #expect(compressed.connections.first?.log.first?.value == "connected")
        #expect(throws: (any Error).self) { try WebRTCDump.parse(Data(#"{"hello":1}"#.utf8)) }
    }

    @Test func gapsAndTimesReadSensibly() {
        let start = Date(timeIntervalSince1970: 0)
        let points = [1, 1, 0, 0, 0, 0, 1].enumerated().map { WebRTCMetric.Point(time: start.addingTimeInterval(Double($0.offset)), value: Double($0.element)) }
        let gaps = WebRTCAnalysis.gaps(points)
        #expect(gaps.count == 1 && gaps.first?.1 == 5)
        #expect(WebRTCDump.time("11/14/2023, 10:13:20 PM") != nil)
        #expect(WebRTCDump.time(1_700_000_000_000.0) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WebRTCAnalysis.candidate("candidate:842163049 1 tcp 1518280447 192.168.1.2 9 typ host tcptype active") == "host tcp")
    }

    @Test func expertEvidenceLeavesOutAddressesAndValidatesReplies() throws {
        let dump = try WebRTCDump.parse(internalsDump(connection: sampleConnection()))
        let analysis = WebRTCAnalysis(dump)
        let evidence = WebRTCExpert.evidence(dump: dump, analysis: analysis)
        let text = WebRTCExpert.prompt(evidence)
        #expect(evidence.contains { $0.id == "pc1-setup" && $0.text.contains("relay") })
        #expect(evidence.contains { $0.id.hasPrefix("rule-") })
        #expect(evidence.contains { $0.text.contains("Timeline (bucket start s: mean)") })
        for secret in ["192.168.1.2", "203.0.113.9", "secret-token", "hunter2"] { #expect(!text.contains(secret), "leaked \(secret)") }
        #expect(WebRTCExpert.scrub("from 10.0.0.1 and fe80::1:2 and 2001:db8:0:0:0:0:0:1 via abcdef01-2345-6789-abcd-ef0123456789.local") == "from [ip] and [ip] and [ip] via [mdns]")

        let reply = #"{"summary":"Downlink loss over a TCP relay.","causes":[{"title":"TCP relay","likelihood":"likely","explanation":"Route is relay over TCP.","evidenceIDs":["pc1-setup"],"checks":["Ask whether UDP is blocked"]}],"askCustomer":["Are you on a VPN?"]}"#
        let (summary, causes, questions) = try WebRTCExpert.parse("```json\n" + reply + "\n```", evidence: evidence)
        #expect(summary.contains("TCP relay") && causes.first?.likelihood == "likely" && causes.first?.checks.count == 1 && questions == ["Are you on a VPN?"])
        #expect(throws: (any Error).self) {
            try WebRTCExpert.parse(#"{"summary":"x","causes":[{"title":"t","explanation":"e","evidenceIDs":["made-up"]}]}"#, evidence: evidence)
        }
    }
}
