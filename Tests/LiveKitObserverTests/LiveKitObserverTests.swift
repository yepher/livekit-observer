import AVFoundation
import Foundation
import Testing
@testable import LiveKitObserver

private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

@Suite struct SigV4Tests {
    let key = "AKIAIOSFODNN7EXAMPLE", secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    let date = Date(timeIntervalSince1970: 1369353600) // 2013-05-24T00:00:00Z

    // AWS's published S3 SigV4 examples.
    @Test func getObjectExample() {
        let headers = SigV4.sign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, headers: ["Range": "bytes=0-9"],
                                 payloadHash: SigV4.emptyPayloadHash, accessKey: key, secret: secret, region: "us-east-1", date: date)
        #expect(headers["authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func listObjectsExample() {
        let headers = SigV4.sign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!, headers: [:],
                                 payloadHash: SigV4.emptyPayloadHash, accessKey: key, secret: secret, region: "us-east-1", date: date)
        #expect(headers["authorization"]?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    @Test func encodesSlashesInQueryButNotPath() {
        #expect(SigV4.encodePath("/bucket/recordings/calls/a b.ogg") == "/bucket/recordings/calls/a%20b.ogg")
        #expect(SigV4.canonicalQuery([URLQueryItem(name: "prefix", value: "recordings/calls/"), URLQueryItem(name: "list-type", value: "2")])
                == "list-type=2&prefix=recordings%2Fcalls%2F")
    }
}

