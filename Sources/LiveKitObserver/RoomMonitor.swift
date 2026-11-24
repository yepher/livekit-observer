import ObserverCore
import Foundation
import LiveKit
import Observation

/// One thing that happened in a live room while Observer was in it.
struct RoomMonitorEvent: Identifiable, Sendable {
    enum Level: String, CaseIterable, Sendable { case info = "Info", warning = "Warning", error = "Error" }
    enum Category: String, CaseIterable, Sendable {
        case connection = "Connection", participant = "Participants", track = "Tracks", data = "Data", agent = "Agent", rpc = "RPC", room = "Room"
        var symbol: String {
            switch self {
            case .connection: "network"; case .participant: "person.2"; case .track: "waveform"; case .data: "envelope"
            case .agent: "person.wave.2"; case .rpc: "arrow.left.arrow.right"; case .room: "house"
            }
        }
    }
    let id = UUID()
    var date = Date()
    let level: Level
    let category: Category
    let participant: String?
    let message: String
    /// Pretty-printed JSON or text behind the event, shown when it is expanded.
    let detail: String?

    init(_ level: Level = .info, _ category: Category, _ message: String, participant: String? = nil, detail: String? = nil) {
        self.level = level; self.category = category; self.message = message; self.participant = participant; self.detail = detail
    }

    var json: [String: Any] {
        var value: [String: Any] = ["time": ISO8601DateFormatter.fractional.string(from: date), "level": level.rawValue, "category": category.rawValue, "message": message]
        if let participant { value["participant"] = participant }
        if let detail { value["detail"] = detail }
        return value
    }
}

/// A line of the live transcript, built from an agent's `lk.transcription` text streams.
struct LiveCaption: Identifiable, Sendable, Equatable {
    let id: String
    var speaker: String
    var agent: Bool
    var text: String
    var final: Bool
    var open: Bool
    let started: Date
}

@MainActor @Observable final class RoomMonitorLog {
    static let limit = 5000
    static let captionLimit = 2000
    private(set) var events: [RoomMonitorEvent] = []
    private(set) var captions: [LiveCaption] = []
    /// Events dropped from the front once the log is full.
    private(set) var dropped = 0

    func record(_ event: RoomMonitorEvent) {
        events.append(event)
        if events.count > Self.limit { let extra = events.count - Self.limit; events.removeFirst(extra); dropped += extra }
    }

    /// A stream's text so far replaces the line it belongs to: agents resend the whole interim
    /// transcript per segment, and stream their own speech in pieces under one stream.
    func caption(id: String, speaker: String, agent: Bool, text: String, final: Bool, open: Bool, date: Date = .now) {
        if let index = captions.lastIndex(where: { $0.id == id }) {
            captions[index].text = text; captions[index].final = final; captions[index].open = open
            captions[index].speaker = speaker; captions[index].agent = agent
        } else {
            guard !text.isEmpty || open else { return }
            captions.append(LiveCaption(id: id, speaker: speaker, agent: agent, text: text, final: final, open: open, started: date))
            if captions.count > Self.captionLimit { captions.removeFirst(captions.count - Self.captionLimit) }
        }
    }

    func clear() { events = []; captions = []; dropped = 0 }

    func export() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["events": events.map(\.json),
                                                    "transcript": captions.map { ["speaker": $0.speaker, "agent": $0.agent, "text": $0.text, "final": $0.final,
                                                                                  "time": ISO8601DateFormatter.fractional.string(from: $0.started)] as [String: Any] }],
                                   options: [.prettyPrinted, .sortedKeys])
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
}

enum RoomMonitorText {
    static let transcriptionTopic = "lk.transcription"
    static let agentStateAttribute = "lk.agent.state"

