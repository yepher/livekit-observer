import ObserverCore
import Foundation

/// Bounded pipe reads, deadline, and cancellation for finite commands. Never stores command text in errors.
enum CommandProcess {
    static func run(_ executable: URL, arguments: [String], directory: URL,
                    environment: [String: String], timeout: TimeInterval = 60,
                    outputLimit: Int = 32 * 1024 * 1024) async throws -> LiveKitCLI.Output {
        let state = State()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    var env = ProcessInfo.processInfo.environment
                    env["LK_NO_SKILLS_PROMPT"] = "1"
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                    env.merge(environment, uniquingKeysWith: { _, new in new })
                    process.environment = env
                    let stdout = Pipe(), stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    process.standardInput = FileHandle.nullDevice
                    do { try state.start(process) }
                    catch { continuation.resume(throwing: error); return }
                    let deadline = DispatchWorkItem { state.stop(.timeout) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    let errors = Bytes()
                    let readers = DispatchGroup()
                    readers.enter()
                    DispatchQueue.global().async {
                        errors.data = drain(stderr.fileHandleForReading, limit: 256 * 1024, state: state)
                        readers.leave()
                    }
                    let data = drain(stdout.fileHandleForReading, limit: outputLimit, state: state)
                    readers.wait()
                    process.waitUntilExit()
                    deadline.cancel()
                    let failure = state.finish()
                    if let failure {
                        switch failure {
                        case .cancelled: continuation.resume(throwing: CancellationError())
                        case .timeout: continuation.resume(throwing: LiveKitCLIError(kind: .timeout, message: "The CLI command timed out. Retry when the service is available."))
                        case .tooLarge: continuation.resume(throwing: LiveKitCLIError(kind: .failed, message: "The CLI response exceeded Observer's memory limit. Request a smaller page."))
                        }
                    } else {
                        continuation.resume(returning: LiveKitCLI.Output(status: process.terminationStatus, stdout: data, stderr: errors.data))
                    }
                }
            }
        } onCancel: { state.stop(.cancelled) }
    }

    private static func drain(_ handle: FileHandle, limit: Int, state: State) -> Data {
        defer { try? handle.close() }
        var result = Data()
        while true {
            let bytes: Data = autoreleasepool { (try? handle.read(upToCount: 64 * 1024)) ?? Data() }
            if bytes.isEmpty { return result }
            if result.count + bytes.count <= limit { result.append(bytes) }
            else { state.stop(.tooLarge) }
        }
    }

    private final class Bytes: @unchecked Sendable { var data = Data() }
    private final class State: @unchecked Sendable {
        enum Failure { case cancelled, timeout, tooLarge }
        private let lock = NSLock()
        private var process: Process?
        private var failure: Failure?
        private var finished = false

        func start(_ value: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard failure == nil else { throw CancellationError() }
            do { try value.run(); process = value }
            catch { throw LiveKitCLIError(kind: .missingCLI, message: "Could not run the configured LiveKit CLI.") }
        }

        func stop(_ reason: Failure) {
            lock.lock(); defer { lock.unlock() }
            guard !finished, failure == nil else { return }
            failure = reason
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if !finished, let process = self.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func finish() -> Failure? {
            lock.lock(); defer { lock.unlock() }
            finished = true
            process = nil
            return failure
        }
    }
}
