import ObserverCore
import AVFoundation
import LiveKit
import Observation
import SwiftUI

@MainActor @Observable
final class TalkSession {
    private static var activeCall: UUID?
    private let identity = UUID()
    private let room = Room()
    private(set) var cli: LiveKitCLI?
    private var createdRoom: LiveRoom?
    private var sampleTask: Task<Void, Never>?
    var connecting = false
    var connected = false
    var ending = false
    var muted = false
    var level: Float = 0
    var agentState = "Waiting for agent"
    var startedAt: Date?
    var message: String?
    var lines: [Line] = []
    struct Line: Identifiable { let id: String, speaker: String; var text: String }
    var roomID: String? { createdRoom?.id }

    func start(cli: LiveKitCLI, projectURL: String, agent: String, roomName: String, metadata: String, input: String, output: String) async {
        guard !connecting, !connected, Self.activeCall == nil else { message = "End the active Observer call before starting another."; return }
        guard URL(string: projectURL)?.scheme == "wss", !roomName.isEmpty else { message = "A valid project URL and room name are required."; return }
        Self.activeCall = identity; connecting = true; self.cli = cli; message = nil
        defer { connecting = false }
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw InferenceClient.Failure(message: "Microphone access is disabled. Enable it for Observer in System Settings → Privacy & Security → Microphone.") }
            try Task.checkCancellation()
            guard try await !cli.rooms().contains(where: { $0.name == roomName }) else { throw InferenceClient.Failure(message: "That room already exists. Choose a new room name for this test call.") }
            if let device = AudioManager.shared.inputDevices.first(where: { $0.id == input }) { AudioManager.shared.inputDevice = device }
            if let device = AudioManager.shared.outputDevices.first(where: { $0.id == output }) { AudioManager.shared.outputDevice = device }
            let created = try await cli.operationJSON(["room", "create", "--empty-timeout", "120", "--departure-timeout", "10", roomName])
            guard let liveRoom = LiveRoom(json: created) else { throw InferenceClient.Failure(message: "The CLI did not return the created room.") }; createdRoom = liveRoom
            let tokenData = try await cli.operation(["token", "create", "--join", "--room", roomName, "--identity", "observer-\(identity.uuidString)", "--allow-source", "microphone", "--metadata", metadata, "--valid-for", "1h", "--token-only"], json: false)
            let token = String(decoding: tokenData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.split(separator: ".").count == 3 else { throw InferenceClient.Failure(message: "The CLI did not return a join token.") }
            try await room.registerTextStreamHandler(for: "lk.transcription") { [weak self] reader, speaker in
                var text = ""
                do {
                    for try await chunk in reader {
                        guard text.utf8.count + chunk.utf8.count <= 16384 else { break }
                        text += chunk
                        await self?.received(id: reader.info.id, speaker: speaker.stringValue, text: text)
                    }
                } catch { /* An interrupted text stream may still have useful partial text. */ }
            }
            try await room.connect(url: projectURL, token: token)
            try Task.checkCancellation()
            try await room.localParticipant.setMicrophone(enabled: true, captureOptions: AudioCaptureOptions(echoCancellation: true, noiseSuppression: true))
            // An unnamed agent auto-joins new rooms; explicitly dispatch only named agents.
            if !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try await cli.operationJSON(["dispatch", "create", "--room", roomName, "--agent-name", agent, "--json"])
            }
            try Task.checkCancellation()
            connected = true; startedAt = .now
            sampleTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    level = room.localParticipant.audioLevel
                    agentState = room.remoteParticipants.values.compactMap { $0.attributes["lk.agent.state"] }.first ?? "Waiting for agent"
                    if room.connectionState == .disconnected { message = "The call disconnected."; await end(); return }
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
        } catch {
            message = error is CancellationError ? "Call setup cancelled." : error.localizedDescription
            await end()
        }
    }
    private func received(id: String, speaker: String, text: String) {
        if let index = lines.firstIndex(where: { $0.id == id }) { lines[index].text = text }
        else { lines.append(Line(id: id, speaker: speaker, text: text)); if lines.count > 500 { lines.removeFirst(lines.count - 500) } }
    }
    func toggleMute() async {
        do { try await room.localParticipant.setMicrophone(enabled: muted); muted.toggle() }
        catch { message = error.localizedDescription }
    }
    func end() async {
        guard !ending else { return }; ending = true
        defer { ending = false; if Self.activeCall == identity { Self.activeCall = nil } }
        sampleTask?.cancel(); sampleTask = nil
        await room.disconnect(); connected = false; level = 0
        // End only the test room this call created. SID protects against a later room reusing its name.
        if let cli, let createdRoom {
            do {
                // Cleanup must survive cancellation of setup or the monitoring task.
                try await Task.detached {
                    if try await cli.rooms().contains(where: { $0.id == createdRoom.id && $0.name == createdRoom.name }) {
                        _ = try await cli.operation(["room", "delete", createdRoom.name], json: false)
                    }
                }.value
            } catch { message = "Disconnected, but test-room cleanup failed: \(error.localizedDescription). Check Rooms." }
        }
    }
}

