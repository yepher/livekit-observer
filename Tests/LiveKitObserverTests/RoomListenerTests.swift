import Foundation
import Testing
@testable import LiveKitObserver

private func listenRoom(_ id: String = "RM_live") -> LiveRoom {
    LiveRoom(json: JSONValue(any: ["sid": id, "name": "existing-room", "numParticipants": 2]))!
}

/// Unsigned test fixtures are only used with the fake connection below.
private func listenToken(room: String, identity: String, overrides: [String: JSONValue] = [:]) throws -> String {
    var grant: [String: JSONValue] = ["room": .string(room), "roomJoin": .bool(true), "canSubscribe": .bool(true), "canPublish": .bool(false), "canPublishData": .bool(true)]
    grant.merge(overrides, uniquingKeysWith: { _, value in value })
    let data = try JSONSerialization.data(withJSONObject: JSONValue.object(["sub": .string(identity), "video": .object(grant)]).foundation)
    return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}

private actor FakeListenSource: RoomListenSource {
    let available: [LiveRoom]
    let blockToken: Bool
    let publish: Bool
    private(set) var tokenRequests = 0
    private var tokenWaiter: CheckedContinuation<Void, Never>?
    init(available: [LiveRoom] = [listenRoom()], blockToken: Bool = false, publish: Bool = false) {
        self.available = available; self.blockToken = blockToken; self.publish = publish
    }
    func rooms() async throws -> [LiveRoom] { available }
    func listenerToken(room: String, identity: String) async throws -> String {
        tokenRequests += 1; tokenWaiter?.resume(); tokenWaiter = nil
        if blockToken { try await Task.sleep(for: .seconds(60)) }
        return try listenToken(room: room, identity: identity, overrides: ["canPublish": .bool(publish)])
    }
    func waitForTokenRequest() async {
        if tokenRequests == 0 { await withCheckedContinuation { tokenWaiter = $0 } }
    }
}

@MainActor private final class FakeListenConnection: RoomListenConnection {
    var connectCount = 0, disconnectCount = 0
    var roomID: String?
    var failConnect = false
    var receivedVolumes: [Double] = []
    var receivedOutputs: [String] = []
    var next = RoomListenSnapshot(audioTracks: 2)
    func connect(url: String, token: String, roomID: String) async throws {
        connectCount += 1; self.roomID = roomID
        if failConnect { throw URLError(.cannotConnectToHost) }
    }
    func refresh(volume: Double, output: String) async throws -> RoomListenSnapshot {
        receivedVolumes.append(volume); receivedOutputs.append(output); return next
    }
    var rpcCalls: [(String, String, String)] = []
    var rpcFailure: Error?
    func performRpc(to identity: String, method: String, payload: String, timeout: TimeInterval) async throws -> String {
        rpcCalls.append((identity, method, payload))
        if let rpcFailure { throw rpcFailure }
        return #"{"ok":true}"#
    }
    func disconnect() async { disconnectCount += 1 }
}

@Suite @MainActor struct RoomListenerTests {
    @Test func tokenRequiresExplicitListenOnlyGrantsAndTheSelectedRoom() throws {
        let token = try listenToken(room: "existing-room", identity: "listener")
        try RoomListenToken.validate(token, room: "existing-room", identity: "listener")
        #expect(throws: (any Error).self) { try RoomListenToken.validate(token, room: "another-room", identity: "listener") }
        #expect(throws: (any Error).self) { try RoomListenToken.validate(token, room: "existing-room", identity: "another-listener") }
        for overrides: [String: JSONValue] in [["canPublish": .bool(true)], ["canPublish": .null], ["canPublishData": .bool(false)], ["canPublishData": .null], ["canSubscribe": .bool(false)], ["roomAdmin": .bool(true)], ["roomCreate": .bool(true)], ["hidden": .bool(true)]] {
            let unsafe = try listenToken(room: "existing-room", identity: "listener", overrides: overrides)
            #expect(throws: (any Error).self) { try RoomListenToken.validate(unsafe, room: "existing-room", identity: "listener") }
        }
    }

