import ObserverCore
import SwiftUI

struct QuickJumpView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var rows: [SessionRow] = []
    @State private var agents: [CloudAgent] = []
    @State private var rooms: [LiveRoom] = []
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Quick jump").font(.title2.bold()); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            TextField("Session ID, room prefix, or agent name", text: $search).textFieldStyle(.roundedBorder).focused($focused)
            Text("Searches indexed sessions and current room/agent metadata for this project.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            List {
                Section("Sessions") {
                    ForEach(rows) { row in Button(row.title) { app.openIndexedSession(row); dismiss() } }
                    if search.hasPrefix("RM_"), !rows.contains(where: { $0.id == search }) {
                        Button("Look up session \(search)") { Task { await app.openRemoteSession(search) }; dismiss() }
                    }
                }
                Section("Agents") {
                    ForEach(agents.filter { matches($0.title) || matches($0.id) }) { agent in
                        Button(agent.title) { app.operations.selectedAgent = agent.id; app.section = .agents; dismiss() }
                    }
                }
                Section("Rooms") {
                    ForEach(rooms.filter { matches($0.name) || matches($0.id) }) { room in
                        Button(room.name) { app.operations.selectedRoom = room.id; app.section = .rooms; dismiss() }
                    }
                }
            }
        }.padding(20).frame(width: 600, height: 480)
        .onAppear { focused = true; agents = app.operations.agents; rooms = app.operations.rooms }
        .task(id: search) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let values = try await app.sessionStore.page(project: app.projectIdentity, query: SessionQuery(), limit: 50, search: search)
                try Task.checkCancellation(); rows = values.map(\.row)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .task(id: app.projectIdentity) {
            guard let cli = app.cli else { return }
            let identity = app.projectIdentity
            async let a = cli.agents(); async let r = cli.rooms()
            let values = (try? await a, try? await r)
            guard !Task.isCancelled, identity == app.projectIdentity else { return }
            if let a = values.0 { agents = a; app.operations.agents = a }
            if let r = values.1 { rooms = r; app.operations.rooms = r }
        }
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
}
