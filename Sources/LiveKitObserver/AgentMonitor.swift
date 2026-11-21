import ObserverCore
import AppKit
import Observation
import SwiftUI
import UserNotifications

@MainActor @Observable
final class AgentMonitor {
    var agents: [CloudAgent] = []
    var projectName = ""
    var error: String?
    var updatedAt: Date?
    private var projectID = ""
    func watch(cli: LiveKitCLI?, project: ProjectRef?, background: Bool) async {
        guard let cli, let project else { return }
        if projectID != project.id { agents = []; projectID = project.id; updatedAt = nil }
        projectName = project.name
        while !Task.isCancelled {
            do {
                var backgroundCLI = cli; backgroundCLI.priority = .background
                let current = try await backgroundCLI.agents()
                try Task.checkCancellation()
                if UserDefaults.standard.bool(forKey: "agentHealthNotifications") {
                    for agent in current {
                        guard agents.first(where: { $0.id == agent.id })?.healthy == true,
                              agent.deployments.contains(where: { ["failed", "error", "unhealthy", "offline", "crashed"].contains($0.status.lowercased()) }) else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = "Agent needs attention in \(project.name)"
                        content.body = "\(agent.title): \(agent.status)"
                        content.userInfo = ["project": project.selection, "agent": agent.id]
                        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: project.id + ":" + agent.id, content: content, trigger: nil))
                    }
                }
                agents = current; error = nil; updatedAt = .now
            } catch is CancellationError { return } catch { self.error = error.localizedDescription }
            do { try await Task.sleep(for: .seconds(background ? 300 : 60)) } catch { return }
        }
    }
}

struct AgentHealthMenu: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Text(app.monitor.projectName.isEmpty ? "Select a project in Observer" : app.monitor.projectName)
        Divider()
        ForEach(app.monitor.agents) { agent in
            Button {
                app.section = .agents
                app.operations.configure(cli: app.cli, projectID: app.projectIdentity)
                app.operations.agents = app.monitor.agents; app.operations.selectedAgent = agent.id
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            } label: { Label("\(agent.title) · \(agent.version) · \(agent.status)", systemImage: agent.healthy ? "checkmark.circle" : "exclamationmark.circle") }
        }
        if let error = app.monitor.error { Text(error) }
        if let date = app.monitor.updatedAt { Text("Updated \(date.formatted(date: .omitted, time: .shortened))") }
    }
}

struct AgentHealthSettings: View {
    @AppStorage("agentHealthMonitoring") private var monitoring = false
    @AppStorage("agentHealthNotifications") private var notifications = false
    @State private var message: String?
    var body: some View {
        Form {
            Toggle("Show agent health in the menu bar", isOn: $monitoring)
            Text("Monitors the selected project every minute, or every five minutes while Observer is in the background. Polling stops when Observer exits.").font(.caption).foregroundStyle(.secondary)
            Toggle("Notify when a running agent becomes unhealthy", isOn: $notifications).disabled(!monitoring)
                .onChange(of: notifications) { _, enabled in
                    guard enabled else { return }
                    Task {
                        do { if try await !UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { notifications = false; message = "Notifications are disabled in macOS System Settings." } }
                        catch { notifications = false; message = error.localizedDescription }
                    }
                }
            if let message { Text(message).font(.caption) }
        }.formStyle(.grouped).frame(height: 220)
    }
}
