import ObserverCore
import CryptoKit
import Foundation

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Recognizes file headers only; it does not decode or certify the packet records.
enum CaptureHeader {
    // https://github.com/the-tcpdump-group/libpcap/blob/master/pcap-savefile.manfile.in
    // https://www.ietf.org/archive/id/draft-ietf-opsawg-pcapng-06.html#section-4.1
    static func inspect(_ file: URL) throws -> PacketCapture.Format {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let bytes = [UInt8](try handle.read(upToCount: 28) ?? Data())
        guard bytes.count >= 24 else { throw CaptureError.message("The capture header is empty or truncated.") }
        func uint(_ at: Int, _ count: Int, little: Bool) -> UInt32 {
            let b = Array(bytes[at..<(at + count)])
            return (little ? b.reversed().map { $0 } : b).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let magic = Array(bytes.prefix(4))
        if magic == [0x0a, 0x0d, 0x0d, 0x0a] {
            guard bytes.count >= 28 else { throw CaptureError.message("The PCAPNG section header is truncated.") }
            let order = Array(bytes[8..<12])
            guard order == [0x4d, 0x3c, 0x2b, 0x1a] || order == [0x1a, 0x2b, 0x3c, 0x4d] else {
                throw CaptureError.message("The PCAPNG byte-order marker is invalid.")
            }
            let little = order[0] == 0x4d
            let length = uint(4, 4, little: little)
            guard length >= 28, length % 4 == 0, UInt64(length) <= size,
                  uint(12, 2, little: little) == 1, uint(14, 2, little: little) == 0 else {
                throw CaptureError.message("The PCAPNG section header is invalid or unsupported.")
            }
            try handle.seek(toOffset: UInt64(length - 4))
            let tail = [UInt8](try handle.read(upToCount: 4) ?? Data())
            guard tail == Array(bytes[4..<8]) else { throw CaptureError.message("The PCAPNG section lengths do not match.") }
            return .pcapng
        }
        let little = magic == [0xd4, 0xc3, 0xb2, 0xa1] || magic == [0x4d, 0x3c, 0xb2, 0xa1]
        let big = magic == [0xa1, 0xb2, 0xc3, 0xd4] || magic == [0xa1, 0xb2, 0x3c, 0x4d]
        guard little || big else { throw CaptureError.message("This is not an uncompressed PCAP or PCAPNG file.") }
        guard uint(4, 2, little: little) == 2, uint(6, 2, little: little) == 4,
              uint(16, 4, little: little) > 0 else {
            throw CaptureError.message("The PCAP header is invalid or unsupported (expected version 2.4).")
        }
        return .pcap
    }
}

/// Durable attachments live outside the disposable recording cache. Each committed directory
/// contains a capture and manifest; publishing the directory makes the pair atomic.
actor AttachmentStore {
    static let shared = AttachmentStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveKit Observer/attachments", isDirectory: true))
    let root: URL
    private var catalog: [UUID: PacketCapture]?
    private var reservedBytes: Int64 = 0

    init(root: URL) { self.root = root }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func directory(session: CaptureSession, id: UUID) -> URL {
        root.appendingPathComponent(Self.digest(session.projectKey), isDirectory: true)
            .appendingPathComponent(Self.digest(session.sessionID), isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func file(for capture: PacketCapture) -> URL {
        directory(session: capture.session, id: capture.id).appendingPathComponent(capture.filename)
    }

    func all() throws -> [PacketCapture] {
        if let catalog { return catalog.values.sorted { $0.importedAt < $1.importedAt } }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Only abandoned staging folders are disposable. Never clean committed attachments here.
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(".partial-") {
            try? fm.removeItem(at: url)
        }
        var loaded: [UUID: PacketCapture] = [:]
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator?.skipDescendants(); continue }
            guard url.lastPathComponent == "manifest.json" else { continue }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024,
                  let item = try? JSONDecoder().decode(PacketCapture.self, from: Data(contentsOf: url)),
                  item.byteCount >= 24, item.byteCount <= Int64.max / 2,
                  item.sha256.count == 64, item.sha256.allSatisfy({ $0.isHexDigit }),
                  url.deletingLastPathComponent().standardizedFileURL == directory(session: item.session, id: item.id).standardizedFileURL
            else { throw CaptureError.message("An attachment manifest could not be read: \(url.lastPathComponent). Your files have been preserved.") }
            loaded[item.id] = item
        }
        catalog = loaded
        return loaded.values.sorted { $0.importedAt < $1.importedAt }
    }

    func importFile(_ source: URL, session: CaptureSession, limit: Int64,
                    progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> PacketCapture {
        try Task.checkCancellation()
        let existing = try all()
        let attributes = try Self.attributes(of: source)
        guard source.isFileURL, attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size >= 24 else {
            throw CaptureError.message("Choose a readable, nonempty capture file.")
        }
        let bytes = Int64(size)
        let used = existing.reduce(Int64(0)) { min(Int64.max / 2, $0 + $1.byteCount) }
        var capacityError: String?
        if limit <= 0 || bytes > limit - min(limit, used + reservedBytes) {
            capacityError = "The packet-capture storage limit would be exceeded. Increase the limit or remove an attachment."
        }
        if let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           bytes > free - min(free, reservedBytes + 16 * 1024 * 1024) {
            capacityError = "There is not enough free disk space to import this capture."
        }
        if let capacityError {
            // A full library can still accept a duplicate without allocating another copy.
            if existing.contains(where: { $0.session.projectKey == session.projectKey && $0.session.sessionID == session.sessionID && $0.byteCount == bytes }) {
                let task = Task.detached(priority: .utility) {
                    _ = try CaptureHeader.inspect(source)
                    let checksum = try CaptureFileIO.checksum(source, expectedSize: bytes, progress: progress)
                    try Self.checkUnchanged(source, before: attributes)
                    return checksum
                }
                let checksum = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                if let duplicate = duplicate(session: session, checksum: checksum) { return duplicate }
            }
            throw CaptureError.message(capacityError)
        }
        reservedBytes += bytes
        defer { reservedBytes -= bytes }
        let partial = root.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: partial) }
        let task = Task.detached(priority: .utility) {
            let format = try CaptureHeader.inspect(source)
            let destination = partial.appendingPathComponent("capture." + format.rawValue)
            let checksum = try CaptureFileIO.copy(source, to: destination, expectedSize: bytes, progress: progress)
            try Self.checkUnchanged(source, before: attributes)
            // Recheck the copied header, independent of the source's filename or later edits.
            guard try CaptureHeader.inspect(destination) == format else { throw CaptureError.message("The capture changed during import.") }
            return (format, checksum)
        }
        let (format, checksum) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        // Actor isolation makes deduplication and publication atomic across concurrent callers.
        if let duplicate = duplicate(session: session, checksum: checksum) { return duplicate }
        let item = PacketCapture(id: UUID(), session: session, originalName: source.lastPathComponent,
                                 format: format, byteCount: bytes, sha256: checksum, importedAt: Date(), source: "manualImport")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(item).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        let final = directory(session: session, id: item.id)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: partial, to: final)
        catalog?[item.id] = item
        return item
    }

    private func duplicate(session: CaptureSession, checksum: String) -> PacketCapture? {
        catalog?.values.first {
            $0.session.projectKey == session.projectKey && $0.session.sessionID == session.sessionID
                && $0.sha256 == checksum && FileManager.default.fileExists(atPath: file(for: $0).path)
        }
    }

    private static func attributes(of file: URL) throws -> URLResourceValues {
        var file = file
        file.removeAllCachedResourceValues()
        return try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
    }

    private static func checkUnchanged(_ source: URL, before: URLResourceValues) throws {
        let after = try attributes(of: source)
        guard after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else {
            throw CaptureError.message("The source changed during import. Wait until the capture is finished, then retry.")
        }
    }

    func remove(_ capture: PacketCapture) throws {
        _ = try all()
        guard catalog?[capture.id] == capture else { throw CaptureError.message("The attachment no longer exists.") }
        try FileManager.default.removeItem(at: directory(session: capture.session, id: capture.id))
        catalog?.removeValue(forKey: capture.id)
    }

    func export(_ items: [PacketCapture], to folder: URL) async throws {
        let sources = items.map { (item: $0, file: file(for: $0)) }
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard !resolvedFolder.path.hasPrefix(resolvedRoot.path + "/"), resolvedFolder != resolvedRoot else {
            throw CaptureError.message("Choose an export location outside Observer's attachment storage.")
        }
        let task = Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: folder.path) else { throw CaptureError.message("The capture export folder already exists. Choose a new destination.") }
            let temp = folder.deletingLastPathComponent().appendingPathComponent(".capture-export-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temp) }
            struct Entry: Encodable { let attachment: PacketCapture; let path: String }
            var manifest: [Entry] = []
            for (item, source) in sources {
                try Task.checkCancellation()
                let name = item.id.uuidString + "." + item.format.rawValue
                let hash = try CaptureFileIO.copy(source, to: temp.appendingPathComponent(name), expectedSize: item.byteCount)
                guard hash == item.sha256 else { throw CaptureError.message("\(item.originalName) has changed since it was imported.") }
                manifest.append(Entry(attachment: item, path: name))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: temp.appendingPathComponent("manifest.json"), options: .atomic)
            try Task.checkCancellation()
            try fm.moveItem(at: temp, to: folder)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

enum CaptureFileIO {
    /// At most 1 MiB of capture bytes in memory, independent of file size.
    static func copy(_ source: URL, to destination: URL, expectedSize: Int64,
                     progress: @Sendable (Int64, Int64) -> Void = { _, _ in }) throws -> String {
        try transfer(source, to: destination, expectedSize: expectedSize, progress: progress)
    }

    static func checksum(_ source: URL, expectedSize: Int64,
                         progress: @Sendable (Int64, Int64) -> Void) throws -> String {
        try transfer(source, to: nil, expectedSize: expectedSize, progress: progress)
    }

    private static func transfer(_ source: URL, to destination: URL?, expectedSize: Int64,
                                 progress: @Sendable (Int64, Int64) -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var output: FileHandle?
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CaptureError.message("Could not create the capture file.")
            }
            output = try FileHandle(forWritingTo: destination)
        }
        defer { try? output?.close() }
        var hash = SHA256(), copied: Int64 = 0
        var lastUpdate = Date.distantPast
        while true {
            // FileHandle bridges through Foundation. Without a per-chunk pool, autoreleased
            // buffers can accumulate for the entire detached task despite the small read size.
            let finished = try autoreleasepool {
                try Task.checkCancellation()
                let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { return true }
                copied += Int64(data.count)
                guard copied <= expectedSize else { throw CaptureError.message("The source grew during the transfer. Retry once it is complete.") }
                try output?.write(contentsOf: data)
                hash.update(data: data)
                if Date().timeIntervalSince(lastUpdate) >= 0.1 {
                    progress(copied, expectedSize)
                    lastUpdate = Date()
                }
                return false
            }
            if finished { break }
        }
        guard copied == expectedSize else { throw CaptureError.message("The source was truncated during the transfer.") }
        try output?.synchronize()
        progress(copied, expectedSize)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