struct TalkView: View {
    let project: ProjectRef
    let initialAgent: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var call = TalkSession()
    @State private var agent = ""
    @State private var name = "observer-" + UUID().uuidString.lowercased()
    @State private var metadata = "{}"
    @State private var input = ""
    @State private var output = ""
    @State private var setup: Task<Void, Never>?
    @State private var waiting: Task<Void, Never>?
    @State private var waitingMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Talk to agent").font(.title2.bold()); Spacer(); Text(project.name).foregroundStyle(project.color) }
            if !call.connected && call.startedAt == nil {
                TextField("Agent dispatch name (blank for default)", text: $agent)
                TextField("New room name", text: $name)
                DisclosureGroup("Participant metadata") { TextEditor(text: $metadata).font(.caption.monospaced()).frame(height: 70) }
                Picker("Microphone", selection: $input) { Text("System default").tag(""); ForEach(AudioManager.shared.inputDevices) { Text($0.name).tag($0.id) } }
                Picker("Speakers", selection: $output) { Text("System default").tag(""); ForEach(AudioManager.shared.outputDevices) { Text($0.name).tag($0.id) } }
                Text("Starts a live call in this project using your microphone. Normal agent and inference charges apply. End Call closes the test room and disconnects its participants.").font(.caption).foregroundStyle(.secondary)
            }
            if call.connected {
                HStack { Label(call.agentState, systemImage: "waveform"); Spacer(); if let date = call.startedAt { Text(date, style: .timer).monospacedDigit() } }
                ProgressView(value: Double(call.level), total: 1).help("Microphone level")
            }
            if !call.lines.isEmpty {
                ScrollView { LazyVStack(alignment: .leading, spacing: 10) { ForEach(call.lines) { line in VStack(alignment: .leading) { Text(line.speaker).font(.caption).foregroundStyle(.secondary); Text(line.text).textSelection(.enabled) } } } }.frame(height: 260)
            }
            if let message = call.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let waitingMessage { Text(waitingMessage).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                if call.connecting { ProgressView(); Button("Cancel") { setup?.cancel() } }
                else if call.connected {
                    Button(call.muted ? "Unmute" : "Mute") { Task { await call.toggleMute() } }
                    Button("End call", role: .destructive) { end() }.disabled(call.ending)
                } else {
                    Button("Close") { waiting?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    if call.startedAt == nil { Button("Start call") { start() }.disabled(call.ending) }
                }
            }
        }.padding(24).frame(width: 600)
        .onAppear { agent = initialAgent }
        .interactiveDismissDisabled(call.connected || call.connecting || call.ending)
        .onDisappear { setup?.cancel(); waiting?.cancel(); Task { await call.end() } }
    }
    private func start() {
        guard let cli = app.cli, app.projectIdentity == project.id else { return }
        app.player.pause(); app.skimmer.end()
        setup = Task { await call.start(cli: cli, projectURL: project.url, agent: agent, roomName: name, metadata: metadata, input: input, output: output) }
    }
    private func end() {
        guard let cli = call.cli else { return }
        waiting = Task {
            await call.end()
            guard let id = call.roomID else { return }
            waitingMessage = "Session will be ready in about a minute. Waiting for LiveKit…"
            for _ in 0..<36 {
                do {
                    try Task.checkCancellation()
                    if let session = try? await cli.session(id), session.hasDetailData {
                        guard app.projectIdentity == project.id else { waitingMessage = "Session ready: \(id). Return to \(project.name) to review it."; return }
                        await app.openRemoteSession(id); dismiss(); return
                    }
                    try await Task.sleep(for: .seconds(5))
                } catch { return }
            }
            waitingMessage = "Session data is still arriving. Open \(call.roomID ?? name) from Sessions after refreshing."
        }
    }
}
