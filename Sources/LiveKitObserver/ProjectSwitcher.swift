import ObserverCore
import SwiftUI

struct SessionQueryView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var days = 30
    @State private var status = ""
    @State private var room = ""
    @State private var tag = ""
    var body: some View {
        DisclosureGroup("LiveKit filters", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Started within", selection: $days) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }
                Picker("Status", selection: $status) {
                    Text("All").tag(""); Text("Active").tag("active"); Text("Closed").tag("closed")
                }
                TextField("Room prefix (case sensitive)", text: $room)
                TextField("Session tag", text: $tag)
                Button("Apply and refresh") {
                    var query = SessionQuery(days: days)
                    query.status = status; query.roomPrefix = room; query.tag = tag
                    model.sessionQuery = query
                    Task { await model.applySessionQuery() }
                }
                .disabled(model.loading)
            }.textFieldStyle(.roundedBorder).padding(.top, 6)
        }
        .font(.caption).padding(8)
        .onAppear { restore() }
        .onChange(of: model.project) { restore() }
    }
    private func restore() { status = model.sessionQuery.status; room = model.sessionQuery.roomPrefix; tag = model.sessionQuery.tag }
}

struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @FocusState private var focused: Bool
    private var recent: [String] { UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] }
    private var projects: [ProjectRef] {
        model.projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
            .sorted { (recent.firstIndex(of: $0.selection) ?? 1000) < (recent.firstIndex(of: $1.selection) ?? 1000) }
    }
    private struct Group { let name: String; let workspaceID: String?; let projects: [ProjectRef] }
    private var groups: [Group] {
        let recentProjects = projects.filter { recent.contains($0.selection) }
        let rest = projects.filter { !recent.contains($0.selection) }
        var groups: [Group] = recentProjects.isEmpty ? [] : [Group(name: "Recent", workspaceID: nil, projects: recentProjects)]
        let byWorkspace = Dictionary(grouping: rest, by: { $0.workspaceID ?? "" })
        for key in byWorkspace.keys.sorted() {
            let values = byWorkspace[key]!
            groups.append(Group(name: key.isEmpty ? "Other projects · workspace unknown" : values.first?.workspaceName ?? key,
                                workspaceID: key.isEmpty ? nil : key, projects: values))
        }
        return groups
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch project").font(.title2.bold())
            TextField("Name or project ID", text: $search).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let first = projects.first { select(first) } }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(groups, id: \.name) { group in
                    HStack {
                        Text(group.name).font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        if let workspaceID = group.workspaceID {
                            Button("All projects") { model.workspaceFilter = workspaceID; model.openWorkspaceAfterSwitcher = true; dismiss() }.font(.caption)
                        }
                    }.padding(.top, 8)
                    ForEach(group.projects) { project in
                        Button { select(project) } label: {
                            HStack {
                                Circle().fill(project.color).frame(width: 9, height: 9)
                                VStack(alignment: .leading) {
                                    Text(project.name).font(.headline)
                                    Text(project.workspaceName ?? project.id).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if project.protected { Image(systemName: "lock.shield").help("Protected project") }
                                if project.lkName == nil { Text("Cloud sign-in").font(.caption).foregroundStyle(.secondary) }
                                if project.selection == model.project { Image(systemName: "checkmark") }
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Open in New Window") { openWindow(id: "project", value: project.selection); dismiss() }
                            Toggle("Protected project", isOn: Binding(get: { project.protected }, set: { UserDefaults.standard.set($0, forKey: "protected." + project.id) }))
                            Menu("Project color") {
                                ForEach(["blue", "green", "red", "orange", "purple"], id: \.self) { color in Button(color.capitalized) { UserDefaults.standard.set(color, forKey: "projectColor." + project.id); model.projects = model.projects.map { $0 } } }
                            }
                        }
                    }
                    }
                }
            }
            HStack { Text("Recent projects first · Return selects the first match").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 520, height: 400).onAppear { focused = true }
    }
    private func select(_ project: ProjectRef) { model.selectProject(project.selection); dismiss() }
}

extension ProjectRef {
    var color: Color {
        switch colorName { case "red": return .red; case "green": return .green; case "orange": return .orange; case "purple": return .purple; default: return .blue }
    }
}

struct SessionRowPositions: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
