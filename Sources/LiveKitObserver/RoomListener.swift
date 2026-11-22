import ObserverCore
import Foundation
import LiveKit
import Observation
import SwiftUI

/// Talk and listen sessions share the SDK's audio device, so allow one across all windows.
@MainActor final class ObserverAudioLease {
    static let shared = ObserverAudioLease()
    private var owner: UUID?
    func acquire(_ id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id; return true
    }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

enum RoomListenToken {
    // Verified with lk 2.19.4 --help and a locally generated --dev token.
    // https://docs.livekit.io/frontends/reference/tokens-grants/#creating-a-subscribe-only-token
    static func arguments(room: String, identity: String) -> [String] {
        ["token", "create", "--join", "--room", room, "--identity", identity,
         "--name", "Observer listener", "--grant",
         #"{"canSubscribe":true,"canPublish":false,"canPublishData":false,"canUpdateOwnMetadata":false,"hidden":false}"#,
         "--valid-for", "1h", "--token-only"]
    }

    /// Inspect the CLI's result before use; the LiveKit server still verifies the JWT signature.
    static func validate(_ token: String, room: String, identity: String) throws {
        guard token.utf8.count <= 65536 else { throw failure }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { throw failure }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let claims = try? JSONValue.parse(data),
              claims["sub"]?.string == identity, let grant = claims["video"], grant["room"]?.string == room,
              grant["roomJoin"]?.bool == true, grant["canSubscribe"]?.bool == true,
              grant["canPublish"]?.bool == false, grant["canPublishData"]?.bool == false,
              !["roomAdmin", "roomCreate", "roomRecord", "ingressAdmin", "hidden"].contains(where: { grant[$0]?.bool == true })
        else { throw failure }
    }
    private static var failure: LiveKitCLIError { .init(kind: .failed, message: "The CLI did not return a listen-only token for this room. Update the LiveKit CLI and try again.") }
}

protocol RoomListenSource: Sendable {
    func rooms() async throws -> [LiveRoom]
    func listenerToken(room: String, identity: String) async throws -> String
}

extension LiveKitCLI: RoomListenSource {
    func listenerToken(room: String, identity: String) async throws -> String {
        let data = try await operation(RoomListenToken.arguments(room: room, identity: identity), json: false, timeout: 30)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RoomListenSnapshot {
    enum State { case listening, reconnecting, disconnected }
    struct Speaker: Identifiable {
        let id: String, name: String
        let level: Float
        let speaking: Bool
    }
    var state: State = .listening
    var speakers: [Speaker] = []
    var audioTracks = 0
    var message: String?
}

@MainActor protocol RoomListenConnection: AnyObject {
    func connect(url: String, token: String, roomID: String) async throws
    func refresh(volume: Double, output: String) async throws -> RoomListenSnapshot
    func disconnect() async
}

/// Never captures media, publishes tracks/data, dispatches agents, or deletes a room.
@MainActor final class LiveKitListenConnection: RoomListenConnection {
    private let room = Room()
    private var expectedRoomID: String?
    private var previousOutput: AudioDevice?
    private var appliedOutput: String?
    private var volumes: [ObjectIdentifier: Double] = [:]

    func connect(url: String, token: String, roomID: String) async throws {
        expectedRoomID = roomID
        // Manually subscribe only to audio, including tracks published after joining.
        try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false, enableMicrophone: false))
        try Task.checkCancellation()
        guard try await room.sid().stringValue == roomID else { throw roomChanged }
    }