    static func who(_ participant: Participant?) -> String {
        guard let participant else { return "server" }
        return participant.identity?.stringValue ?? participant.sid?.stringValue ?? "unknown"
    }
    static func kind(_ kind: Participant.Kind) -> String { kind.description }
    static func quality(_ quality: ConnectionQuality) -> String {
        switch quality { case .unknown: "unknown"; case .lost: "lost"; case .poor: "poor"; case .good: "good"; case .excellent: "excellent" }
    }
    static func source(_ source: Track.Source) -> String {
        switch source { case .unknown: "unknown"; case .camera: "camera"; case .microphone: "microphone"; case .screenShareVideo: "screen share"; case .screenShareAudio: "screen share audio" }
    }
    static func stream(_ state: StreamState) -> String { state == .active ? "active" : "paused" }
    static func track(_ publication: TrackPublication) -> String {
        let name = publication.name.isEmpty ? source(publication.source) : publication.name
        return "\(name) (\(publication.sid.stringValue))"
    }
    /// Pretty JSON for a dictionary, or nil when there is nothing to show.
    static func json(_ value: [String: Any]) -> String? {
        guard !value.isEmpty, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    /// Data packets are shown as text when they are UTF-8, pretty-printed when they are JSON.
    static func payload(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty.prefix(20_000), as: UTF8.self)
        }
        if let text = String(data: data, encoding: .utf8) { return String(text.prefix(20_000)) }
        return "\(data.count) bytes of binary data: " + data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    /// What changed between two attribute sets, as "key: old → new" lines.
    static func changes(from old: [String: String], to new: [String: String]) -> [String] {
        Set(old.keys).union(new.keys).sorted().compactMap { key in
            switch (old[key], new[key]) {
            case let (before?, after?) where before != after: "\(key): \(before) → \(after)"
            case (nil, let after?): "\(key): \(after)"
            case (_?, nil): "\(key): removed"
            default: nil
            }
        }
    }
}

/// Turns the SDK's room delegate callbacks, which arrive on its own queues, into log events on the main actor.
final class RoomEventRecorder: NSObject, RoomDelegate, @unchecked Sendable {
    private let sink: @Sendable (RoomMonitorEvent) -> Void
    private let captions: @Sendable ([(id: String, text: String, final: Bool)], String, Bool) -> Void
    private let lock = NSLock()
    private var known: [String: [String: String]] = [:]
    /// The SDK fills in names and permissions while joining; those aren't changes worth logging.
    private var ready = false

