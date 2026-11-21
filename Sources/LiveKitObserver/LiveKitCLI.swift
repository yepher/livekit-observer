import ObserverCore
import AppKit
import Foundation

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
    var priority: WorkScheduler.Priority = .interactive

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

    /// Cloud metadata never contains API secrets; saved metadata is decoded with an allowlist.
    func projects() async throws -> [ProjectRef] {
        let local = try SavedProjects.read()
        let result = try await Self.execute(executable, ["project", "list", "--user-auth", "--json"], in: Self.workingDirectory)
        guard result.status == 0 else {
            if !local.isEmpty { return local }
            throw LiveKitCLIError(kind: .failed, message: Self.message(result))
        }
        var projects = ProjectRef.merged(local: local, cloud: try JSONValue.parse(result.stdout))
        if let user = await signedInUser() {
            let memberships = await ProjectDirectory.shared.memberships(cli: self, user: user)
            let byProject = Dictionary(memberships.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
            for index in projects.indices {
                if let member = byProject[projects[index].id] {
                    projects[index].workspaceID = member.workspaceID
                    projects[index].workspaceName = member.workspaceName
                }
            }
        }
        return projects
    }

    func version() async throws -> CLIVersion {
        let result = try await Self.execute(executable, ["--version"], in: Self.workingDirectory)
        guard result.status == 0, let version = CLIVersion(String(decoding: result.stdout, as: UTF8.self)) else {
            throw LiveKitCLIError(kind: .tooOld, message: "Could not determine the CLI version. Observer requires lk 2.19.4 or later.")
        }
        guard version >= .minimum else {
            throw LiveKitCLIError(kind: .tooOld, message: "Observer requires lk 2.19.4 or later; installed: \(version). Update livekit-cli with Homebrew.")
        }
        return version
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

    func sessionPage(query: SessionQuery, cursor: String? = nil) async throws -> SessionPage {
        try await SessionPage(json: analytics(query.arguments(cursor: cursor)))
    }

    func session(_ id: String) async throws -> LiveKitSession? {
        let json = try await analytics(["session", "get", id])
        return LiveKitSession(json: json["session"] ?? json)
    }

    /// The dispatch name of the agent that ran the session, read from its first log record.
    /// `settled` is false while LiveKit may still be ingesting the session's logs.
    func agentName(_ id: String) async throws -> (name: String?, settled: Bool) {
        let json = try await analytics(["session", "logs", id, "--limit", "1"])
        let name = json.items.lazy.compactMap { $0["attributes"]?["lk.agent_name"]?.string }.first { !$0.isEmpty }
        return (name, Self.dataState(json) == "settled")
    }

    /// How many moments were flagged from the lesson page, counted from the session's warning log lines.
    /// `settled` is false while LiveKit may still be ingesting the session's logs.
    func lessonFlagCount(_ id: String) async throws -> (count: Int, settled: Bool) {
        let json = try await analytics(["session", "logs", id, "--log-level", "warn", "--limit", "2000"])
        let count = json.items.filter { ($0["message"]?.string ?? "").hasPrefix(Flag.lessonLogPrefix) }.count
        return (count, Self.dataState(json) == "settled")
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

    /// Participants' connected time and the room's bandwidth, for the cost breakdown.
    func roomUsage(_ id: String) async throws -> RoomUsage? {
        RoomUsage(json: try await analytics(["session", "get", id]))
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

    /// The session's data as `lk analytics` returns it, pretty-printed, by file name, for saving to disk.
    /// Fetches each kind separately, so one that fails (with its error in `failures`) does not stop the rest.
    func rawSessionData(_ id: String) async -> (files: [(name: String, data: Data)], failures: [String: String]) {
        let requests: [(name: String, args: [String])] = [
            ("session.json", ["session", "get", id]),
            ("transcript.json", ["session", "transcript", id, "--limit", "5000"]),
            ("logs.json", ["session", "logs", id, "--limit", "20000"]),
            ("traces.json", ["session", "traces", id, "--limit", "20000"]),
            ("metrics.json", ["session", "metrics", id, "--limit", "20000"]),
        ]
        var files: [(name: String, data: Data)] = [], failures: [String: String] = [:]
        await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
            for request in requests {
                group.addTask {
                    do { return (request.name, .success(try await self.analyticsData(request.args))) }
                    catch { return (request.name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let data): files.append((name, Self.prettyPrinted(data)))
                case .failure(let error): failures[name] = (error as? LiveKitCLIError)?.message ?? error.localizedDescription
                }
            }
        }
        return (files.sorted { $0.name < $1.name }, failures)
    }

    private static func prettyPrinted(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return data }
        return pretty
    }

    func analytics(_ args: [String]) async throws -> JSONValue {
        let data = try await analyticsData(args)
        do { return try JSONValue.parse(data) }
        catch { throw LiveKitCLIError(kind: .failed, message: "lk returned output that is not JSON.") }
    }

    private func analyticsData(_ args: [String]) async throws -> Data {
        let selection = project.map { ["--project", $0] } ?? []
        let result = try await Self.execute(executable, selection + ["analytics"] + args + ["--json", "--user-auth"], in: Self.workingDirectory, priority: priority)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        if result.status == 75 { throw LiveKitCLIError(kind: .notReady, message: "LiveKit is still preparing this data. Try again in a minute.") }
        if stderr.localizedCaseInsensitiveContains("no user is signed in") || stderr.localizedCaseInsensitiveContains("not signed in") {
            throw LiveKitCLIError(kind: .signedOut, message: "Sign in to LiveKit to read session data.")
        }
        if stderr.contains("ObservabilityDisabled") {
            throw LiveKitCLIError(kind: .observabilityOff, message: "Agent observability (user data recording) is off for this LiveKit project, so there is no transcript, log, or trace data.")
        }
        if stderr.localizedCaseInsensitiveContains("permission denied") || stderr.contains("403") || stderr.contains("PERMISSION_DENIED") {
            throw LiveKitCLIError(kind: .forbidden, message: "The signed-in user does not have permission for this project data. Session observability requires an Admin role.")
        }
        if stderr.localizedCaseInsensitiveContains("project not found") {
            throw LiveKitCLIError(kind: .projectNotFound, message: "The signed-in LiveKit user cannot open project \(project.map { "“\($0)”" } ?? "(lk default)"). Sign in as a member of that project, or pick another.")
        }
        guard result.status == 0 else { throw LiveKitCLIError(kind: .failed, message: Self.message(result)) }
        return result.stdout
    }

    struct Output: Sendable { let status: Int32; let stdout: Data; let stderr: Data }

    static func execute(_ executable: URL, _ arguments: [String], in directory: URL,
                        environment: [String: String] = [:], priority: WorkScheduler.Priority = .interactive,
                        timeout: TimeInterval = 60) async throws -> Output {
        let project = arguments.firstIndex(of: "--project").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "account"
        let read = isReadOnly(arguments)
        return try await CommandBroker.shared.run(.init(executable: executable, arguments: arguments, directory: directory,
                                                         environment: environment, timeout: timeout, nonce: read ? nil : UUID()),
                                                   project: project, priority: priority)
    }

    static func isReadOnly(_ arguments: [String]) -> Bool {
        // Strip global options with values before interpreting the command path. Resource IDs
        // that happen to say "list" must never turn a mutation into a retried request.
        var index = 0
        let valued: Set<String> = ["--project", "--user", "--config", "--url", "--api-key", "--api-secret", "--subdomain"]
        while index < arguments.count, arguments[index].hasPrefix("--"), arguments[index] != "--version" {
            index += valued.contains(arguments[index]) ? 2 : 1
        }
        let command = Array(arguments.dropFirst(index))
        guard let first = command.first else { return false }
        if first == "--version" || first == "analytics" { return true }
        guard command.count > 1 else { return false }
        switch first {
        case "cloud": return command[1] == "whoami"
        case "project", "workspace": return command[1] == "list"
        case "agent":
            if command[1] == "simulate" { return command.count > 2 && ["list", "get", "export"].contains(command[2]) }
            return ["list", "status", "versions", "secrets"].contains(command[1])
        case "room":
            if command[1] == "participants" { return command.count > 2 && ["list", "get"].contains(command[2]) }
            return command[1] == "list"
        default: return false
        }
    }
}