@Suite struct ParsingTests {
    @Test func egressManifestUsesNanosecondTimesAndRoomSid() throws {
        let m = try json(#"{"egress_id":"EG_1","room_id":"RM_abc","room_name":"support-46c3","started_at":1794581855490086702,"ended_at":1794583400703899643,"files":[{"filename":"recordings/calls/2026/11/13/x.ogg"}]}"#)
        let r = try #require(EgressRecording(manifest: m))
        #expect(r.roomId == "RM_abc")
        #expect(r.audioKey == "recordings/calls/2026/11/13/x.ogg")
        #expect(abs(r.startedAt!.timeIntervalSince1970 - 1794581855.490) < 0.01)
    }

    @Test func mergesSessionsWithRecordingsByRoomSid() throws {
        let s = try #require(LiveKitSession(json: json(#"{"sessionId":"RM_abc","roomName":"support-1","status":"SESSION_STATUS_CLOSED","startedAt":"2026-11-13T15:00:00Z","endedAt":"2026-11-13T15:30:00Z","hasDetailData":true}"#)))
        var r = try #require(EgressRecording(manifest: json(#"{"room_id":"RM_abc","files":[{"filename":"a.ogg"}]}"#)))
        r.size = 10
        var old = try #require(EgressRecording(manifest: json(#"{"room_id":"RM_old","room_name":"support-2","started_at":1700000000000000000,"files":[{"filename":"b.ogg"}]}"#)))
        old.size = 5
        let rows = SessionRow.merge(sessions: [s], recordings: [r, old])
        #expect(rows.map(\.id) == ["RM_abc", "RM_old"])
        #expect(rows[0].recording?.audioKey == "a.ogg")
        #expect(rows[0].title == "support-1")
        #expect(rows[0].duration == 1800)
        #expect(rows[1].session == nil)
        #expect(SessionRow(id: "RM_x").title == "RM_x")
    }

    @Test func groupsRowsByDayNewestFirstWithUndatedLast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func row(_ id: String, _ start: String?) throws -> SessionRow {
            let started = start.map { #","startedAt":"\#($0)""# } ?? ""
            return SessionRow(id: id, session: try #require(LiveKitSession(json: json(#"{"sessionId":"\#(id)"\#(started)}"#))))
        }
        // 07:30Z on the 14th is still the 13th in Los Angeles.
        let rows = try [row("a", "2026-11-14T09:00:00Z"), row("b", "2026-11-14T07:30:00Z"), row("c", "2026-11-13T15:00:00Z"), row("d", nil)]
        let days = DaySection.group(rows, calendar: calendar)
        #expect(days.map { $0.rows.map(\.id) } == [["a"], ["b", "c"], ["d"]])
        #expect(days.last?.id == nil)
        #expect(days.last?.title == "Unknown date")
    }

    @Test func readsTranscriptTimingAndListShapes() throws {
        let page = try json(#"{"items":[{"id":"i1","timestamp":"2026-01-15T01:38:58.212Z","message":{"role":"ROLE_USER","text":"hola","transcriptConfidence":0.42,"startedSpeakingAt":"2026-01-15T01:38:58.212Z","endOfTurnDelayMs":528.9}},{"id":"i2","message":{"role":"ROLE_AGENT","text":"¡Muy bien!","e2eLatencyMs":2406.3,"llmTtftMs":"412.7"}},{"id":"i3","functionCall":{"name":"record_answer","arguments":"{}"}}],"dataStatus":{"state":"DATA_STATE_SETTLED"}}"#)
        let items = page.items.enumerated().map { TranscriptItem(json: $1, index: $0) }
        #expect(items.map(\.role) == [.user, .agent, .other])
        #expect(items[0].start != nil)
        #expect(items[1].llmTtftMs == 412.7)
        #expect(items[2].kind == "functionCall")
        let insights = SessionInsights(transcript: items, logs: [LogRecord(json: try json(#"{"level":"LOG_LEVEL_WARN","message":"slow"}"#), index: 0)], spans: [])
        #expect(insights.slowTurns.map(\.id) == ["i2"])
        #expect(insights.lowConfidence.map(\.id) == ["i1"])
        #expect(insights.problems.count == 1)
        #expect(try json(#"[{"a":1}]"#).items.count == 1)
        #expect(try json(#"{"sessions":[{"a":1}],"pageInfo":{}}"#).items.count == 1)
    }

    @Test func parsesNanosecondIsoDates() {
        #expect(ISODate.parse("2026-01-15T01:38:58.212345678Z") != nil)
        #expect(ISODate.parse("2026-01-15T01:38:58Z") != nil)
    }

    @Test func spanTreeNestsChildrenAndKeepsOrphans() throws {
        let spans = try ["{\"spanId\":\"a\",\"name\":\"root\",\"startTime\":\"2026-01-15T01:00:00Z\"}",
                         "{\"spanId\":\"b\",\"parentSpanId\":\"a\",\"name\":\"child\"}",
                         "{\"spanId\":\"c\",\"parentSpanId\":\"missing\",\"name\":\"orphan\"}"].enumerated().map { Span(json: try json($1), index: $0) }
        let tree = SpanNode.tree(spans)
        #expect(Set(tree.map(\.span.name)) == ["root", "orphan"])
        #expect(tree.first { $0.span.name == "root" }?.children?.first?.span.name == "child")
    }

    @Test func readsLkProjects() throws {
        let projects = LKProject.list(from: try json(#"[{"Name":"other","ProjectId":"","URL":"ws://localhost:7880"},{"Name":"app","ProjectId":"p_123","URL":"wss://app-b2qz62bd.livekit.cloud","APIKey":"k","APISecret":"s"}]"#))
        #expect(projects.map(\.name) == ["other", "app"])
        #expect(projects[0].projectId == nil && projects[0].subdomain == nil)
        #expect(projects[1].projectId == "p_123" && projects[1].subdomain == "app-b2qz62bd")
        #expect(LiveKitCLI.dashboardURL(project: "p_123", session: "RM_abc")?.absoluteString == "https://cloud.livekit.io/projects/p_123/sessions/RM_abc")
    }

    @Test func listObjectsXML() {
        let xml = Data("<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>a/b.ogg</Key><Size>42</Size></Contents><NextContinuationToken>tok</NextContinuationToken></ListBucketResult>".utf8)
        let page = ListObjectsParser.parse(xml)
        #expect(page.objects == [StorageObject(key: "a/b.ogg", size: 42)])
        #expect(page.nextToken == "tok")
    }

    @Test func importsEgressOrAwsEnvFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "# c\nEGRESS_S3_BUCKET=bkt\nEGRESS_S3_REGION=nyc3\nEGRESS_S3_ENDPOINT=\"https://nyc3.digitaloceanspaces.com\"\nEGRESS_S3_ACCESS_KEY=k\nEGRESS_S3_SECRET=s\nEGRESS_PREFIX=/calls/\n".write(to: url, atomically: true, encoding: .utf8)
        let spaces = try StorageSettings.importing(envFile: url)
        #expect(spaces.settings.bucket == "bkt" && spaces.settings.accessKey == "k" && spaces.secret == "s")
        let config = try StorageConfig(settings: spaces.settings, secret: spaces.secret)
        #expect(config.endpoint.host == "nyc3.digitaloceanspaces.com" && config.pathStyle && config.prefix == "calls/")

        try "export AWS_ACCESS_KEY_ID=AK\nexport AWS_SECRET_ACCESS_KEY=SK\nAWS_REGION=us-west-2\nS3_BUCKET=media\n".write(to: url, atomically: true, encoding: .utf8)
        let aws = try StorageSettings.importing(envFile: url)
        #expect(aws.settings.endpoint.isEmpty && aws.secret == "SK")
        let awsConfig = try StorageConfig(settings: aws.settings, secret: aws.secret)
        #expect(awsConfig.endpoint.absoluteString == "https://s3.us-west-2.amazonaws.com" && !awsConfig.pathStyle && awsConfig.prefix.isEmpty)
    }

    @Test func storageNeedsBucketKeysAndAnEndpointOrRegion() throws {
        var settings = StorageSettings()
        settings.bucket = "b"
        settings.accessKey = "k"
        #expect(throws: StorageError.self) { try StorageConfig(settings: settings, secret: "") }
        #expect(throws: StorageError.self) { try StorageConfig(settings: settings, secret: "s") }
        settings.endpoint = "abc.r2.cloudflarestorage.com"
        let r2 = try StorageConfig(settings: settings, secret: "s")
        #expect(r2.endpoint.absoluteString == "https://abc.r2.cloudflarestorage.com" && r2.region == "auto" && r2.pathStyle)
        settings.endpoint = "https://sfo3.digitaloceanspaces.com"
        #expect(try StorageConfig(settings: settings, secret: "s").region == "sfo3")
    }
}

@Suite struct SpectrogramTests {
    /// Writes a two-second 48 kHz stereo WAV with a sine of `left` Hz and `right` Hz.
    private func tone(left: Double, right: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for i in 0..<96_000 {
            buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * left * Double(i) / 48_000))
            buffer.floatChannelData![1][i] = Float(0.5 * sin(2 * .pi * right * Double(i) / 48_000))
        }
        try file.write(from: buffer)
        return url
    }

    private func loudestBand(_ s: Spectrogram, channel: Int) -> Int {
        let frame = s.frameCount / 2
        return (0..<Spectrogram.bands).max { s.level(channel: channel, frame: frame, band: $0) < s.level(channel: channel, frame: frame, band: $1) }!
    }

    @Test func eachChannelPeaksAtItsOwnFrequency() throws {
        let url = try tone(left: 440, right: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try Spectrogram.compute(file: url)
        #expect(s.channels.count == 2 && !s.identicalChannels)
        #expect(abs(s.hop - 0.01) < 1e-9)
        #expect(abs(s.duration - 2) < 0.05)
        let centers = Spectrogram.bandCenters
        let left = centers[loudestBand(s, channel: 0)], right = centers[loudestBand(s, channel: 1)]
        #expect(abs(left - 440) / 440 < 0.08, "left peak \(left) Hz")
        #expect(abs(right - 3000) / 3000 < 0.08, "right peak \(right) Hz")
        // A half-scale sine is about -6 dBFS: near the top of the range, not clipped.
        let peak = s.level(channel: 0, frame: s.frameCount / 2, band: loudestBand(s, channel: 0))
        #expect(peak > 200 && peak < 255)
    }

    @Test func aMonoMixWrittenAsStereoIsOneLane() throws {
        let url = try tone(left: 1000, right: 1000)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try Spectrogram.compute(file: url)
        #expect(s.identicalChannels && s.channels.count == 1)
    }

    @Test func imageCoversTheRequestedWindowAndLeavesTheRestBlank() throws {
        let url = try tone(left: 440, right: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try Spectrogram.compute(file: url)
        let image = try #require(s.image(channel: 0, from: -1, to: 3, columns: 400))
        #expect(image.width == 400 && image.height == Spectrogram.bands)
        let pixels = try #require(image.dataProvider?.data as Data?)
        let alpha = { (x: Int) in pixels[(Spectrogram.bands / 2 * image.bytesPerRow) + x * 4 + 3] }
        #expect(alpha(10) == 0)     // before the recording
        #expect(alpha(200) == 255)  // inside it
        #expect(alpha(390) == 0)    // after it
    }

    @Test func channelNamesFollowLiveKitsLayout() {
        let livekit = RecordingSource(kind: .observability, file: URL(fileURLWithPath: "/x"), origin: nil)
        #expect(livekit.channelName(0, of: 2, identical: false) == "User (left)")
        #expect(livekit.channelName(1, of: 2, identical: false) == "Agent (right)")
        let egress = RecordingSource(kind: .egress, file: URL(fileURLWithPath: "/x"), origin: nil)
        #expect(egress.channelName(0, of: 1, identical: true) == "Mix (both channels identical)")
        #expect(egress.channelName(0, of: 2, identical: false) == "Left")
        #expect(egress.channelName(1, of: 2, identical: false) == "Right")
        let routed = RecordingSource(kind: .egress, file: URL(fileURLWithPath: "/x"), origin: nil, userLeftAgentRight: true)
        #expect(routed.channelName(0, of: 2, identical: false) == "User (left)")
        #expect(routed.channelName(0, of: 3, identical: false) == "Channel 1")
    }
}

@Suite struct AlignmentTests {
    /// Bursts of a tone at irregular times, like turns of speech, starting `delay` seconds into the file.
    private func bursts(delay: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = 48_000 * 12
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let turns: [(Double, Double)] = [(0.5, 1.2), (2.0, 0.4), (3.1, 2.0), (6.0, 0.7), (7.5, 1.5)]
        for i in 0..<count {
            let t = Double(i) / 48_000 - delay
            let on = turns.contains { t >= $0.0 && t < $0.0 + $0.1 }
            buffer.floatChannelData![0][i] = on ? Float(0.4 * sin(2 * .pi * 300 * t)) : 0
        }
        try file.write(from: buffer)
        return url
    }

    @Test func findsTheTrueStartOffsetNearTheReportedOne() throws {
        let early = try bursts(delay: 0), late = try bursts(delay: 0.75)
        defer { try? FileManager.default.removeItem(at: early); try? FileManager.default.removeItem(at: late) }
        let a = try Spectrogram.compute(file: early), b = try Spectrogram.compute(file: late)
        // `late` has 0.75 s of lead-in, so the same sounds come 0.75 s later in it: `early` starts 0.75 s after it.
        let offset = try #require(a.startOffset(from: b, expected: 0.5))
        #expect(abs(offset - 0.75) <= 0.011)
    }

    @Test func findsTheStartOffsetFarFromTheReportedOne() throws {
        let early = try bursts(delay: 0), late = try bursts(delay: 0.75)
        defer { try? FileManager.default.removeItem(at: early); try? FileManager.default.removeItem(at: late) }
        let a = try Spectrogram.compute(file: early), b = try Spectrogram.compute(file: late)
        // The clocks disagree by about 25 s, as egress and LiveKit's recording can.
        let offset = try #require(a.startOffset(from: b, expected: -25, range: 60))
        #expect(abs(offset - 0.75) <= 0.011)
    }

    @Test func refusesToAlignUnrelatedRecordings() throws {
        let tones = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: tones, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 12)!
        buffer.frameLength = 48_000 * 12
        for i in 0..<(48_000 * 12) { buffer.floatChannelData![0][i] = (i / 48_000) % 3 == 2 ? 0.3 : 0 }
        try file.write(from: buffer)
        let speech = try bursts(delay: 0)
        defer { try? FileManager.default.removeItem(at: tones); try? FileManager.default.removeItem(at: speech) }
        #expect(try Spectrogram.compute(file: speech).startOffset(from: Spectrogram.compute(file: tones), expected: 0) == nil)
    }
}

@Suite struct FlagTests {
    let t0 = Date(timeIntervalSince1970: 1_794_665_497)
    var flag: Flag { Flag(start: t0, end: t0.addingTimeInterval(9.4), note: "Ma came out as static") }

    private func span(_ id: String, from: TimeInterval, to: TimeInterval) throws -> Span {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Span(json: try json(#"{"spanId":"\#(id)","name":"\#(id)","startTime":"\#(iso.string(from: t0.addingTimeInterval(from)))","endTime":"\#(iso.string(from: t0.addingTimeInterval(to)))"}"#), index: 0)
    }

    @Test func coversLogLinesInsideWithALittleSlack() {
        #expect(flag.covers(t0.addingTimeInterval(4)))
        #expect(flag.covers(t0.addingTimeInterval(-0.3)))
        #expect(!flag.covers(t0.addingTimeInterval(11)))
        #expect(!flag.covers(nil))
    }

    @Test func marksSpansInsideButNotTheSessionAroundIt() throws {
        #expect(flag.marks(try span("tts_request", from: 0.1, to: 1.4)))
        #expect(flag.marks(try span("agent_turn", from: -0.2, to: 9.2)))
        #expect(!flag.marks(try span("agent_session", from: -300, to: 200)))
        #expect(!flag.marks(try span("next_turn", from: 20, to: 22)))
    }
}

@Suite struct PlaybackFileTests {
    /// LiveKit's recording of RM_YKzvGTR8nqoi, if it is cached on this Mac: AVPlayer called it 381.8 s, decoding gives 494.2 s.
    @Test func copiesARecordingAVPlayerMistimes() async throws {
        let original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LiveKitObserver/livekit/RM_YKzvGTR8nqoi.ogg")
        guard FileManager.default.fileExists(atPath: original.path) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ogg")
        try FileManager.default.copyItem(at: original, to: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("playback.caf")) }
        #expect(await PlaybackFile.needsCopy(url))
        let played = await PlaybackFile.timed(url)
        #expect(played.pathExtension == "caf")
        let decoded = try AVAudioFile(forReading: url), copy = try AVAudioFile(forReading: played)
        #expect(abs(Int64(decoded.length) - Int64(copy.length)) < 4800)
        let seconds = try await AVURLAsset(url: played).load(.duration).seconds
        #expect(abs(seconds - Double(decoded.length) / decoded.processingFormat.sampleRate) < 0.1)
    }
}
