import ObserverCore
import Foundation

struct WorkspaceMembership: Sendable {
    let projectID: String, workspaceID: String, workspaceName: String
}

/// Workspace membership is metadata, refreshed at most once per ten minutes per signed-in user.
/// Each traversal is paged and bounded; undiscovered projects remain explicitly ungrouped.
actor ProjectDirectory {
    static let shared = ProjectDirectory()
    private var cache: [String: (Date, [WorkspaceMembership])] = [:]
    private var work: [String: Task<[WorkspaceMembership], Never>] = [:]
    func memberships(cli: LiveKitCLI, user: String) async -> [WorkspaceMembership] {
        let key = cli.executable.path + ":" + user
        if let value = cache[key], Date().timeIntervalSince(value.0) < 600 { return value.1 }
        if let task = work[key] { return await task.value }
        let task = Task { () -> [WorkspaceMembership] in
            var result: [WorkspaceMembership] = []
            do {
                let workspaces = try await cli.directoryPages(["workspace", "list"], maximumPages: 10)
                for workspace in workspaces.prefix(100) {
                    try Task.checkCancellation()
                    let id = workspace.text("id"), name = workspace.text("name")
                    guard !id.isEmpty else { continue }
                    guard let projects = try? await cli.directoryPages(["workspace", "project", "list", "--workspace", id], maximumPages: 10) else { continue }
                    result += projects.compactMap { item in
                        let project = item["project"] ?? item
                        let projectID = project.text("id")
                        return projectID.isEmpty ? nil : WorkspaceMembership(projectID: projectID, workspaceID: id, workspaceName: name)
                    }
                    if result.count >= 5000 { break }
                }
            } catch {}
            return Array(result.prefix(5000))
        }
        work[key] = task
        let values = await task.value
        work.removeValue(forKey: key)
        cache[key] = (.now, values)
        if cache.count > 3 { cache = [key: cache[key]!] }
        return values
    }
}

extension LiveKitCLI {
    func directoryPages(_ arguments: [String], maximumPages: Int) async throws -> [JSONValue] {
        var cursor: String?, seen = Set<String>(), result: [JSONValue] = []
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let output = try await Self.execute(executable, arguments + ["--user-auth", "--json", "--limit", "100"] + (cursor.map { ["--cursor", $0] } ?? []), in: Self.workingDirectory, priority: .background)
            guard output.status == 0 else { throw LiveKitCLIError(kind: .failed, message: "Workspace membership could not be loaded.") }
            let json = try JSONValue.parse(output.stdout)
            result += json.items
            cursor = (json["pageInfo"] ?? json)["nextCursor"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            guard let next = cursor, seen.insert(next).inserted else { break }
        }
        return result
    }
}
