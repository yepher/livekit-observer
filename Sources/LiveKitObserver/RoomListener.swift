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
    // canPublishData lets Observer call the agent's RPC methods; it never publishes media.
    static func arguments(room: String, identity: String) -> [String] {
        ["token", "create", "--join", "--room", room, "--identity", identity,
         "--name", "Observer listener", "--grant",
         #"{"canSubscribe":true,"canPublish":false,"canPublishData":true,"canUpdateOwnMetadata":false,"hidden":false}"#,
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
              grant["canPublish"]?.bool == false, grant["canPublishData"]?.bool == true,
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
    /// A remote participant as the room connection sees it right now.
    struct Member: Identifiable {
        let id: String, name: String
        var kind = "standard"
        var level: Float = 0
        var speaking = false
        var quality = "unknown"
        var agentState: String?
        var audioTracks = 0
    }
    struct Server: Equatable {
        var region = "", node = "", version = ""
        var recording = false
    }
    var state: State = .listening
    var members: [Member] = []
    var speakers: [Member] { members.filter { $0.audioTracks > 0 } }
    var audioTracks = 0
    var server = Server()
    var roomMetadata = ""
    var message: String?
}

@MainActor protocol RoomListenConnection: AnyObject {
    func connect(url: String, token: String, roomID: String) async throws
    func refresh(volume: Double, output: String) async throws -> RoomListenSnapshot
    func performRpc(to identity: String, method: String, payload: String, timeout: TimeInterval) async throws -> String
    func disconnect() async
}

/// Never captures media, publishes tracks, dispatches agents, or deletes a room.
/// It sends data only for RPC calls the user makes.
@MainActor final class LiveKitListenConnection: RoomListenConnection {
    private let room = Room()
    private let log: RoomMonitorLog?
    private let recorder: RoomEventRecorder?
    private var expectedRoomID: String?
    private var previousOutput: AudioDevice?
    private var appliedOutput: String?
    private var volumes: [ObjectIdentifier: Double] = [:]
    private var transcribing = false

    init(log: RoomMonitorLog? = nil) {
        self.log = log
        recorder = log.map(RoomEventRecorder.init)
        if let recorder { room.add(delegate: recorder) }
    }

    func connect(url: String, token: String, roomID: String) async throws {
        expectedRoomID = roomID
        if log != nil, !transcribing {
            transcribing = (try? await room.registerTextStreamHandler(for: RoomMonitorText.transcriptionTopic) { [weak self] reader, identity in
                await self?.transcribe(reader, from: identity.stringValue)
            }) != nil
        }
        // Manually subscribe only to audio, including tracks published after joining.
        try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false, enableMicrophone: false))
        try Task.checkCancellation()
        guard try await room.sid().stringValue == roomID else { throw roomChanged }
        let present = Array(room.remoteParticipants.values)
        recorder?.seed(present)
        var detail: [String: Any] = ["participants": present.map { ["identity": RoomMonitorText.who($0), "kind": RoomMonitorText.kind($0.kind)] }]
        if let region = room.serverRegion { detail["region"] = region }
        if let node = room.serverNodeId { detail["node"] = node }
        if let version = room.serverVersion { detail["serverVersion"] = version }
        recorder?.note(RoomMonitorEvent(.info, .connection, "Observer joined with \(present.count) other participant\(present.count == 1 ? "" : "s")",
                                        detail: RoomMonitorText.json(detail)))
    }

    /// Streams arrive per segment; the text so far replaces the caption each time a piece arrives.
    private func transcribe(_ reader: TextStreamReader, from identity: String) async {
        let id = reader.info.attributes["lk.segment_id"] ?? reader.info.id
        let final = reader.info.attributes["lk.transcription_final"] == "true"
        let agent = room.remoteParticipants[Participant.Identity(from: identity)]?.kind == .agent
        var text = ""
        log?.caption(id: id, speaker: identity, agent: agent, text: text, final: final, open: true)
        do {
            for try await chunk in reader {
                text += chunk
                log?.caption(id: id, speaker: identity, agent: agent, text: text, final: final, open: true)
            }
        } catch {
            log?.record(RoomMonitorEvent(.warning, .data, "Transcript stream ended early: \(error.localizedDescription)", participant: identity))
        }
        log?.caption(id: id, speaker: identity, agent: agent, text: text, final: final, open: false)
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
        let members = participants.map { participant in
            RoomListenSnapshot.Member(id: RoomMonitorText.who(participant),
                name: participant.name.flatMap { $0.isEmpty ? nil : $0 } ?? participant.identity?.stringValue ?? "Participant",
                kind: RoomMonitorText.kind(participant.kind),
                level: participant.audioLevel.isFinite ? min(1, max(0, participant.audioLevel)) : 0, speaking: participant.isSpeaking,
                quality: RoomMonitorText.quality(participant.connectionQuality),
                agentState: participant.attributes[RoomMonitorText.agentStateAttribute], audioTracks: participant.audioTracks.count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let server = RoomListenSnapshot.Server(region: room.serverRegion ?? "", node: room.serverNodeId ?? "", version: room.serverVersion ?? "", recording: room.isRecording)
        return .init(members: members, audioTracks: subscribed, server: server, roomMetadata: room.metadata ?? "",
                     message: denied > 0 ? "The room does not allow access to \(denied) audio track(s)." : nil)
    }

    func performRpc(to identity: String, method: String, payload: String, timeout: TimeInterval) async throws -> String {
        guard room.connectionState == .connected else { throw LiveKitCLIError(kind: .notReady, message: "Join the room before calling RPC methods.") }
        return try await room.localParticipant.performRpc(destinationIdentity: Participant.Identity(from: identity), method: method,
                                                          payload: payload, responseTimeout: timeout)
    }

    func disconnect() async {
        await room.disconnect()
        if transcribing { await room.unregisterTextStreamHandler(for: RoomMonitorText.transcriptionTopic); transcribing = false }
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
    /// Room events and the live transcript, kept across rejoins until cleared.
    let log: RoomMonitorLog
    private let connection: any RoomListenConnection
    private let lease: ObserverAudioLease
    private let owner = UUID()
    private var setupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(connection: (any RoomListenConnection)? = nil, lease: ObserverAudioLease? = nil, log: RoomMonitorLog? = nil) {
        let log = log ?? RoomMonitorLog()
        self.log = log
        self.connection = connection ?? LiveKitListenConnection(log: log); self.lease = lease ?? .shared
    }

    var joined: Bool { phase == .listening || phase == .reconnecting }

    /// Calls a method the participant registered with RPC, and logs the call and its answer.
    func performRpc(to identity: String, method: String, payload: String, timeout: TimeInterval = 15) async throws -> String {
        guard joined else { throw LiveKitCLIError(kind: .notReady, message: "Join the room before calling RPC methods.") }
        log.record(RoomMonitorEvent(.info, .rpc, "Called \(method)", participant: identity, detail: payload.isEmpty ? nil : payload))
        do {
            let response = try await connection.performRpc(to: identity, method: method, payload: payload, timeout: timeout)
            log.record(RoomMonitorEvent(.info, .rpc, "\(method) answered · \(response.utf8.count) bytes", participant: identity, detail: response.isEmpty ? nil : RoomMonitorText.payload(Data(response.utf8))))
            return response
        } catch {
            log.record(RoomMonitorEvent(.error, .rpc, "\(method) failed: \(Self.describe(error))", participant: identity))
            throw error
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? RpcError { return "\(error.message) (code \(error.code))" + (error.data.isEmpty ? "" : " · \(error.data)") }
        return error.localizedDescription
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
            log.record(RoomMonitorEvent(.error, .connection, "Could not join: \(message ?? "")"))
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
        log.record(RoomMonitorEvent(.info, .connection, "Observer left the room"))
        snapshot = .init(); phase = .idle; lease.release(owner)
    }
}