    func refresh(volume: Double, output: String) async throws -> RoomListenSnapshot {
        if room.connectionState == .reconnecting { return .init(state: .reconnecting) }
        guard room.connectionState == .connected else {
            return .init(state: .disconnected, message: room.disconnectError?.localizedDescription ?? "Disconnected from the room.")
        }
        guard room.sid?.stringValue == expectedRoomID else { throw roomChanged }
        if appliedOutput != output {
            let device = output.isEmpty ? AudioManager.shared.defaultOutputDevice : AudioManager.shared.outputDevices.first { $0.id == output }
            guard let device else { throw LiveKitCLIError(kind: .failed, message: "The selected speakers are unavailable. Choose another audio output.") }
            if previousOutput == nil { previousOutput = AudioManager.shared.outputDevice }
            AudioManager.shared.outputDevice = device; appliedOutput = output
        }
        let participants = Array(room.remoteParticipants.values)
        let publications = participants.flatMap(\.audioTracks).compactMap { $0 as? RemoteTrackPublication }
        guard publications.count <= 256 else { throw LiveKitCLIError(kind: .busy, message: "This room exceeds Observer's limit of 256 audio tracks.") }
        var activeTracks = Set<ObjectIdentifier>(), subscribed = 0, denied = 0
        for publication in publications {
            try Task.checkCancellation()
            guard publication.isSubscriptionAllowed else { denied += 1; continue }
            try await publication.set(subscribed: true)
            if let track = publication.track as? RemoteAudioTrack {
                let key = ObjectIdentifier(track); activeTracks.insert(key); subscribed += 1
                if volumes[key] != volume { track.volume = volume; volumes[key] = volume }
            }
        }
        volumes = volumes.filter { activeTracks.contains($0.key) }
        let speakers = participants.filter { !$0.audioTracks.isEmpty }.map { participant in
            RoomListenSnapshot.Speaker(id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? "unknown",
                name: participant.name.flatMap { $0.isEmpty ? nil : $0 } ?? participant.identity?.stringValue ?? "Participant",
                level: participant.audioLevel.isFinite ? min(1, max(0, participant.audioLevel)) : 0, speaking: participant.isSpeaking)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return .init(speakers: speakers, audioTracks: subscribed,
                     message: denied > 0 ? "The room does not allow access to \(denied) audio track(s)." : nil)
    }

    func disconnect() async {
        await room.disconnect()
        if let previousOutput { AudioManager.shared.outputDevice = previousOutput }
        previousOutput = nil; appliedOutput = nil; expectedRoomID = nil; volumes = [:]
    }
    private var roomChanged: LiveKitCLIError { .init(kind: .notReady, message: "That room has ended or was replaced. Refresh Rooms and select the live room again.") }
}

@MainActor @Observable final class RoomListenSession {
    enum Phase { case idle, connecting, listening, reconnecting, leaving }
    private(set) var phase: Phase = .idle
    private(set) var snapshot = RoomListenSnapshot()
    private(set) var startedAt: Date?
    var message: String?
    var volume: Double = 1
    var muted = false
    var output = ""
    var effectiveVolume: Double { muted ? 0 : volume.isFinite ? min(1, max(0, volume)) : 1 }
    private let connection: any RoomListenConnection
    private let lease: ObserverAudioLease
    private let owner = UUID()
    private var setupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(connection: (any RoomListenConnection)? = nil, lease: ObserverAudioLease? = nil) {
        self.connection = connection ?? LiveKitListenConnection(); self.lease = lease ?? .shared
    }

    func start(source: any RoomListenSource, projectURL: String, target: LiveRoom) async {
        guard phase == .idle else { return }
        guard let url = URL(string: projectURL), url.scheme == "wss", url.host != nil, !target.name.isEmpty else {
            message = "A valid project URL and live room are required."; return
        }
        guard lease.acquire(owner) else { message = "End the active Observer call or listener before joining another room."; return }
        phase = .connecting; message = nil; startedAt = nil; snapshot = .init()
        let task = Task { await connect(source: source, projectURL: projectURL, target: target) }
        setupTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func connect(source: any RoomListenSource, projectURL: String, target: LiveRoom) async {
        do {
            let current = try await source.rooms()
            try Task.checkCancellation()
            guard current.contains(where: { $0.id == target.id && $0.name == target.name }) else {
                throw LiveKitCLIError(kind: .notReady, message: "This room is no longer live. Refresh Rooms before listening.")
            }
            let identity = "observer-listener-" + owner.uuidString.lowercased()
            let token = try await source.listenerToken(room: target.name, identity: identity)
            try Task.checkCancellation()
            try RoomListenToken.validate(token, room: target.name, identity: identity)
            try await connection.connect(url: projectURL, token: token, roomID: target.id)
            try Task.checkCancellation()
            snapshot = try await connection.refresh(volume: effectiveVolume, output: output)
            try Task.checkCancellation()
            guard snapshot.state != .disconnected else { throw LiveKitCLIError(kind: .failed, message: snapshot.message ?? "The room disconnected.") }
            phase = snapshot.state == .reconnecting ? .reconnecting : .listening; startedAt = .now
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self else { return }; await refreshPlayback()
                }
            }
        } catch {
            // stop() owns cleanup while cancelling setup; it waits for this task first.
            guard phase != .leaving else { return }
            message = error is CancellationError ? "Joining cancelled." : error.localizedDescription
            phase = .leaving
            await connection.disconnect(); phase = .idle; lease.release(owner)
        }
    }

