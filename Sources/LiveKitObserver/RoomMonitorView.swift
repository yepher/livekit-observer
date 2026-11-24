import ObserverCore
import AppKit
import LiveKit
import SwiftUI

/// A live room: its participants from the server, and, once Observer joins, its events, live transcript, and RPC.
struct RoomDetailView: View {
    enum Tab: String, CaseIterable { case participants = "Participants", events = "Events", transcript = "Transcript", rpc = "RPC", room = "Room" }
    let room: LiveRoom
    @Environment(AppModel.self) private var app
    @State private var listener = RoomListenSession()
    @AppStorage("roomMonitorTab") private var tab = Tab.participants
    @State private var rpcTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) { Text(room.name).font(.title2.bold()).textSelection(.enabled); Text(room.id).font(.caption.monospaced()).textSelection(.enabled) }
                Spacer()
                if listener.phase == .idle {
                    Button { Task { await join() } } label: { Label("Join", systemImage: "headphones") }
                        .help("Join as Observer listener, with the microphone off, to hear the room and record its events")
                        .disabled(app.selectedProject == nil || app.cli == nil)
                } else {
                    Button(listener.phase == .connecting ? "Cancel" : "Leave") { Task { await listener.stop() } }.disabled(listener.phase == .leaving)
                }
                Button("Open session") { Task { await app.openRemoteSession(room.id) } }
            }
            RoomJoinBar(listener: listener)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in Text(title(tab)).tag(tab) }
            }.pickerStyle(.segmented).labelsHidden()
            if let error = app.operations.detailError { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            Group {
                switch tab {
                case .participants: RoomParticipantsView(room: room, listener: listener) { identity in rpcTarget = identity; tab = .rpc }
                case .events: RoomEventsView(listener: listener, roomName: room.name)
                case .transcript: RoomTranscriptView(listener: listener)
                case .rpc: RoomRPCView(listener: listener, target: $rpcTarget)
                case .room: RoomInfoView(room: room, listener: listener)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding()
        .task { await app.operations.watchRoom() }
        .task(id: "\(listener.volume):\(listener.muted):\(listener.output)") { await listener.refreshPlayback() }
        .onDisappear { Task { await listener.stop() } }
    }

    private func title(_ tab: Tab) -> String {
        switch tab {
        case .participants: "Participants (\(app.operations.participants.count))"
        case .events: listener.log.events.isEmpty ? "Events" : "Events (\(listener.log.events.count))"
        case .transcript: listener.log.captions.isEmpty ? "Transcript" : "Transcript (\(listener.log.captions.count))"
        default: tab.rawValue
        }
    }

    private func join() async {
        guard let project = app.selectedProject, app.projectIdentity == project.id, let cli = app.cli else {
            listener.message = "Connect the LiveKit CLI for this project to join."; return
        }
        app.player.pause(); app.skimmer.end()
        await listener.start(source: cli, projectURL: project.url, target: room)
    }
}

/// Status and playback controls while Observer is in the room.
struct RoomJoinBar: View {
    @Bindable var listener: RoomListenSession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if listener.phase != .idle {
                HStack(spacing: 12) {
                    switch listener.phase {
                    case .connecting: ProgressView().controlSize(.small); Text("Joining room…")
                    case .reconnecting: ProgressView().controlSize(.small); Text("Reconnecting…")
                    case .leaving: ProgressView().controlSize(.small); Text("Leaving room…")
                    default:
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                        Text("Joined as Observer listener · mic off · \(listener.snapshot.audioTracks) audio track\(listener.snapshot.audioTracks == 1 ? "" : "s")")
                        if let start = listener.startedAt { Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { listener.muted.toggle() } label: { Image(systemName: listener.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                        .help(listener.muted ? "Unmute playback" : "Mute playback").buttonStyle(.borderless)
                    Slider(value: $listener.volume, in: 0...1).frame(width: 110).accessibilityLabel("Playback volume")
                    Picker("Speakers", selection: $listener.output) {
                        Text("System output").tag("")
                        ForEach(AudioManager.shared.outputDevices) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 170)
                }.font(.callout)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = listener.message ?? listener.snapshot.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

// MARK: - Participants

struct RoomParticipantsView: View {
    let room: LiveRoom
    let listener: RoomListenSession
    let callRPC: (String) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let live = Dictionary(listener.snapshot.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 6) {
            List(app.operations.participants) { participant in
                ParticipantRow(participant: participant, live: live[participant.identity], joined: listener.joined,
                               act: { action(participant, $0) }).padding(.vertical, 6)
            }.disabled(app.operations.mutating)
            Text("From the LiveKit server, every 5 seconds\(listener.joined ? "; speaking, levels, and connection quality are live while Observer is in the room" : ". Join to see who is speaking.")")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    enum Action { case remove, mute(LiveParticipant.Track), unmute(LiveParticipant.Track), metadata, sendData, rpc }

    private func action(_ participant: LiveParticipant, _ action: Action) {
        guard let project = app.selectedProject else { return }
        let ops = app.operations, who = "Room: \(room.name)\nParticipant: \(participant.identity)"
        let base = ["room"], roomName = room.name, identity = participant.identity
        switch action {
        case .rpc: callRPC(identity)
        case .remove:
            ops.confirm("Remove participant", explanation: who + "\nThe participant will be disconnected.",
                        arguments: base + ["participants", "remove", "--room", roomName, "--identity", identity], project: project)
        case .mute(let track), .unmute(let track):
            let mute = if case .mute = action { true } else { false }
            ops.confirm(mute ? "Mute track" : "Unmute track", explanation: who + "\nTrack: \(track.name.isEmpty ? track.summary : track.name) (\(track.id))"
                        + (mute ? "" : "\nThe room must allow remote unmute."),
                        arguments: base + ["mute-track", "--room", roomName, "--identity", identity, mute ? "--mute" : "--unmute", track.id], project: project)
        case .metadata:
            ops.confirm("Update metadata", explanation: who + "\nReplaces the participant's metadata. Their app receives the change.",
                        fields: [.init(label: "Metadata", text: participant.metadata, multiline: true, optional: true)], project: project) { values in
                base + ["participants", "update", "--room", roomName, "--identity", identity, "--metadata=" + values[0]]
            }
        case .sendData:
            RoomInfoView.sendData(app: app, project: project, room: roomName, to: identity)
        }
    }
}

private struct ParticipantRow: View {
    let participant: LiveParticipant
    let live: RoomListenSnapshot.Member?
    let joined: Bool
    let act: (RoomParticipantsView.Action) -> Void
    private var isObserver: Bool { participant.identity.hasPrefix("observer-listener-") }
    private var agentState: String? { live?.agentState ?? participant.agentState }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let live { Image(systemName: live.speaking ? "waveform" : "person.fill").foregroundStyle(live.speaking ? .green : .secondary).frame(width: 18) }
                Text(participant.name.isEmpty ? participant.identity : participant.name).font(.headline)
                Tag(text: participant.kind.capitalized, symbol: participant.kind == "AGENT" ? "person.wave.2" : participant.kind == "SIP" ? "phone" : "person",
                    color: participant.kind == "AGENT" ? .blue : participant.kind == "SIP" ? .purple : .secondary)
                if isObserver { Tag(text: "Observer", symbol: "headphones", color: .teal) }
                if let agentState { Tag(text: agentState, symbol: "brain", color: agentState == "speaking" ? .green : agentState == "thinking" ? .orange : .blue) }
                if !participant.state.isEmpty, participant.state != "ACTIVE" { Text(participant.state.lowercased()).font(.caption).foregroundStyle(.orange) }
                Spacer()
                if let live {
                    if live.audioTracks > 0 { ProgressView(value: Double(live.level), total: 1).frame(width: 70).help("Incoming audio level") }
                    Label(live.quality, systemImage: "antenna.radiowaves.left.and.right").font(.caption)
                        .foregroundStyle(live.quality == "poor" || live.quality == "lost" ? .orange : .secondary).help("Connection quality")
                }
                if !isObserver {
                    Menu {
                        Button("Call RPC method…") { act(.rpc) }.disabled(!joined)
                        Button("Send data…") { act(.sendData) }
                        Divider()
                        Button("Edit metadata…") { act(.metadata) }
                        Divider()
                        Button("Remove from room…", role: .destructive) { act(.remove) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("Actions")
                }
            }
            Text([participant.identity, participant.region.isEmpty ? nil : participant.region,
                  participant.joinedAt.map { "joined \($0.formatted(date: .omitted, time: .standard))" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(participant.tracks) { track in
                HStack {
                    Label("\(track.name.isEmpty ? track.type.lowercased() : track.name) · \(track.summary)", systemImage: track.muted ? "mic.slash" : track.type == "VIDEO" ? "video" : "waveform")
                        .foregroundStyle(track.muted ? .secondary : .primary)
                    Text(track.id).foregroundStyle(.tertiary).textSelection(.enabled)
                    Spacer()
                    if !isObserver {
                        if track.muted { Button("Unmute…") { act(.unmute(track)) }.buttonStyle(.link) }
                        else { Button("Mute…") { act(.mute(track)) }.buttonStyle(.link) }
                    }
                }.font(.caption)
            }
            if !participant.attributes.isEmpty {
                DisclosureGroup("Attributes (\(participant.attributes.count))") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                        ForEach(participant.attributes.keys.sorted(), id: \.self) { key in
                            GridRow { Text(key).foregroundStyle(.secondary); Text(participant.attributes[key] ?? "").textSelection(.enabled) }
                        }
                    }.font(.caption.monospaced()).padding(.leading, 4)
                }.font(.caption)
            }
            if !participant.permissions.isEmpty {
                Text("Permissions: " + participant.permissions.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
            }
            if !participant.metadata.isEmpty { DisclosureGroup("Metadata") { JSONText(participant.metadata) }.font(.caption) }
            DisclosureGroup("Raw JSON") { JSONText(participant.raw) }.font(.caption)
        }
    }
}

/// Text or JSON in a monospaced, selectable block; JSON is pretty-printed.
struct JSONText: View {
    let text: String
    init(_ text: String) {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            self.text = String(decoding: data, as: UTF8.self)
        } else { self.text = text }
    }
    init(_ value: JSONValue) {
        let data = (try? JSONSerialization.data(withJSONObject: value.foundation, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }
    var body: some View {
        Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Events

struct RoomEventsView: View {
    let listener: RoomListenSession
    let roomName: String
    @State private var level: RoomMonitorEvent.Level = .info
    @State private var hidden: Set<RoomMonitorEvent.Category> = []
    @State private var search = ""
    @State private var follow = true
    @State private var frozen: [RoomMonitorEvent]?
    @State private var expanded: Set<UUID> = []

    private var shown: [RoomMonitorEvent] {
        let order = RoomMonitorEvent.Level.allCases
        let minimum = order.firstIndex(of: level) ?? 0
        return (frozen ?? listener.log.events).filter { event in
            (order.firstIndex(of: event.level) ?? 0) >= minimum && !hidden.contains(event.category)
                && (search.isEmpty || event.message.localizedCaseInsensitiveContains(search) || (event.participant ?? "").localizedCaseInsensitiveContains(search)
                    || (event.detail ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Level", selection: $level) {
                    Text("All levels").tag(RoomMonitorEvent.Level.info); Text("Warnings and errors").tag(RoomMonitorEvent.Level.warning); Text("Errors").tag(RoomMonitorEvent.Level.error)
                }.labelsHidden().frame(width: 180)
                Menu("Categories\(hidden.isEmpty ? "" : " (\(RoomMonitorEvent.Category.allCases.count - hidden.count))")") {
                    ForEach(RoomMonitorEvent.Category.allCases, id: \.self) { category in
                        Toggle(isOn: Binding(get: { !hidden.contains(category) }, set: { if $0 { hidden.remove(category) } else { hidden.insert(category) } })) {
                            Label(category.rawValue, systemImage: category.symbol)
                        }
                    }
                    Divider(); Button("Show all") { hidden = [] }
                }.fixedSize()
                TextField("Search events", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).help("Scroll to new events as they arrive")
                Toggle("Pause", isOn: Binding(get: { frozen != nil }, set: { frozen = $0 ? listener.log.events : nil })).toggleStyle(.checkbox)
                    .help("Hold the list still; events are still recorded")
                Menu { Button("Export…", action: export); Button("Clear", role: .destructive) { listener.log.clear(); frozen = nil } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            let events = shown
            if events.isEmpty {
                ContentUnavailableView(listener.log.events.isEmpty ? (listener.joined ? "Waiting for events" : "Join the room to record its events") : "No matching events",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text(listener.log.events.isEmpty ? "Joins, tracks, mutes, attribute and metadata changes, data messages, agent state, and RPC calls appear here while Observer is in the room." : ""))
            } else {
                ScrollViewReader { proxy in
                    List(events) { event in EventRow(event: event, expanded: expandedBinding(event.id)).id(event.id) }
                        .font(.callout)
                        .onChange(of: events.last?.id) { _, last in if follow, let last { proxy.scrollTo(last, anchor: .bottom) } }
                        .onAppear { if follow, let last = events.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            Text("\(listener.log.events.count) events" + (listener.log.dropped > 0 ? " · \(listener.log.dropped) oldest dropped (keeps \(RoomMonitorLog.limit))" : "") + " · kept until you clear them or close the room")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(roomName)-events.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try listener.log.export().write(to: url, options: .atomic) } catch { listener.message = error.localizedDescription }
    }
}

private struct EventRow: View {
    let event: RoomMonitorEvent
    @Binding var expanded: Bool
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.time.string(from: event.date)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Image(systemName: event.category.symbol).foregroundStyle(color).frame(width: 18).help(event.category.rawValue)
                if let participant = event.participant { Text(participant).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                Text(event.message).foregroundStyle(event.level == .info ? .primary : color).textSelection(.enabled)
                Spacer(minLength: 0)
                if event.detail != nil {
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }.buttonStyle(.borderless).help("Details")
                }
            }
            if expanded, let detail = event.detail { JSONText(detail).padding(.leading, 90) }
        }
    }
    private var color: Color {
        switch event.level { case .error: .red; case .warning: .orange; case .info: event.category == .agent ? .blue : event.category == .rpc ? .purple : .secondary }
    }
}

// MARK: - Transcript

struct RoomTranscriptView: View {
    let listener: RoomListenSession
    @State private var follow = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let captions = listener.log.captions
            if captions.isEmpty {
                ContentUnavailableView(listener.joined ? "Waiting for speech" : "Join the room for a live transcript", systemImage: "captions.bubble",
                                       description: Text("Captions come from the transcriptions a LiveKit agent publishes as people speak."))
            } else {
                ScrollViewReader { proxy in
                    List(captions) { caption in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(caption.started.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(caption.speaker).font(.callout.bold()).foregroundStyle(caption.agent ? .blue : .green).frame(width: 140, alignment: .leading).lineLimit(1)
                            Text(caption.text.isEmpty ? "…" : caption.text).foregroundStyle(caption.open && !caption.final ? .secondary : .primary).textSelection(.enabled)
                        }.id(caption.id)
                    }
                    .onChange(of: captions.last?.text) { _, _ in if follow, let last = captions.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            HStack {
                Text("Agent lines are blue and user lines green. Grey text is still being spoken or transcribed.").font(.caption2).foregroundStyle(.secondary)
                Spacer(); Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption)
            }
        }
    }
}

// MARK: - RPC

struct RoomRPCView: View {
    let listener: RoomListenSession
    @Binding var target: String?
    @Environment(AppModel.self) private var app
    @AppStorage("roomRPCMethod") private var method = ""
    @AppStorage("roomRPCPayload") private var payload = ""
    @State private var timeout = 15.0
    @State private var calling = false
    @State private var result: (ok: Bool, text: String)?
    @State private var confirming = false

    private var members: [RoomListenSnapshot.Member] {
        listener.snapshot.members.filter { !$0.id.hasPrefix("observer-listener-") }.sorted { ($0.kind == "agent" ? 0 : 1, $0.name) < ($1.kind == "agent" ? 0 : 1, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !listener.joined {
                ContentUnavailableView("Join the room to call RPC methods", systemImage: "arrow.left.arrow.right",
                                       description: Text("Observer calls a method a participant registered with registerRpcMethod, and shows its answer."))
            } else {
                Form {
                    Picker("Participant", selection: Binding(get: { target ?? members.first?.id ?? "" }, set: { target = $0 })) {
                        ForEach(members) { Text("\($0.name) (\($0.kind))").tag($0.id) }
                    }
                    TextField("Method", text: $method, prompt: Text("e.g. get_user_location"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Payload").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $payload).font(.body.monospaced()).frame(minHeight: 80, maxHeight: 160)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    }
                    Stepper("Response timeout: \(Int(timeout)) s", value: $timeout, in: 1...60)
                }.formStyle(.columns)
                HStack {
                    Text("The payload is sent as text (up to 15 KB). The agent's handler runs with it, so it can change what the agent does.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if calling { ProgressView().controlSize(.small) }
                    Button("Call") { if app.selectedProject?.protected == true { confirming = true } else { call() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(calling || method.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty || payload.utf8.count > 15_360)
                }
                if let result {
                    Text(result.ok ? "Response" : "Error").font(.caption.bold()).foregroundStyle(result.ok ? Color.secondary : .red)
                    ScrollView { JSONText(result.text) }.frame(maxHeight: 180)
                }
            }
            let history = listener.log.events.filter { $0.category == .rpc }.suffix(50).reversed()
            if !history.isEmpty {
                Text("Recent calls").font(.caption.bold()).foregroundStyle(.secondary)
                List(Array(history)) { event in
                    HStack {
                        Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(event.participant ?? "").font(.caption.monospaced())
                        Text(event.message).foregroundStyle(event.level == .error ? .red : .primary).lineLimit(1)
                    }.font(.callout)
                }.frame(minHeight: 100)
            }
        }
        .confirmationDialog("Call \(method) on \(target ?? members.first?.id ?? "")?", isPresented: $confirming) {
            Button("Call") { call() }
        } message: { Text("\(app.selectedProject?.name ?? "This project") is a protected project.") }
    }

    private func call() {
        guard let identity = target ?? members.first?.id else { return }
        let method = method.trimmingCharacters(in: .whitespaces), payload = payload, timeout = timeout
        calling = true; result = nil
        Task {
            defer { calling = false }
            do { result = (true, try await listener.performRpc(to: identity, method: method, payload: payload, timeout: timeout)) }
            catch { result = (false, RoomListenSession.describe(error)) }
        }
    }
}

// MARK: - Room

struct RoomInfoView: View {
    let room: LiveRoom
    let listener: RoomListenSession
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Name", room.name); row("Room ID", room.id)
                    if let date = room.createdAt { row("Created", date.formatted(date: .abbreviated, time: .standard)) }
                    row("Participants", "\(room.participants) · \(room.publishers) publishing")
                    if room.maxParticipants > 0 { row("Max participants", "\(room.maxParticipants)") }
                    row("Empty timeout", "\(room.emptyTimeout) s · departure timeout \(room.departureTimeout) s")
                    row("Recording", (listener.joined ? listener.snapshot.server.recording : room.recording) ? "Yes" : "No")
                    if !room.codecs.isEmpty { row("Codecs", room.codecs.joined(separator: ", ")) }
                    if listener.joined {
                        let server = listener.snapshot.server
                        if !server.region.isEmpty { row("Server region", server.region) }
                        if !server.node.isEmpty { row("Server node", server.node) }
                        if !server.version.isEmpty { row("Server version", server.version) }
                    }
                }.font(.callout)
                if !listener.joined { Text("Join the room to see the server region, node, and version.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text("Metadata").font(.headline); Spacer()
                    Button("Edit metadata…", action: editMetadata)
                    Button("Send data…") { if let project = app.selectedProject { Self.sendData(app: app, project: project, room: room.name, to: nil) } }
                }
                let metadata = listener.joined ? listener.snapshot.roomMetadata : room.metadata
                if metadata.isEmpty { Text(listener.joined ? "None" : "Join the room to see its current metadata; the room list doesn't include it.").foregroundStyle(.secondary) } else { JSONText(metadata) }
                DisclosureGroup("Raw JSON") { JSONText(room.raw) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing)
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }

    private func editMetadata() {
        guard let project = app.selectedProject else { return }
        let name = room.name
        app.operations.confirm("Update room metadata", explanation: "Room: \(name)\nReplaces the room's metadata. Everyone in the room receives the change.",
                               fields: [.init(label: "Metadata", text: room.metadata, multiline: true, check: .notFlag, optional: true)], project: project) { values in
            ["room", "update", "--metadata=" + values[0], name]
        }
    }

    /// Sends a data packet from the server, to one participant or the whole room.
    static func sendData(app: AppModel, project: ProjectRef, room: String, to identity: String?) {
        app.operations.confirm("Send data", explanation: "Room: \(room)\nTo: \(identity ?? "everyone in the room")\nSent from the server as a reliable data packet. Observer logs it too while it is in the room.",
                               fields: [.init(label: "Topic", text: "", check: .notFlag, optional: true),
                                        .init(label: "Data", text: "", multiline: true, check: .notFlag)], project: project) { values in
            ["room", "send-data", "--room", room] + (values[0].isEmpty ? [] : ["--topic", values[0]]) + (identity.map { ["--identity", $0] } ?? []) + [values[1]]
        }
    }
}
