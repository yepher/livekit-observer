import ObserverCore
import Foundation
import Observation

/// Tails have their own two-process budget; they never occupy finite-command slots.
@MainActor @Observable
final class AgentLogStream {
    static let budget = WorkScheduler(limit: 2, backgroundLimit: 1, queueLimit: 8)
    var lines: [Line] = []
    var error: String?
    var running = false
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        var level: String {
            let lower = text.lowercased()
            if lower.contains("error") || lower.contains("fatal") { return "Error" }
            if lower.contains("warn") { return "Warning" }
            if lower.contains("debug") { return "Debug" }
            return "Info"
        }
    }
    func tail(cli: LiveKitCLI, agent: String, type: String) async {
        lines = []; error = nil; running = true
        defer { running = false }
        do {
            try await Self.budget.perform(project: cli.project ?? "", priority: .interactive) {
                for try await batch in LogPipe.stream(cli: cli, agent: agent, type: type) {
                    try Task.checkCancellation()
                    await self.append(batch)
                }
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func append(_ batch: [String]) {
        lines.append(contentsOf: batch.map { Line(text: $0) })
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
}

private final class LogPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); self.process = process
    }
    func stop() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    static func stream(cli: LiveKitCLI, agent: String, type: String) -> AsyncThrowingStream<[String], Error> {
        let state = LogPipe()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            continuation.onTermination = { _ in state.stop() }
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = cli.executable
                process.arguments = ["--project", cli.project ?? "", "--user-auth", "--yes", "agent", "logs", "--id", agent, "--log-type", type]
                process.currentDirectoryURL = LiveKitCLI.workingDirectory
                var env = ProcessInfo.processInfo.environment; env["NO_COLOR"] = "1"; env["TERM"] = "dumb"; env["LK_NO_SKILLS_PROMPT"] = "1"
                process.environment = env; process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe; process.standardError = pipe
                do {
                    try state.start(process)
                    var pending = Data()
                    while true {
                        let data = pipe.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        pending.append(data)
                        var batch: [String] = []
                        while let newline = pending.firstIndex(of: 10) {
                            batch.append(String(decoding: pending[..<newline].prefix(4096), as: UTF8.self))
                            pending.removeSubrange(...newline)
                            if batch.count == 100 { continuation.yield(batch); batch.removeAll(keepingCapacity: true) }
                        }
                        if !batch.isEmpty { continuation.yield(batch) }
                        if pending.count > 65536 { pending.removeAll(); continuation.yield(["[Observer: oversized log line omitted]"]) }
                    }
                    if !pending.isEmpty { continuation.yield([String(decoding: pending.prefix(4096), as: UTF8.self)]) }
                    process.waitUntilExit()
                    if process.terminationStatus != 0 { throw LiveKitCLIError(kind: .failed, message: "Log stream ended (\(process.terminationStatus)). Retry to reconnect.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
