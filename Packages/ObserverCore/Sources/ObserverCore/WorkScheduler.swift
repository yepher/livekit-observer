import Foundation

/// One process budget for every window. A waiting operation owns no process or worker thread.
public actor WorkScheduler {
    public static let shared = WorkScheduler()
    public enum Priority: Int, Sendable { case interactive, background }
    public struct Snapshot: Sendable { public let running: Int; public let background: Int; public let queued: Int 
    public init(running: Int, background: Int, queued: Int) { self.running = running; self.background = background; self.queued = queued }
}
    private struct Waiter {
        let id: UUID
        let project: String
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }
    private let limit: Int
    private let backgroundLimit: Int
    private let queueLimit: Int
    private var running: [UUID: (String, Priority)] = [:]
    private var waiting: [Waiter] = []
    private var lastProject: String?

    public init(limit: Int = 4, backgroundLimit: Int = 2, queueLimit: Int = 64) {
        self.limit = max(1, limit)
        self.backgroundLimit = max(1, min(limit, backgroundLimit))
        self.queueLimit = max(1, queueLimit)
    }

    public func perform<T: Sendable>(project: String, priority: Priority = .interactive,
                             operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard waiting.count < queueLimit else {
                    continuation.resume(throwing: LiveKitCLIError(kind: .busy, message: "Observer's work queue is full. Try again after current work completes."))
                    return
                }
                waiting.append(Waiter(id: id, project: project, priority: priority, continuation: continuation))
                pump()
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
        defer { running.removeValue(forKey: id); pump() }
        try Task.checkCancellation()
        return try await operation()
    }

    public func snapshot() -> Snapshot {
        Snapshot(running: running.count, background: running.values.filter { $0.1 == .background }.count, queued: waiting.count)
    }

    private func cancelWaiting(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func pump() {
        while running.count < limit {
            let background = running.values.filter { $0.1 == .background }.count
            let eligible = waiting.indices.filter { waiting[$0].priority == .interactive || background < backgroundLimit }
            guard let best = eligible.map({ waiting[$0].priority.rawValue }).min() else { return }
            let prioritized = eligible.filter { waiting[$0].priority.rawValue == best }
            guard let index = prioritized.first(where: { waiting[$0].project != lastProject }) ?? prioritized.first else { return }
            let next = waiting.remove(at: index)
            running[next.id] = (next.project, next.priority)
            lastProject = next.project
            next.continuation.resume()
        }
    }
}

