import ObserverCore
import Foundation

/// Coalesce identical reads across windows; cancelling one consumer leaves the others running.
actor CommandBroker {
    static let shared = CommandBroker()
    struct Request: Hashable, Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL
        let environment: [String: String]
        let timeout: TimeInterval
        /// Mutations get a unique identity and must never be retried or coalesced.
        let nonce: UUID?
    }
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LiveKitCLI.Output, Error>]
    }
    private var jobs: [Request: Job] = [:]

    func run(_ request: Request, project: String, priority: WorkScheduler.Priority) async throws -> LiveKitCLI.Output {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var job = jobs[request] {
                    job.waiters[waiter] = continuation; jobs[request] = job
                    return
                }
                guard jobs.count < 64 else {
                    continuation.resume(throwing: LiveKitCLIError(kind: .busy, message: "Observer has too many pending CLI requests. Try again shortly."))
                    return
                }
                let id = UUID()
                let task = Task {
                    let result: Result<LiveKitCLI.Output, Error>
                    do {
                        result = .success(try await WorkScheduler.shared.perform(project: project, priority: priority) {
                            var output = try await CommandProcess.run(request.executable, arguments: request.arguments, directory: request.directory,
                                                                     environment: request.environment, timeout: request.timeout)
                            // Retry rate-limited reads only, with bounded jittered backoff. No mutation is retried.
                            for attempt in 0..<2 where request.nonce == nil && output.status != 0 {
                                let error = String(decoding: output.stderr, as: UTF8.self).lowercased()
                                guard error.contains("429") || error.contains("resource_exhausted") || error.contains("rate limit") else { break }
                                try await Task.sleep(for: .milliseconds((1 << attempt) * 1000 + Int.random(in: 0...500)))
                                output = try await CommandProcess.run(request.executable, arguments: request.arguments, directory: request.directory,
                                                                      environment: request.environment, timeout: request.timeout)
                            }
                            return output
                        })
                    } catch { result = .failure(error) }
                    finish(request, id: id, result: result)
                }
                jobs[request] = Job(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: { Task { await self.cancel(request, waiter: waiter) } }
    }

    private func cancel(_ request: Request, waiter: UUID) {
        guard var job = jobs[request], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty { jobs.removeValue(forKey: request); job.task.cancel() }
        else { jobs[request] = job }
    }

    private func finish(_ request: Request, id: UUID, result: Result<LiveKitCLI.Output, Error>) {
        guard let job = jobs[request], job.id == id else { return }
        jobs.removeValue(forKey: request)
        for continuation in job.waiters.values { continuation.resume(with: result) }
    }
}
