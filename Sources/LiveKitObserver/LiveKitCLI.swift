import AppKit
import Foundation

struct LiveKitCLIError: LocalizedError, Sendable {
    enum Kind: Sendable { case signedOut, notReady, observabilityOff, missingCLI, projectNotFound, failed }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}

/// A project saved in the `lk` CLI (`lk project list`).
struct LKProject: Identifiable, Hashable, Sendable {
    let name: String
    let url: String
    /// The Cloud project ID (`p_…`) for dashboard links; `lk` knows it only for projects linked with `lk cloud auth`.
    let projectId: String?
    let isDefault: Bool
    var id: String { name }

    /// The Cloud subdomain, `my-app-abc123` in `wss://my-app-abc123.livekit.cloud`.
    var subdomain: String? {
        guard let host = URL(string: url)?.host, host.hasSuffix(".livekit.cloud") else { return nil }
        return host.split(separator: ".").first.map(String.init)
    }

    static func list(from json: JSONValue) -> [LKProject] {
        let items = json.array ?? json["projects"]?.array ?? []
        return items.compactMap { item in
            guard let name = item["Name"]?.string ?? item["name"]?.string, !name.isEmpty else { return nil }
            let id = item["ProjectId"]?.string ?? item["projectId"]?.string ?? item["project_id"]?.string
            return LKProject(name: name, url: item["URL"]?.string ?? item["url"]?.string ?? "",
                             projectId: id.flatMap { $0.isEmpty ? nil : $0 },
                             isDefault: item["IsDefault"]?.bool ?? item["isDefault"]?.bool ?? item["default"]?.bool ?? false)
        }
    }
}

/// Runs `lk` with the developer's own LiveKit sign-in. The app never sees LiveKit credentials; `lk` keeps them.
struct LiveKitCLI: Sendable {
    let executable: URL
    /// The `lk` project to use, by name; nil uses `lk`'s default project.
    let project: String?

