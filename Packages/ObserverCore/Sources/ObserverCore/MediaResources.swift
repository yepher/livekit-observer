import Foundation

public enum MediaResources {
    public static let downloads = WorkScheduler(limit: 2, backgroundLimit: 1, queueLimit: 12)
    // Serial decoding also prevents two windows writing the same derived channel files.
    public static let analysis = WorkScheduler(limit: 1, backgroundLimit: 1, queueLimit: 12)
    public static func compute<T: Sendable>(project: String, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await analysis.perform(project: project) {
            let worker = Task.detached(priority: .userInitiated) { try operation() }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }
}

/// Disposable recordings only. Durable attachments, annotations, AI results and exports are outside this root.
public actor MediaCache {
    public init() {}
    public static let shared = MediaCache()
    private var leases: [UUID: Set<String>] = [:]
    public func pin(_ files: [URL], lease: UUID) {
        leases[lease] = Set(files.map(\.path))
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }
    public func release(_ lease: UUID) { leases.removeValue(forKey: lease) }
    public struct Limits: Sendable {
        public let recordings: Int64, decoded: Int64
        public static var configured: Self {
            let defaults = UserDefaults.standard
            func bytes(_ key: String, fallback: Int) -> Int64 { Int64(max(1, min(100, defaults.object(forKey: key) as? Int ?? fallback))) * 1_073_741_824 }
            return Self(recordings: bytes("recordingCacheGB", fallback: 2), decoded: bytes("decodedCacheGB", fallback: 4))
        }
    
    public init(recordings: Int64, decoded: Int64) { self.recordings = recordings; self.decoded = decoded }
}
    public func prune(root: URL, limits: Limits = .configured) throws {
        struct File { let url: URL, size: Int64, date: Date, decoded: Bool, pinned: Bool }
        var files: [File] = []
        let pins = leases.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for name in ["livekit", "recordings"] {
            guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(name), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let value = try url.resourceValues(forKeys: keys)
                guard value.isRegularFile == true, value.isSymbolicLink != true else { continue }
                // Keep recently written partials safe even if their creating window has just closed.
                let date = value.contentModificationDate ?? .distantPast
                let pinned = pins.contains { url.path == $0 || url.path.hasPrefix($0 + ".") } || Date().timeIntervalSince(date) < 60
                files.append(File(url: url, size: Int64(value.fileSize ?? 0), date: date, decoded: url.lastPathComponent.contains(".ch") && (url.pathExtension == "caf" || url.pathExtension == "partial"), pinned: pinned))
            }
        }
        for decoded in [false, true] {
            let group = files.filter { $0.decoded == decoded }
            var size = group.reduce(Int64(0)) { $0 + $1.size }
            let limit = decoded ? limits.decoded : limits.recordings
            for file in group.filter({ !$0.pinned }).sorted(by: { $0.date < $1.date }) where size > limit {
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: file.url); size -= file.size
            }
        }
    }
}
