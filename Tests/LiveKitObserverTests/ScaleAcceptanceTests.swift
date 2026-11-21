import AppKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
@testable import LiveKitObserver

/// Opt-in hosted-app acceptance check. Run scripts/check-app-scale.sh; no Cloud calls or media.
final class ScaleAcceptanceTests: XCTestCase {
    @MainActor func testMillionSummaryWorkspace() async throws {
        guard ProcessInfo.processInfo.environment["OBSERVER_SCALE_TEST"] == "1" else { throw XCTSkip("Run scripts/check-app-scale.sh for the million-row acceptance check.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("observer-app-scale-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.sqlite"), store = SessionStore(url: path)
        let query = SessionQuery(), now = Date(), projects = (0..<4).map { "local:scale-\($0)" }
        let app = AppModel(project: projects[0], sessionStore: store)
        let workspace = WorkspaceModel(store: store)
        let projectView = NSHostingView(rootView: SessionListView().environment(app))
        let workspaceView = NSHostingView(rootView: WorkspaceSessionList(workspace: workspace, name: { $0 }, open: { _ in }))
        let container = NSStackView(views: [projectView, workspaceView]); container.orientation = .horizontal; container.distribution = .fillEqually
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container; window.orderFront(nil)
        defer { window.close() }
        func rss() -> UInt64 {
            var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            return status == KERN_SUCCESS ? info.resident_size : 0
        }
        var dbSamples: [Double] = []
        func render(view: Int = 0, flagged: Bool = false, after: SessionBookmark? = nil, workspaceAfter: SessionStore.WorkspaceRow? = nil) async throws {
            let dbStart = CACurrentMediaTime()
            let projectRows = view != 2 ? try await store.page(project: projects[0], query: query, after: after, onlyFlagged: flagged).map(\.row) : nil
            let workspaceRows = view != 1 ? try await store.workspacePage(projects: projects, query: query, after: workspaceAfter, onlyFlagged: flagged) : nil
            if flagged { dbSamples.append((CACurrentMediaTime() - dbStart) * 1000) }
            if let projectRows { app.rows = projectRows }
            if let workspaceRows { workspace.rows = workspaceRows }
            // Let SwiftUI consume Observation changes, then force actual AppKit layout/display.
            try await Task.sleep(for: .milliseconds(16))
            container.layoutSubtreeIfNeeded(); projectView.displayIfNeeded(); workspaceView.displayIfNeeded(); CATransaction.flush()
        }
        var baseline: UInt64 = 0, peak: UInt64 = 0
        let started = Date()
        for offset in stride(from: 0, to: 1_000_000, by: 1000) {
            let page: SessionPage = try autoreleasepool {
                let items: [JSONValue] = (offset..<offset + 1000).map { i in
                    .object(["sessionId": .string("RM_\(i)"), "roomName": .string("support-\(i)"), "status": .string("closed"),
                             "startedAt": .string(now.addingTimeInterval(-Double(i % 300000) * 8).ISO8601Format()),
                             "tags": .array(i % 10 == 0 ? [.string(Flag.lessonTag)] : [])])
                }
                return try SessionPage(json: .object(["items": .array(items)]))
            }
            try await store.ingest(page, project: projects[offset / 300000], scope: "scale", query: query)
            if offset == 9000 {
                for _ in 0..<5 { try await render() }
                baseline = rss(); peak = baseline
            }
            if offset >= 10000 { peak = max(peak, rss()) }
        }
        // One user interaction changes one list. Keep both lists visible for whole-app
        // memory, but measure each project/workspace page and filter independently.
        var projectPages: [Double] = [], workspacePages: [Double] = []
        var projectFilters: [Double] = [], workspaceFilters: [Double] = []
        for _ in 0..<40 {
            var time = CACurrentMediaTime()
            try await render(view: 1, after: app.rows.last.map(SessionBookmark.init))
            projectPages.append((CACurrentMediaTime() - time) * 1000)
            time = CACurrentMediaTime(); try await render(view: 1, flagged: true)
            projectFilters.append((CACurrentMediaTime() - time) * 1000)
            time = CACurrentMediaTime()
            try await render(view: 2, workspaceAfter: workspace.rows.last)
            workspacePages.append((CACurrentMediaTime() - time) * 1000)
            time = CACurrentMediaTime(); try await render(view: 2, flagged: true)
            workspaceFilters.append((CACurrentMediaTime() - time) * 1000); peak = max(peak, rss())
        }
        let reopened = SessionStore(url: path), coldStart = CACurrentMediaTime()
        app.rows = try await reopened.page(project: projects[0], query: query).map(\.row)
        workspace.rows = try await reopened.workspacePage(projects: projects, query: query)
        try await Task.sleep(for: .milliseconds(16)); container.layoutSubtreeIfNeeded(); container.displayIfNeeded(); CATransaction.flush()
        let cold = (CACurrentMediaTime() - coldStart) * 1000
        let delta = peak > baseline ? peak - baseline : 0
        let projectPageP95 = projectPages.sorted()[37], workspacePageP95 = workspacePages.sorted()[37]
        let projectFilterP95 = projectFilters.sorted()[37], workspaceFilterP95 = workspaceFilters.sorted()[37]
        let report: [String: Any] = ["summaries": 1_000_000, "projects": 4, "baselineRows": 10_000, "rowsPerList": 100,
            "baselineAppRSS": baseline, "peakAppRSS": peak, "additionalAppRSS": delta, "projectPageAndRenderP95Ms": projectPageP95, "workspacePageAndRenderP95Ms": workspacePageP95,
            "projectFilterAndRenderP95Ms": projectFilterP95, "workspaceFilterAndRenderP95Ms": workspaceFilterP95,
            "filterDatabaseP95Ms": dbSamples.sorted()[75], "reopenAndRenderMs": cold, "elapsedSeconds": Date().timeIntervalSince(started),
            "mode": "Hosted app with Release optimizations and testability; both production lists visible, interactions measured separately; no media; synthetic data", "system": ProcessInfo.processInfo.operatingSystemVersionString]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/private/tmp/observer-whole-app-scale.json"), options: .atomic)
        print("OBSERVER_APP_SCALE " + String(decoding: data, as: UTF8.self))
        XCTAssertGreaterThan(baseline, 0); XCTAssertLessThanOrEqual(delta, 150_000_000)
        XCTAssertLessThan(projectPageP95, 300); XCTAssertLessThan(workspacePageP95, 300)
        XCTAssertLessThan(projectFilterP95, 250); XCTAssertLessThan(workspaceFilterP95, 250)
        XCTAssertEqual(app.rows.count, 100); XCTAssertEqual(workspace.rows.count, 100)
    }
}
