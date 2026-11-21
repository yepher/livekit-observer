import Foundation
import Darwin

import ObserverCore

@main struct SessionIndexBenchmark {
    static func main() async throws {
        let count = Int(CommandLine.arguments.dropFirst().first ?? "1000000")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("observer-session-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("index.sqlite"))
        let query = SessionQuery(days: 30)
        let now = Date()
        let start = Date()
        // First three projects reach 300k summaries each; a fourth brings the workspace to one million.
        for offset in stride(from: 0, to: count, by: 1000) {
            let project = "p_\(offset / 300000)"
            let items: [JSONValue] = (offset..<min(offset + 1000, count)).map { i in
                .object(["sessionId": .string("RM_\(i)"), "roomName": .string("support-\(i)"),
                         "status": .string(i % 100 == 0 ? "active" : "closed"),
                         "startedAt": .string(now.addingTimeInterval(-Double(i % 300000) * 8).ISO8601Format()),
                         "hasDetailData": .bool(true), "tags": .array(i % 10 == 0 ? [.string(Flag.lessonTag)] : [])])
            }
            try await store.ingest(SessionPage(json: .object(["items": .array(items)])), project: project, scope: project, query: query)
            if offset % 100000 == 0 { print("indexed=\(offset + items.count)") }
        }
        var samples: [Double] = [], filters: [Double] = [], workspace: [Double] = [], workspaceFlags: [Double] = []
        for _ in 0..<40 {
            var time = Date()
            let page = try await store.page(project: "p_0", query: query)
            guard page.count == min(100, count) else { fatalError("Page bound or row count failed") }
            samples.append(Date().timeIntervalSince(time) * 1000)
            time = Date()
            _ = try await store.page(project: "p_0", query: query, onlyFlagged: true)
            filters.append(Date().timeIntervalSince(time) * 1000)
            time = Date()
            let projects = (0...max(0, (count - 1) / 300000)).map { "p_\($0)" }
            let across = try await store.workspacePage(projects: projects, query: query)
            guard across.count == min(100, count) else { fatalError("Workspace page bound failed") }
            workspace.append(Date().timeIntervalSince(time) * 1000)
            time = Date()
            _ = try await store.workspacePage(projects: projects, query: query, onlyFlagged: true)
            workspaceFlags.append(Date().timeIntervalSince(time) * 1000)
        }
        let cold = SessionStore(url: folder.appendingPathComponent("index.sqlite"))
        let coldStart = Date()
        _ = try await cold.page(project: "p_0", query: query)
        let p95 = samples.sorted()[37], filteredP95 = filters.sorted()[37]
        print("summaries=\(count) total_seconds=\(Date().timeIntervalSince(start)) cached_page_p95_ms=\(p95) flagged_filter_p95_ms=\(filteredP95) reopen_first_page_ms=\(Date().timeIntervalSince(coldStart) * 1000)")
        print("workspace_page_p95_ms=\(workspace.sorted()[37]) workspace_flags_p95_ms=\(workspaceFlags.sorted()[37])")
        fflush(stdout)
        guard p95 < 300, filteredP95 < 250, workspace.sorted()[37] < 300, workspaceFlags.sorted()[37] < 250 else { fatalError("Index latency exceeded PRD targets") }
    }
}