    @Test func listeningReceivesAudioAndLeaveOnlyDisconnectsTheListener() async {
        let source = FakeListenSource(), connection = FakeListenConnection(), lease = ObserverAudioLease()
        let session = RoomListenSession(connection: connection, lease: lease)
        await session.start(source: source, projectURL: "wss://example.invalid", target: listenRoom())
        #expect(session.phase == .listening)
        #expect(connection.roomID == "RM_live")
        #expect(session.snapshot.audioTracks == 2)
        session.volume = 0.4; session.output = "speakers"
        await session.refreshPlayback()
        #expect(connection.receivedVolumes.last == 0.4 && connection.receivedOutputs.last == "speakers")
        session.muted = true; await session.refreshPlayback()
        #expect(connection.receivedVolumes.last == 0)
        await session.stop()
        #expect(connection.disconnectCount == 1 && session.phase == .idle)
        #expect(await source.tokenRequests == 1)
        let owner = UUID(); #expect(lease.acquire(owner)); lease.release(owner)
    }

    @Test func endedOrReplacedRoomDoesNotRequestATokenOrConnect() async {
        for available in [[], [listenRoom("RM_replacement")]] {
            let source = FakeListenSource(available: available), connection = FakeListenConnection()
            let session = RoomListenSession(connection: connection, lease: ObserverAudioLease())
            await session.start(source: source, projectURL: "wss://example.invalid", target: listenRoom())
            #expect(connection.connectCount == 0)
            #expect(await source.tokenRequests == 0)
            #expect(session.phase == .idle && session.message?.contains("no longer live") == true)
        }
    }

    @Test func unsafeTokenAndConnectionFailureReleaseTheAudioLease() async {
        for publish in [true, false] {
            let connection = FakeListenConnection(), lease = ObserverAudioLease()
            connection.failConnect = !publish
            let session = RoomListenSession(connection: connection, lease: lease)
            await session.start(source: FakeListenSource(publish: publish), projectURL: "wss://example.invalid", target: listenRoom())
            #expect(session.phase == .idle && session.message != nil)
            #expect(connection.connectCount == (publish ? 0 : 1))
            #expect(connection.disconnectCount == 1)
            let owner = UUID(); #expect(lease.acquire(owner)); lease.release(owner)
        }
    }

    @Test func cancellationDuringTokenCreationCannotJoinLater() async {
        let source = FakeListenSource(blockToken: true), connection = FakeListenConnection(), lease = ObserverAudioLease()
        let session = RoomListenSession(connection: connection, lease: lease)
        let setup = Task { await session.start(source: source, projectURL: "wss://example.invalid", target: listenRoom()) }
        await source.waitForTokenRequest()
        await session.stop(); await setup.value
        #expect(session.phase == .idle && connection.connectCount == 0 && connection.disconnectCount == 1)
        let owner = UUID(); #expect(lease.acquire(owner)); lease.release(owner)
    }

    @Test func anotherObserverCallBlocksListeningAcrossWindows() async {
        let connection = FakeListenConnection(), lease = ObserverAudioLease(), callOwner = UUID()
        #expect(lease.acquire(callOwner))
        let source = FakeListenSource(), session = RoomListenSession(connection: connection, lease: lease)
        await session.start(source: source, projectURL: "wss://example.invalid", target: listenRoom())
        #expect(await source.tokenRequests == 0)
        #expect(connection.connectCount == 0 && session.message?.contains("active Observer call") == true)
        await session.stop()
        #expect(!lease.acquire(UUID())) // An idle listener cannot release somebody else's call.
        lease.release(callOwner)
    }

    @Test func reconnectionAndRemoteDisconnectUpdateTheListener() async {
        let connection = FakeListenConnection(), lease = ObserverAudioLease()
        let session = RoomListenSession(connection: connection, lease: lease)
        await session.start(source: FakeListenSource(), projectURL: "wss://example.invalid", target: listenRoom())
        connection.next = .init(state: .reconnecting); await session.refreshPlayback()
        #expect(session.phase == .reconnecting)
        connection.next = .init(audioTracks: 3); await session.refreshPlayback()
        #expect(session.phase == .listening && session.snapshot.audioTracks == 3)
        connection.next = .init(state: .disconnected, message: "Room ended"); await session.refreshPlayback()
        #expect(session.phase == .idle && session.message == "Room ended")
        #expect(connection.disconnectCount == 1)
        let owner = UUID(); #expect(lease.acquire(owner)); lease.release(owner)
    }
}