    func refreshPlayback() async {
        guard phase == .listening || phase == .reconnecting else { return }
        do {
            let value = try await connection.refresh(volume: effectiveVolume, output: output)
            guard phase == .listening || phase == .reconnecting else { return }
            snapshot = value
            if value.state == .disconnected { message = value.message ?? "The room disconnected."; await stop() }
            else { phase = value.state == .reconnecting ? .reconnecting : .listening }
        } catch is CancellationError { }
        catch { message = error.localizedDescription; await stop() }
    }

    func stop() async {
        guard phase != .leaving, phase != .idle else { return }
        phase = .leaving
        setupTask?.cancel(); monitorTask?.cancel(); monitorTask = nil
        await setupTask?.value; setupTask = nil
        await connection.disconnect()
        snapshot = .init(); phase = .idle; lease.release(owner)
    }
}

struct RoomListenView: View {
    let project: ProjectRef
    let target: LiveRoom
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var listener = RoomListenSession()
    var body: some View {
        @Bindable var listener = listener
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Listen live", systemImage: "headphones").font(.title2.bold()); Spacer(); Text(project.name).foregroundStyle(project.color) }
            Text(target.name).font(.headline).textSelection(.enabled)
            Label("Listen only · Microphone off", systemImage: "mic.slash.fill").foregroundStyle(.secondary)
            Text("You appear in the room as Observer listener. Leave disconnects only this listener.").font(.caption).foregroundStyle(.secondary)
            Picker("Speakers", selection: $listener.output) {
                Text("System default").tag("")
                ForEach(AudioManager.shared.outputDevices) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button { listener.muted.toggle() } label: { Label(listener.muted ? "Unmute playback" : "Mute playback", systemImage: listener.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                Slider(value: $listener.volume, in: 0...1).accessibilityLabel("Playback volume")
                Text("\(Int(listener.volume * 100))%").monospacedDigit().frame(width: 42)
            }
            if listener.phase == .connecting || listener.phase == .reconnecting || listener.phase == .leaving {
                HStack { ProgressView().controlSize(.small); Text(listener.phase == .connecting ? "Joining room…" : listener.phase == .reconnecting ? "Reconnecting…" : "Leaving room…") }
            }
            if listener.phase == .listening {
                HStack { Text("Listening · \(listener.snapshot.audioTracks) audio tracks"); Spacer(); if let start = listener.startedAt { Text(start, style: .timer).monospacedDigit() } }
                if listener.snapshot.speakers.isEmpty { Text("Waiting for participants to publish audio…").foregroundStyle(.secondary) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(listener.snapshot.speakers) { speaker in
                                HStack {
                                    Image(systemName: speaker.speaking ? "waveform" : "speaker.fill").foregroundStyle(speaker.speaking ? .green : .secondary)
                                    Text(speaker.name).lineLimit(1); Spacer()
                                    ProgressView(value: Double(speaker.level), total: 1).frame(width: 100).help("Incoming audio level")
                                }
                            }
                        }
                    }.frame(maxHeight: 220)
                }
            }
            if let message = listener.message ?? listener.snapshot.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                if listener.phase == .idle {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { Task { await start() } }
                } else {
                    Button(listener.phase == .connecting ? "Cancel" : "Leave") { Task { await listener.stop(); dismiss() } }.disabled(listener.phase == .leaving)
                }
            }
        }.padding(24).frame(width: 560)
        .task { await start() }
        .task(id: "\(listener.volume):\(listener.muted):\(listener.output)") { await listener.refreshPlayback() }
        .interactiveDismissDisabled(listener.phase != .idle)
        .onDisappear { Task { await listener.stop() } }
    }
    private func start() async {
        guard app.projectIdentity == project.id, let cli = app.cli else { listener.message = "Return to \(project.name) and connect the LiveKit CLI to listen."; return }
        app.player.pause(); app.skimmer.end()
        await listener.start(source: cli, projectURL: project.url, target: target)
    }
}
