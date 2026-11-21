import ObserverCore
import Foundation
import Observation

@MainActor @Observable
final class CostHistoryModel {
    static let shared = CostHistoryModel()
    var progress: [String: CostHistoryProgress] = [:]
    var running: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    func pause(_ project: String) { tasks[project]?.cancel() }
    func load(_ projects: [String]) async {
        for id in projects where !running.contains(id) { progress[id] = try? await SessionStore.shared.historyProgress(project: id) }
    }
    func start(project: ProjectRef, cli: LiveKitCLI?, plan: PricePlan, priceDate: Date?, reprice: Bool, restart: Bool = false, maximumSessions: Int = 100) {
        guard !running.contains(project.id), running.count < 2 else { return }
        let id = project.id
        running.insert(id)
        var source = cli; source?.priority = .background
        tasks[id] = Task {
            defer { running.remove(id); tasks.removeValue(forKey: id) }
            var state = (try? await SessionStore.shared.historyProgress(project: id)) ?? CostHistoryProgress()
            if restart || state.finished || state.repricing != reprice { state = CostHistoryProgress(); state.repricing = reprice }
            let initialCount = state.completed
            do {
                while true {
                    if state.completed - initialCount >= max(1, min(1000, maximumSessions)) { state.message = "Batch complete. Resume for the next indexed calls."; break }
                    try Task.checkCancellation()
                    let page = try await SessionStore.shared.page(project: id, query: state.query, after: state.bookmark, limit: 100)
                    if page.isEmpty { state.finished = true; state.message = "Calculation complete for indexed history in this range."; break }
                    for item in page {
                        if state.completed - initialCount >= max(1, min(1000, maximumSessions)) { break }
                        try Task.checkCancellation()
                        do {
                            if reprice {
                                if let usage = try await SessionStore.shared.costUsage(project: id, id: item.row.id) {
                                    try await SessionStore.shared.saveCostUsage(project: id, id: item.row.id, usage: usage.repriced(plan: plan, priceDate: priceDate))
                                }
                            } else if item.row.session != nil {
                                guard let source else { throw LiveKitCLIError(kind: .missingCLI, message: "Configure lk to calculate new usage. Saved usage can be repriced offline.") }
                                let documents = await SessionResources.load(source: source, id: item.row.id)
                                try Task.checkCancellation()
                                if documents.values.allSatisfy({ if case .failure = $0 { return true }; return false }) {
                                    throw LiveKitCLIError(kind: .failed, message: "No usage data could be loaded for \(item.row.id). Resume to retry this call.")
                                }
                                let usage = CostUsageSnapshot.make(row: item.row, documents: documents, plan: plan, priceDate: priceDate)
                                try await SessionStore.shared.saveCostUsage(project: id, id: item.row.id, usage: usage)
                                for (kind, value) in documents {
                                    let state: ResourceReadiness
                                    switch value { case .success(let doc): state = doc.readiness; case .failure(let error): state = ResourceReadiness(error: error) }
                                    try await SessionStore.shared.recordResource(project: id, id: item.row.id, kind: kind, readiness: state)
                                }
                            }
                            state.completed += 1; state.bookmark = SessionBookmark(item.row); state.message = nil; state.updated = .now
                            try await SessionStore.shared.saveHistoryProgress(project: id, progress: state)
                            progress[id] = state
                        } catch is CancellationError { throw CancellationError() }
                        catch { state.failed += 1; throw error }
                    }
                }
            } catch is CancellationError { state.message = "Paused. Resume continues after the last saved call." }
            catch { state.message = error.localizedDescription }
            state.updated = .now; progress[id] = state
            try? await SessionStore.shared.saveHistoryProgress(project: id, progress: state)
        }
    }
}