@Suite @MainActor struct RoomMonitorTests {
    @Test func captionsReplaceTheirTextAndTheLogKeepsTheNewestEvents() {
        let log = RoomMonitorLog()
        log.caption(id: "SG_1", speaker: "user", agent: false, text: "hel", final: false, open: true)
        log.caption(id: "SG_1", speaker: "user", agent: false, text: "hello there", final: true, open: false)
        log.caption(id: "SG_2", speaker: "agent", agent: true, text: "", final: false, open: false)
        #expect(log.captions.map(\.text) == ["hello there"])
        #expect(log.captions.first?.final == true && log.captions.first?.open == false)
        for index in 0..<(RoomMonitorLog.limit + 3) { log.record(RoomMonitorEvent(.info, .data, "event \(index)")) }
        #expect(log.events.count == RoomMonitorLog.limit && log.dropped == 3)
        #expect(log.events.first?.message == "event 3")
        let exported = try? JSONSerialization.jsonObject(with: log.export()) as? [String: Any]
        #expect((exported?["events"] as? [Any])?.count == RoomMonitorLog.limit)
        log.clear(); #expect(log.events.isEmpty && log.captions.isEmpty && log.dropped == 0)
    }

    @Test func attributeChangesAndPayloadsReadClearly() {
        #expect(RoomMonitorText.changes(from: ["lk.agent.state": "listening", "gone": "1"], to: ["lk.agent.state": "thinking", "new": "x"])
                == ["gone: removed", "lk.agent.state: listening → thinking", "new: x"])
        #expect(RoomMonitorText.payload(Data(#"{"b":1,"a":2}"#.utf8)).contains("\"a\" : 2"))
        #expect(RoomMonitorText.payload(Data("plain".utf8)) == "plain")
        #expect(RoomMonitorText.payload(Data([0xff, 0xfe])).hasPrefix("2 bytes of binary data"))
    }

    @Test func roomAndParticipantRecordsKeepTheirDetailsButNotTheTurnPassword() throws {
        let room = try #require(LiveRoom(json: JSONValue(any: ["sid": "RM_1", "name": "r", "numPublishers": 2, "turnPassword": "secret", "activeRecording": true,
                                                               "enabledCodecs": [["mime": "audio/opus"]]])))
        #expect(room.publishers == 2 && room.recording && room.codecs == ["audio/opus"])
        #expect(room.raw["turnPassword"] == nil)
        let participant = try #require(LiveParticipant(json: JSONValue(any: [
            "identity": "agent-1", "kind": "AGENT", "state": "ACTIVE", "region": "us-east",
            "attributes": ["lk.agent.state": "speaking"], "permission": ["canPublish": true, "canSubscribe": true, "hidden": false],
            "tracks": [["sid": "TR_1", "type": "AUDIO", "source": "MICROPHONE", "mimeType": "audio/opus"]]])))
        #expect(participant.agentState == "speaking")
        #expect(participant.permissions == ["canPublish", "canSubscribe"])
        #expect(participant.tracks.first?.summary == "audio/opus · microphone")
    }

    @Test func confirmationFieldsCheckWhatTheUserTyped() {
        typealias Field = OperationConfirmation.Field
        #expect(Field(label: "Permissions", text: #"{"canPublish":false}"#, check: .jsonObject).problem == nil)
        #expect(Field(label: "Permissions", text: "[1]", check: .jsonObject).problem != nil)
        #expect(Field(label: "Data", text: "--room other", check: .notFlag).problem != nil)
        #expect(Field(label: "Topic", text: "", check: .notFlag, optional: true).problem == nil)
        #expect(Field(label: "Data", text: "").problem != nil)
        let request = OperationConfirmation(projectID: "p", projectName: "P", title: "Send", explanation: "", protected: false, arguments: [],
                                            fields: [Field(label: "Data", text: "x")], build: { ["room", "send-data", $0[0]] })
        #expect(request.arguments(for: ["hello"]) == ["room", "send-data", "hello"])
    }

    @Test func rpcCallsNeedTheRoomAndAreLogged() async throws {
        let connection = FakeListenConnection(), session = RoomListenSession(connection: connection, lease: ObserverAudioLease())
        await #expect(throws: (any Error).self) { try await session.performRpc(to: "agent", method: "ping", payload: "") }
        #expect(connection.rpcCalls.isEmpty)
        await session.start(source: FakeListenSource(), projectURL: "wss://example.invalid", target: listenRoom())
        let answer = try await session.performRpc(to: "agent", method: "ping", payload: "{}")
        #expect(answer == #"{"ok":true}"# && connection.rpcCalls.first?.1 == "ping")
        connection.rpcFailure = URLError(.timedOut)
        await #expect(throws: (any Error).self) { try await session.performRpc(to: "agent", method: "slow", payload: "") }
        let rpc = session.log.events.filter { $0.category == .rpc }
        #expect(rpc.map(\.level) == [.info, .info, .info, .error])
        await session.stop()
        #expect(session.log.events.last?.message == "Observer left the room")
    }
}
