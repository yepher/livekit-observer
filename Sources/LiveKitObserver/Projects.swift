import ObserverCore
import Foundation
import Yams

struct ProjectRef: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var url: String
    var lkName: String?
    var isDefault = false
    var workspaceID: String?
    var workspaceName: String?
    var projectId: String? { id.hasPrefix("p_") ? id : nil }
    var selection: String { lkName ?? id }
    var subdomain: String? { URL(string: url)?.host?.split(separator: ".").first.map(String.init) }
    var protected: Bool {
        (UserDefaults.standard.object(forKey: "protected." + id) as? Bool) ?? name.localizedCaseInsensitiveContains("prod")
    }
    var colorName: String {
        UserDefaults.standard.string(forKey: "projectColor." + id) ?? (name.localizedCaseInsensitiveContains("prod") ? "red" : name.localizedCaseInsensitiveContains("stag") ? "green" : "blue")
    }

    static func merged(local: [ProjectRef], cloud: JSONValue) -> [ProjectRef] {
        var result = local
        for item in cloud.items {
            guard let id = item["id"]?.string, !id.isEmpty else { continue }
            let url = item["url"]?.string ?? ""
            if let i = result.firstIndex(where: { $0.id == id || (!$0.id.hasPrefix("p_") && !url.isEmpty && URL(string: $0.url)?.host == URL(string: url)?.host) }) {
                let old = result[i]
                result[i] = ProjectRef(id: id, name: item["name"]?.string ?? old.name, url: url.isEmpty ? old.url : url,
                                       lkName: old.lkName, isDefault: old.isDefault, workspaceID: item["workspaceId"]?.string)
            } else {
                result.append(ProjectRef(id: id, name: item["name"]?.string ?? id, url: url, workspaceID: item["workspaceId"]?.string))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Decode only metadata from lk's documented YAML config. Never decode, persist, or log key/token fields.
enum SavedProjects {
    private struct Config: Decodable {
        var default_project: String?
        var projects: [Entry]?
        struct Entry: Decodable { let name: String; let project_id: String?; let url: String? }
    }
    static func decode(_ data: Data) throws -> [ProjectRef] {
        do {
            let config = try YAMLDecoder().decode(Config.self, from: data)
            return (config.projects ?? []).map {
                ProjectRef(id: $0.project_id.flatMap { $0.isEmpty ? nil : $0 } ?? "lk:" + $0.name,
                           name: $0.name, url: $0.url ?? "", lkName: $0.name,
                           isDefault: config.default_project != nil && (config.default_project == $0.name || config.default_project == $0.project_id))
            }
        } catch {
            // YAML errors can include source lines from the credential file. Do not propagate those.
            throw LiveKitCLIError(kind: .failed, message: "Could not read saved project metadata from lk's configuration.")
        }
    }
    static func read() throws -> [ProjectRef] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".livekit/cli-config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw LiveKitCLIError(kind: .failed, message: "The saved CLI configuration exceeds the metadata reader's size limit.") }
        return try decode(Data(contentsOf: url))
    }
}

struct ProjectBrowseState {
    var rows: [SessionRow]
    var selection: String?
    var query: SessionQuery
    var search: String
    var onlyFlagged: Bool
    var onlyRecording: Bool
    var coverage: SessionCoverage?
    var navigation: ProjectNavigation = ProjectNavigation()
}

struct ProjectNavigation: Codable, Sendable {
    var selection: String?
    var anchor: SessionBookmark?
    var section = "Sessions"
    var agent: String?
    var run: String?
    var room: String?
    var query = SessionQuery()
    var search = ""
    var flagged = false
    var recorded = false
    static func load(_ project: String) -> Self {
        UserDefaults.standard.data(forKey: "navigation." + project).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save(_ project: String) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "navigation." + project) }
}

/// Lightweight project state only; audio and spectrograms never enter this cache.
struct ProjectStateCache {
    private var values: [String: ProjectBrowseState] = [:]
    private var order: [String] = []
    mutating func save(_ state: ProjectBrowseState, for project: String) {
        values[project] = state
        order.removeAll { $0 == project }; order.append(project)
        while order.count > 3 { values.removeValue(forKey: order.removeFirst()) }
    }
    func state(for project: String) -> ProjectBrowseState? { values[project] }
    var count: Int { values.count }
}

struct CLIVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int; let minor: Int; let patch: Int
    static let minimum = CLIVersion(major: 2, minor: 19, patch: 4)
    init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    init?(_ text: String) {
        guard let match = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }; self.init(major: parts[0], minor: parts[1], patch: parts[2])
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}