    init(log: RoomMonitorLog) {
        sink = { [weak log] event in
            // The main queue keeps events in the order the SDK delivered them.
            DispatchQueue.main.async { MainActor.assumeIsolated { log?.record(event) } }
        }
        captions = { [weak log] segments, speaker, agent in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for segment in segments { log?.caption(id: segment.id, speaker: speaker, agent: agent, text: segment.text, final: segment.final, open: !segment.final) }
                }
            }
        }
    }

    private func emit(_ level: RoomMonitorEvent.Level = .info, _ category: RoomMonitorEvent.Category, _ message: String, _ participant: Participant? = nil, detail: [String: Any] = [:]) {
        sink(RoomMonitorEvent(level, category, message, participant: participant.map(RoomMonitorText.who), detail: RoomMonitorText.json(detail)))
    }
    func note(_ event: RoomMonitorEvent) { sink(event) }

    /// Remembers attributes so later changes can be shown as differences.
    func seed(_ participants: [Participant]) {
        lock.withLock { for participant in participants { known[RoomMonitorText.who(participant)] = participant.attributes }; ready = true }
    }

    // MARK: Connection

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        let name = { (state: ConnectionState) in String(describing: state).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        emit(connectionState == .disconnected ? .warning : .info, .connection, "Connection \(name(connectionState)) (was \(name(oldConnectionState)))")
    }
    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        emit(.warning, .connection, "Reconnecting (\(reconnectMode))")
    }
    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        emit(.info, .connection, "Reconnected (\(reconnectMode))")
    }
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        emit(error == nil ? .info : .error, .connection, error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected")
    }
    func room(_ room: Room, didUpdateBufferStatus isLow: Bool, of kind: DataChannelKind) {
        if isLow { emit(.warning, .connection, "Data channel buffer is low") }
    }

    // MARK: Room

    func room(_ room: Room, didUpdateMetadata metadata: String?) {
        emit(.info, .room, "Room metadata changed", detail: ["metadata": metadata ?? ""])
    }
    func room(_ room: Room, didUpdateIsRecording isRecording: Bool) {
        emit(.info, .room, isRecording ? "Recording started" : "Recording stopped")
    }
    func room(_ room: Room, didMoveToRoomNamed roomName: String) {
        emit(.warning, .room, "Observer was moved to room \(roomName)")
    }

    // MARK: Participants

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        lock.withLock { known[RoomMonitorText.who(participant)] = participant.attributes }
        var detail: [String: Any] = ["identity": RoomMonitorText.who(participant), "kind": RoomMonitorText.kind(participant.kind)]
        if let name = participant.name, !name.isEmpty { detail["name"] = name }
        if let metadata = participant.metadata, !metadata.isEmpty { detail["metadata"] = metadata }
        if !participant.attributes.isEmpty { detail["attributes"] = participant.attributes }
        emit(.info, participant.kind == .agent ? .agent : .participant, "\(RoomMonitorText.kind(participant.kind).capitalized) participant joined", participant, detail: detail)
    }
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        _ = lock.withLock { known.removeValue(forKey: RoomMonitorText.who(participant)) }
        emit(participant.kind == .agent ? .warning : .info, participant.kind == .agent ? .agent : .participant,
             "\(RoomMonitorText.kind(participant.kind).capitalized) participant left", participant)
    }
    private var settled: Bool { lock.withLock { ready } }

    func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) {
        guard settled, !(participant is LocalParticipant) else { return }
        emit(.info, .participant, "Metadata changed", participant, detail: ["metadata": metadata ?? ""])
    }
    func room(_ room: Room, participant: Participant, didUpdateName name: String) {
        // A joining participant's name arrives just before it joins.
        guard settled, !(participant is LocalParticipant), lock.withLock({ known[RoomMonitorText.who(participant)] != nil }) else { return }
        emit(.info, .participant, "Name changed to \(name)", participant)
    }
    func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        guard !(participant is LocalParticipant) else { return }
        emit(quality == .poor || quality == .lost ? .warning : .info, .participant, "Connection quality \(RoomMonitorText.quality(quality))", participant)
    }
    func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions) {
        guard settled, !(participant is LocalParticipant) else { return }
        emit(.info, .participant, "Permissions changed", participant, detail: [
            "canSubscribe": permissions.canSubscribe, "canPublish": permissions.canPublish, "canPublishData": permissions.canPublishData,
            "hidden": permissions.hidden, "recorder": permissions.recorder, "canUpdateMetadata": permissions.canUpdateMetadata,
        ])
    }
    /// The SDK passes only the keys that changed (a removed key arrives as ""), so compare whole sets.
    func room(_ room: Room, participant: Participant, didUpdateAttributes changed: [String: String]) {
        guard !(participant is LocalParticipant) else { return }
        let key = RoomMonitorText.who(participant), current = participant.attributes
        let old = lock.withLock { () -> [String: String] in defer { known[key] = current }; return known[key] ?? [:] }
        let changes = RoomMonitorText.changes(from: old, to: current)
        if let state = current[RoomMonitorText.agentStateAttribute], state != old[RoomMonitorText.agentStateAttribute] {
            emit(.info, .agent, "Agent is \(state)", participant)
            if changes.count == 1 { return }
        }
        guard !changes.isEmpty else { return }
        emit(.info, .participant, "Attributes changed: " + changes.joined(separator: "; "), participant, detail: ["attributes": current])
    }

    // MARK: Tracks

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        emit(.info, .track, "Published \(RoomMonitorText.track(publication))", participant, detail: ["mimeType": publication.mimeType, "source": RoomMonitorText.source(publication.source), "simulcast": publication.isSimulcasted])
    }
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        emit(.info, .track, "Unpublished \(RoomMonitorText.track(publication))", participant)
    }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        emit(.info, .track, "Subscribed to \(RoomMonitorText.track(publication))", participant)
    }
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        emit(.info, .track, "Unsubscribed from \(RoomMonitorText.track(publication))", participant)
    }
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        emit(.error, .track, "Could not subscribe to \(trackSid.stringValue): \(error.localizedDescription)", participant)
    }
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        emit(.info, .track, "\(isMuted ? "Muted" : "Unmuted") \(RoomMonitorText.track(trackPublication))", participant)
    }
    func room(_ room: Room, participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateStreamState streamState: StreamState) {
        emit(.info, .track, "Stream \(RoomMonitorText.stream(streamState)) for \(RoomMonitorText.track(trackPublication))", participant)
    }
    func room(_ room: Room, participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateIsSubscriptionAllowed isSubscriptionAllowed: Bool) {
        emit(isSubscriptionAllowed ? .info : .warning, .track, "Subscription \(isSubscriptionAllowed ? "allowed" : "not allowed") for \(RoomMonitorText.track(trackPublication))", participant)
    }

    // MARK: Data

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        sink(RoomMonitorEvent(.info, .data, "Data\(topic.isEmpty ? "" : " on topic \(topic)") · \(data.count) bytes",
                              participant: RoomMonitorText.who(participant), detail: RoomMonitorText.payload(data)))
    }

    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        // Older agents send transcripts as segments instead of text streams.
        captions(segments.map { (id: $0.id, text: $0.text, final: $0.isFinal) }, RoomMonitorText.who(participant), participant.kind == .agent)
    }
}
