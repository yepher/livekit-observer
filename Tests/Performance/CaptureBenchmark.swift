import Foundation

@main struct CaptureBenchmark {
    static func main() async throws {
        let size = Int64(CommandLine.arguments[1])!
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("capture-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("generated.pcap")
        // Recognizable PCAP header followed by sparse synthetic bytes; packet decoding is out of scope.
        let header: [UInt8] = [0xd4, 0xc3, 0xb2, 0xa1, 2, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 1, 0, 0, 0]
        try Data(header).write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let session = CaptureSession(projectKey: "benchmark", projectName: "benchmark", sessionID: "synthetic",
                                     roomName: "Synthetic large-file check", startedAt: nil, endedAt: nil)
        let store = AttachmentStore(root: scratch.appendingPathComponent("attachments"))
        let start = Date()
        let capture = try await store.importFile(source, session: session, limit: size * 2)
        let importSeconds = Date().timeIntervalSince(start)
        try FileManager.default.removeItem(at: source)
        try await store.export([capture], to: scratch.appendingPathComponent("export"))
        let reload = AttachmentStore(root: scratch.appendingPathComponent("attachments"))
        guard try await reload.all() == [capture], capture.byteCount == size else { fatalError("Durability check failed") }
        print("bytes=\(size) import_seconds=\(importSeconds) import_and_verified_export_seconds=\(Date().timeIntervalSince(start))")
    }
}
