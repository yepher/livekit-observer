import CryptoKit
import Foundation

public struct AnnotationReference: Codable, Sendable {
    public let project: String
    public let session: CaptureSession
    public var flagged: Bool
    public var noted: Bool

    public init(project: String, session: CaptureSession, flagged: Bool, noted: Bool) { self.project = project; self.session = session; self.flagged = flagged; self.noted = noted }
}

/// Tiny durable references supplement legacy UserDefaults flags. No transcript or media is copied.
public actor AnnotationStore {
    public static let shared = AnnotationStore()
    public static let unassigned = "local:unassigned"
    private let root: URL
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveKit Observer/Annotations")) { self.root = root }
    public func save(_ reference: AnnotationReference) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data((reference.project + ":" + reference.session.sessionID).utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(reference).write(to: root.appendingPathComponent(key + ".json"), options: .atomic)
    }
    public func references() throws -> [AnnotationReference] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }.compactMap {
            guard (try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 16_384 else { return nil }
            return try? JSONDecoder().decode(AnnotationReference.self, from: Data(contentsOf: $0))
        }
    }
    /// Legacy flags have globally unique session IDs but no trustworthy project association.
    /// Keep unknown references in a local-only project instead of assigning them to whichever project is open.
    public func recoverLegacy(flagged: Set<String>, notes: [String: [Flag]]) throws -> [AnnotationReference] {
        let known = try references()
        let associated = Set(known.filter { $0.project != Self.unassigned }.map { $0.session.sessionID })
        for id in flagged.union(notes.keys) where !associated.contains(id) {
            let flags = notes[id] ?? []
            let session = CaptureSession(projectKey: Self.unassigned, projectName: "Unassigned local notes", sessionID: id,
                                         roomName: id, startedAt: flags.map(\.start).min(), endedAt: flags.map(\.end).max())
            try save(AnnotationReference(project: Self.unassigned, session: session, flagged: flagged.contains(id), noted: !flags.isEmpty))
        }
        return try references().filter { $0.project != Self.unassigned || !associated.contains($0.session.sessionID) }
    }
}
