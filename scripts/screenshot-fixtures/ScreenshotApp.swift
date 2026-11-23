import AppKit
import Foundation
import ObserverCore
import SwiftUI

/// Compiled only by prepare-screenshots.py into a separate, offline app bundle.
@main
struct ScreenshotApp: App {
    @State private var model: AppModel?
    @State private var problem: String?
    var body: some Scene {
        Window("LiveKit Observer", id: "demo") {
            Group {
                if let model { ContentView().environment(model) }
                else if let problem { Text(problem).padding() }
                else { ProgressView("Preparing synthetic demo data…") }
            }
            .frame(minWidth: 1300, minHeight: 900)
            .preferredColorScheme(.dark)
            .task {
                guard model == nil else { return }
                do { model = try await ScreenshotFixture.makeModel() }
                catch { problem = error.localizedDescription }
            }
        }
        .defaultSize(width: 1400, height: 960)
    }
}

@MainActor enum ScreenshotFixture {
    static var root: URL { Bundle.main.resourceURL!.appendingPathComponent("DemoData") }
    static var scratch: URL { FileManager.default.temporaryDirectory.appendingPathComponent("observer-screenshot-fixture") }
    static let store = AttachmentStore(root: scratch.appendingPathComponent("captures"))
    static let project = "Acme Voice Demo"
    static func json(_ object: Any) throws -> JSONValue {
        JSONValue(any: object)
    }
    static func makeModel() async throws -> AppModel {
        UserDefaults.standard.set(0, forKey: "spectrogramSpan")
        UserDefaults.standard.set(false, forKey: "agentHealthMonitoring")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Double]
        let start = Date(timeIntervalSince1970: meta["epoch"]!)
        func date(_ seconds: Double) -> String { start.addingTimeInterval(seconds).formatted(.iso8601) }
        let model = AppModel(project: project, sessionStore: SessionStore(url: scratch.appendingPathComponent("index.sqlite")), mediaCacheDirectory: scratch.appendingPathComponent("media"))
        model.projects = [ProjectRef(id: project, name: "Acme Voice · Demo", url: "wss://voice.example.com", isDefault: true, workspaceName: "Demo Workspace")]
        model.signedInUser = "demo@example.com"
        let titles = ["Support · +1 202-555-0101", "Appointment assistant", "Order status · +1 202-555-0102", "Travel concierge", "Support follow-up", "Product information", "Account help", "Appointment reminder"]
        for (index, title) in titles.enumerated() {
            let id = "RM_DEMO_" + String(format: "%04d", index + 1)
            let began = -Double(index * 900)
            let duration = index == 0 ? 36.0 : Double(72 + index * 23)
            let session = LiveKitSession(json: try json(["sessionId": id, "roomName": title, "status": "ended", "startedAt": date(began), "endedAt": date(began + duration), "numParticipants": 2, "hasDetailData": true]))!
            let recording = EgressRecording(manifest: try json(["egress_id": "EG_DEMO_\(index)", "room_id": id, "room_name": title, "started_at": start.addingTimeInterval(began).timeIntervalSince1970 * 1e9, "ended_at": start.addingTimeInterval(began + duration).timeIntervalSince1970 * 1e9, "files": [["filename": "demo/\(id).ogg"]]]))!
            model.rows.append(SessionRow(id: id, session: session, recording: recording))
        }
        model.coverage = SessionCoverage(fetchedAt: start.addingTimeInterval(120), complete: true)
        model.liveKitLoaded = true
        let detail = SessionDetail(row: model.rows[0])
        let lines: [(String, Double, Double, String)] = [
            ("assistant", 0.8, 3.2, "Thanks for calling Acme. How can I help today?"),
            ("user", 3.6, 6.0, "I'd like to check the delivery date for my order."),
            ("assistant", 6.5, 9.1, "Of course. Do you have your order number handy?"),
            ("user", 9.5, 11.5, "Yes, it's the demo order A-1042."),
            ("assistant", 12.1, 16.2, "I found it. Your package is scheduled to arrive on Tuesday."),
            ("user", 16.8, 19.2, "Great. Can I get a tracking link?"),
            ("assistant", 19.9, 23.5, "Yes. The tracking link is available in your order confirmation."),
            ("user", 24.1, 26.2, "Perfect, I see it now. Thank you."),
            ("assistant", 26.8, 30.0, "You're welcome. Is there anything else I can help with?"),
            ("user", 30.5, 32.1, "No, that's everything."),
            ("assistant", 32.6, 35.1, "Thanks for calling Acme. Have a wonderful day!")
        ]
        detail.transcript = try lines.enumerated().map { index, line in
            TranscriptItem(json: try json(["id": "demo-turn-\(index)", "timestamp": date(line.1), "message": ["role": line.0, "text": line.3, "startedSpeakingAt": date(line.1), "stoppedSpeakingAt": date(line.2), "e2eLatencyMs": 450 + index * 31, "llmTtftMs": 130 + index * 7, "ttsTtfbMs": 85 + index * 3, "endOfTurnDelayMs": 310, "transcriptionDelayMs": 120, "transcriptConfidence": 0.98]]), index: index)
        }
        detail.logs = try [("INFO", 0.2, "Agent connected and ready"), ("WARN", 12.8, "Elevated packet arrival delay observed"), ("INFO", 35.8, "Session completed successfully")].enumerated().map { index, log in
            LogRecord(json: try json(["timestamp": date(log.1), "level": log.0, "logger": "acme.voice", "message": log.2]), index: index)
        }
        detail.spans = try lines.enumerated().filter { $0.element.0 == "assistant" }.map { index, line in
            Span(json: try json(["spanId": "demo-tts-\(index)", "name": "tts_request", "startTime": date(line.1), "endTime": date(line.2), "status": "OK", "attributes": ["lk.cloud_agent_id": "CA_DEMO", "lk.pii.input_text": line.3, "lk.tts_metrics": ["audio_duration": line.2 - line.1, "ttfb": 0.09, "metadata": ["model_name": "cartesia/sonic-3", "model_provider": "livekit"]]]]), index: index)
        }
        detail.spans.append(Span(json: try json(["spanId": "demo-llm", "name": "llm_request", "startTime": date(6.1), "endTime": date(6.5), "status": "OK", "attributes": ["gen_ai.request.model": "openai/gpt-4.1-mini", "gen_ai.provider.name": "livekit", "gen_ai.usage.input_tokens": 2400, "gen_ai.usage.output_tokens": 460]]), index: 99))
        detail.metrics = [MetricPoint(json: try json(["name": "lk.agents.usage.stt_audio_duration", "value": 36, "attributes": ["model_name": "deepgram/nova-3", "model_provider": "livekit"]]), index: 0)]
        detail.insights = SessionInsights(transcript: detail.transcript, logs: detail.logs, spans: detail.spans)
        detail.dataState = "settled"
        detail.room = RoomUsage(participants: [.init(identity: "agent-demo", seconds: 36), .init(identity: "caller-demo", seconds: 36), .init(identity: "EG_DEMO", seconds: 36)], bytesOut: 420_000)
        let audio = root.appendingPathComponent("demo-audio.wav")
        let channels = [root.appendingPathComponent("channel-0.wav"), root.appendingPathComponent("channel-1.wav")]
        let spectrum = try Spectrogram.compute(file: audio)
        for kind in [RecordingSource.Kind.egress, .observability] {
            detail.sources.append(RecordingSource(kind: kind, file: audio, origin: start, userLeftAgentRight: true))
            detail.spectrograms[kind] = spectrum
            detail.channelFiles[kind] = channels
        }
        detail.alignment = .byAudio
        model.player.load(channels.enumerated().map { index, file in PlaybackTrack(id: TrackID(kind: .egress, channel: index), file: file, origin: start, pan: index == 0 ? -1 : 1) })
        model.skimmer.isEnabled = false
        let target = CaptureSession(projectKey: project, projectName: "Acme Voice · Demo", sessionID: detail.row.id, roomName: detail.row.roomName, startedAt: start, endedAt: start.addingTimeInterval(36))
        let capture = try await store.importFile(root.appendingPathComponent("support-call-demo.pcap"), session: target, limit: 20_000_000)
        let analysis = try CaptureAnalyzer.scan(await store.file(for: capture))
        var mapping = CaptureAudioMapping()
        for row in CaptureJitterOverview(analysis).series { mapping.assign(row.key.source.hasPrefix("192.0.2.") ? .user : .agent, to: row) }
        mapping.save(for: capture.id)
        await model.captures.load()
        detail.row.localCaptureSession = target
        model.rows[0] = detail.row
        model.selection = detail.row.id
        model.detail = detail
        return model
    }
}