    static func locate(override: String = "") -> URL? {
        let candidates = [override, "/opt/homebrew/bin/lk", "/usr/local/bin/lk", NSHomeDirectory() + "/go/bin/lk"]
        return candidates.filter { !$0.isEmpty }.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Commands run here, so no livekit.toml in some other folder can pick the project.
    static var workingDirectory: URL {
        let folder = AppSettings.cacheDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The projects saved in `lk`.
    func projects() async throws -> [LKProject] {
        let result = try await Self.execute(executable, ["project", "list", "--json"], in: Self.workingDirectory)
        guard result.status == 0 else { throw LiveKitCLIError(kind: .failed, message: Self.message(result)) }
        return LKProject.list(from: try JSONValue.parse(result.stdout))
    }

    /// Saves a project in `lk` from its URL, API key, and secret.
    /// `lk` takes them only as arguments, so they are briefly visible to other processes on this Mac.
    func addProject(name: String, url: String, apiKey: String, apiSecret: String) async throws {
        let result = try await Self.execute(executable, ["project", "add", name, "--url", url, "--api-key", apiKey, "--api-secret", apiSecret, "--yes"],
                                            in: Self.workingDirectory)
        guard result.status == 0 else { throw LiveKitCLIError(kind: .failed, message: Self.message(result)) }
    }

    /// The email of the LiveKit Cloud user `lk` is signed in as, or nil when nobody is.
    func signedInUser() async -> String? {
        guard let result = try? await Self.execute(executable, ["cloud", "whoami", "--user-auth", "--json"], in: Self.workingDirectory),
              result.status == 0, let json = try? JSONValue.parse(result.stdout) else { return nil }
        return json["email"]?.string ?? json["id"]?.string
    }

    /// Opens Terminal running an interactive `lk` command, for the browser sign-in flows `lk` runs only in a terminal.
    static func openInTerminal(_ executable: URL, _ arguments: [String]) throws {
        let quoted = ([executable.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = workingDirectory.appendingPathComponent("lk-\(arguments.prefix(2).joined(separator: "-")).command")
        try "#!/bin/sh\n\(quoted)\necho\necho 'Done. Return to LiveKit Observer and refresh.'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw LiveKitCLIError(kind: .failed, message: "Could not open Terminal.") }
    }

    private static func message(_ result: Output) -> String {
        let detail = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("Tip:") && !$0.hasPrefix("warning:") && !$0.hasPrefix("Using ") }.joined(separator: "\n")
        return detail.isEmpty ? "lk exited with status \(result.status)." : detail
    }

    static func dashboardURL(project: String, session: String) -> URL? {
        URL(string: "https://cloud.livekit.io/projects/\(project)/sessions/\(session)")
    }

    func sessions(since days: Int = 30, limit: Int = 200) async throws -> [LiveKitSession] {
        try await analytics(["session", "list", "--since", "\(days)d", "--limit", "\(limit)"]).items.compactMap(LiveKitSession.init(json:))
    }

    /// The dispatch name of the agent that ran the session, read from its first log record.
    /// `settled` is false while LiveKit may still be ingesting the session's logs.
    func agentName(_ id: String) async throws -> (name: String?, settled: Bool) {
        let json = try await analytics(["session", "logs", id, "--limit", "1"])
        let name = json.items.lazy.compactMap { $0["attributes"]?["lk.agent_name"]?.string }.first { !$0.isEmpty }
        return (name, Self.dataState(json) == "settled")
    }

    func transcript(_ id: String) async throws -> (items: [TranscriptItem], status: String?) {
        let json = try await analytics(["session", "transcript", id, "--limit", "5000"])
        return (json.items.enumerated().map { TranscriptItem(json: $1, index: $0) }, Self.dataState(json))
    }

    func logs(_ id: String) async throws -> [LogRecord] {
        try await analytics(["session", "logs", id, "--limit", "20000"]).items.enumerated().map { LogRecord(json: $1, index: $0) }
    }

    func traces(_ id: String) async throws -> [Span] {
        try await analytics(["session", "traces", id, "--limit", "20000"]).items.enumerated().map { Span(json: $1, index: $0) }
    }

    func metrics(_ id: String) async throws -> [MetricPoint] {
        try await analytics(["session", "metrics", id, "--limit", "20000"]).items.enumerated().map { MetricPoint(json: $1, index: $0) }
    }

    /// LiveKit's own recording of the session (agent observability), if one exists.
    /// `settled` is false while LiveKit is still writing it, so a download may be partial.
    func recording(_ id: String) async throws -> (url: URL, startedAt: Date?, settled: Bool)? {
        let json = try await analytics(["session", "recording", id, "--type", "audio"])
        guard let link = json["url"]?.string, !link.isEmpty, let url = URL(string: link) else { return nil }
        return (url, json["recordingStartedAt"]?.date, Self.dataState(json) == "settled")
    }

    private static func dataState(_ json: JSONValue) -> String? {
        json["dataStatus"]?["state"]?.string?.replacingOccurrences(of: "DATA_STATE_", with: "").lowercased()
    }

    private func analytics(_ args: [String]) async throws -> JSONValue {
        let selection = project.map { ["--project", $0] } ?? []
        let result = try await Self.execute(executable, selection + ["analytics"] + args + ["--json", "--user-auth"], in: Self.workingDirectory)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        if result.status == 75 { throw LiveKitCLIError(kind: .notReady, message: "LiveKit is still preparing this data. Try again in a minute.") }
        if stderr.localizedCaseInsensitiveContains("no user is signed in") || stderr.localizedCaseInsensitiveContains("not signed in") {
            throw LiveKitCLIError(kind: .signedOut, message: "Sign in to LiveKit to read session data.")
        }
        if stderr.contains("ObservabilityDisabled") {
            throw LiveKitCLIError(kind: .observabilityOff, message: "Agent observability (user data recording) is off for this LiveKit project, so there is no transcript, log, or trace data.")
        }
        if stderr.localizedCaseInsensitiveContains("project not found") {
            throw LiveKitCLIError(kind: .projectNotFound, message: "The signed-in LiveKit user cannot open project \(project.map { "“\($0)”" } ?? "(lk default)"). Sign in as a member of that project, or pick another.")
        }
        guard result.status == 0 else { throw LiveKitCLIError(kind: .failed, message: Self.message(result)) }
        do { return try JSONValue.parse(result.stdout) }
        catch { throw LiveKitCLIError(kind: .failed, message: "lk returned output that is not JSON.") }
    }

    struct Output: Sendable { let status: Int32; let stdout: Data; let stderr: Data }

    static func execute(_ executable: URL, _ arguments: [String], in directory: URL) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["LK_NO_SKILLS_PROMPT"] = "1"
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: LiveKitCLIError(kind: .missingCLI, message: "Could not run lk: \(error.localizedDescription)"))
                    return
                }
                // Drain both pipes concurrently so a large output cannot block the child.
                let box = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { box.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: stdout, stderr: box.data))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }
