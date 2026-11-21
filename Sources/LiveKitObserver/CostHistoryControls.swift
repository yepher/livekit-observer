import ObserverCore
import SwiftUI

struct CostHistoryControls: View {
    let projects: [ProjectRef]
    let refresh: () -> Void
    @Environment(AppModel.self) private var app
    @State private var history = CostHistoryModel.shared
    @State private var selectedProject: ProjectRef?
    @State private var reprice = false
    @State private var restart = false
    @State private var batchSize = 100
    var body: some View {
        DisclosureGroup("Calculate historical costs") {
            ScrollView {
                ForEach(projects.filter { !$0.id.hasPrefix("local:") }) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(project.name).font(.headline); Spacer()
                            if history.running.contains(project.id) {
                                ProgressView().controlSize(.small); Button("Pause") { history.pause(project.id) }
                            } else {
                                Button(history.progress[project.id] == nil || history.progress[project.id]?.finished == true ? "Calculate…" : "Resume…") {
                                    reprice = history.progress[project.id]?.repricing ?? false; restart = false; selectedProject = project
                                }
                                Button("Recalculate…") { reprice = false; restart = true; selectedProject = project }
                                Button("Reprice saved usage…") { reprice = true; restart = true; selectedProject = project }
                            }
                        }
                        if let progress = history.progress[project.id] {
                            Text("\(progress.completed) processed · \(progress.failed) failed · \(progress.message ?? "Working…")").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
            }.frame(maxHeight: 160)
        }
        .task { await history.load(projects.map(\.id)) }
        .onChange(of: history.running) { _, _ in refresh() }
        .sheet(item: $selectedProject) { project in
            VStack(alignment: .leading, spacing: 14) {
                Text(reprice ? "Reprice saved usage" : "Calculate indexed history").font(.title2.bold())
                Text(project.name).font(.headline)
                Text(reprice ? "Uses saved numeric usage and current \(app.plan.name) prices. No session data is downloaded." : "Fetches transcript, logs, traces, metrics and room usage for indexed calls in the last 30 days. Audio and packet captures are not downloaded. Work runs in small batches and can be paused and resumed.")
                Picker("Calls in this batch", selection: $batchSize) { Text("100").tag(100); Text("500").tag(500); Text("1,000").tag(1000) }
                Text("Costs may remain partial when usage is unavailable. Previously calculated calls are replaced, not added twice.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { selectedProject = nil }; Spacer()
                    Button("Start batch") {
                        let cli = app.cli.map { LiveKitCLI(executable: $0.executable, project: project.projectId ?? project.selection) }
                        history.start(project: project, cli: cli, plan: app.plan, priceDate: app.pricing?.fetched, reprice: reprice, restart: restart, maximumSessions: batchSize)
                        selectedProject = nil
                    }.disabled(history.running.count >= 2 || (!reprice && app.cli == nil))
                }
            }.padding(24).frame(width: 540)
        }
    }
}
