import Foundation
import Testing
@testable import LiveKitObserver

private func pcap(little: Bool = true, nano: Bool = false) -> Data {
    let magic: [UInt8] = nano ? [0xa1, 0xb2, 0x3c, 0x4d] : [0xa1, 0xb2, 0xc3, 0xd4]
    var result = Data(little ? magic.reversed().map { $0 } : magic)
    for (number, width) in [(UInt32(2), 2), (4, 2), (0, 4), (0, 4), (65535, 4), (1, 4)] {
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
        result.append(contentsOf: little ? bytes : bytes.reversed().map { $0 })
    }
    return result
}

private func pcapng(little: Bool) -> Data {
    var data = Data()
    for (number, width) in [(UInt32(0x0a0d0d0a), 4), (28, 4), (0x1a2b3c4d, 4), (1, 2), (0, 2),
                            (UInt32.max, 4), (UInt32.max, 4), (28, 4)] {
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
        data.append(contentsOf: little ? bytes : bytes.reversed().map { $0 })
    }
    return data
}

private struct CaptureFixture {
    let directory: URL
    let store: AttachmentStore
    let session = CaptureSession(projectKey: "lk:test", projectName: "test", sessionID: "RM_test",
                                 roomName: "test room", startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("observer-capture-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AttachmentStore(root: directory.appendingPathComponent("attachments"))
    }
    func source(_ data: Data, name: String = "source.pcap") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct PacketCaptureTests {
    @Test func recognizesByteOrdersAndTimestampVariantsByContents() throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        for little in [true, false] {
            for nano in [true, false] {
                #expect(try CaptureHeader.inspect(f.source(pcap(little: little, nano: nano), name: "misnamed.bin")) == .pcap)
            }
            #expect(try CaptureHeader.inspect(f.source(pcapng(little: little), name: "misnamed.pcap")) == .pcapng)
        }
    }

    @Test func rejectsInvalidAndTruncatedHeadersWithoutAllocatingDeclaredBlockSize() throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        var invalidBlock = pcapng(little: true)
        invalidBlock.replaceSubrange(4..<8, with: [0xfc, 0xff, 0xff, 0xff])
        var mismatch = pcapng(little: false)
        mismatch[27] = 32
        var badVersion = pcap()
        badVersion[4] = 3
        for bytes in [Data(), Data("not a capture".utf8), Data(repeating: 0, count: 28), pcap().prefix(23),
                      pcapng(little: true).prefix(27), invalidBlock, mismatch, badVersion] {
            let url = try f.source(Data(bytes))
            #expect(throws: (any Error).self) { try CaptureHeader.inspect(url) }
        }
    }

    @Test func keepsDurableCopyAfterSourceDeletionAndReload() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let original = pcapng(little: true)
        let source = try f.source(original, name: "call.pcapng")
        let item = try await f.store.importFile(source, session: f.session, limit: 1_000_000)
        try FileManager.default.removeItem(at: source)
        let reloaded = AttachmentStore(root: await f.store.root)
        let all = try await reloaded.all()
        #expect(all == [item])
        #expect(try Data(contentsOf: await reloaded.file(for: item)) == original)
        #expect(item.session.roomName == "test room")
    }

    @Test func duplicatesCommitOnceAndProjectBoundariesArePreserved() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let source = try f.source(pcap())
        async let first = f.store.importFile(source, session: f.session, limit: 1_000_000)
        async let second = f.store.importFile(source, session: f.session, limit: 1_000_000)
        let (a, b) = try await (first, second)
        #expect(a.id == b.id)
        #expect(try await f.store.all().count == 1)
        let other = CaptureSession(projectKey: "lk:other", projectName: "other", sessionID: f.session.sessionID,
                                   roomName: "another project", startedAt: nil, endedAt: nil)
        let c = try await f.store.importFile(source, session: other, limit: 1_000_000)
        #expect(c.id != a.id)
        #expect(await f.store.file(for: c) != f.store.file(for: a))
    }

    @Test func sameNameDifferentBytesDoesNotOverwriteAndRemovalPreservesOriginal() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let source = try f.source(pcap())
        let a = try await f.store.importFile(source, session: f.session, limit: 1_000_000)
        try pcap(little: false).write(to: source)
        let b = try await f.store.importFile(source, session: f.session, limit: 1_000_000)
        #expect(a.id != b.id)
        try await f.store.remove(a)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await f.store.all() == [b])
        #expect(try Data(contentsOf: await f.store.file(for: b)) == pcap(little: false))
    }

    @Test func duplicateIsAcceptedEvenWhenStorageAllowanceIsFull() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let source = try f.source(pcap())
        let original = try await f.store.importFile(source, session: f.session, limit: 24)
        let duplicate = try await f.store.importFile(source, session: f.session, limit: 24)
        #expect(original.id == duplicate.id)
        try pcap(little: false).write(to: source)
        await #expect(throws: (any Error).self) { try await f.store.importFile(source, session: f.session, limit: 24) }
        #expect(try await f.store.all() == [original])
    }

    @Test func invalidImportsAndStorageLimitLeaveNoCommittedOrPartialFiles() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let invalid = try f.source(Data(repeating: 0, count: 40))
        await #expect(throws: (any Error).self) { try await f.store.importFile(invalid, session: f.session, limit: 1_000) }
        let valid = try f.source(pcap())
        await #expect(throws: (any Error).self) { try await f.store.importFile(valid, session: f.session, limit: 10) }
        #expect(try await f.store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: await f.store.root.path).isEmpty)
    }

    @Test func exportsCompleteCaptureWithRelativeManifestAndPreservesExistingDestination() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let item = try await f.store.importFile(f.source(pcap()), session: f.session, limit: 1_000_000)
        let destination = f.directory.appendingPathComponent("export")
        try await f.store.export([item], to: destination)
        let manifest = try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!manifest.contains(f.directory.path))
        #expect(manifest.contains(item.id.uuidString + ".pcap"))
        #expect(try Data(contentsOf: destination.appendingPathComponent(item.id.uuidString + ".pcap")) == pcap())
        await #expect(throws: (any Error).self) { try await f.store.export([item], to: destination) }
        #expect(try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8) == manifest)
        try await f.store.remove(item)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(item.id.uuidString + ".pcap").path))
    }

    @Test func cancellationAndChangingSourceDoNotPublishIncompleteCopies() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        var bytes = pcap()
        bytes.append(Data(repeating: 0, count: 8 * 1024 * 1024))
        let source = try f.source(bytes)
        let task = Task { try await f.store.importFile(source, session: f.session, limit: 100_000_000) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled import succeeded") } catch is CancellationError { }
        #expect(try await f.store.all().isEmpty)
        await #expect(throws: (any Error).self) {
            try await f.store.importFile(source, session: f.session, limit: 100_000_000) { _, _ in
                // Source mutation while the copy is underway must invalidate the import.
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: source.path)
            }
        }
        #expect(try await f.store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: await f.store.root.path).isEmpty)
    }

    @Test func stalePartialImportIsCleanedWithoutDeletingCommittedEvidence() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let item = try await f.store.importFile(f.source(pcap()), session: f.session, limit: 1_000_000)
        let root = await f.store.root
        let stale = root.appendingPathComponent(".partial-abandoned")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let reloaded = AttachmentStore(root: root)
        #expect(try await reloaded.all() == [item])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func cancellationAfterCopyBeginsCleansUp() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        var bytes = pcap()
        bytes.append(Data(repeating: 0, count: 2 * 1024 * 1024))
        let source = try f.source(bytes)
        await #expect(throws: CancellationError.self) {
            try await f.store.importFile(source, session: f.session, limit: 10_000_000) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        #expect(try await f.store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: await f.store.root.path).isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func concurrentImportsCannotExceedStorageAllowance() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let a = try f.source(pcap(), name: "a.pcap")
        let b = try f.source(pcap(little: false), name: "b.pcap")
        async let first = try? f.store.importFile(a, session: f.session, limit: 24)
        async let second = try? f.store.importFile(b, session: f.session, limit: 24)
        let results = await [first, second].compactMap { $0 }
        #expect(results.count == 1)
        #expect(try await f.store.all().count == 1)
    }

    @Test func changedManagedFileCannotPublishIncompleteExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let item = try await f.store.importFile(f.source(pcap()), session: f.session, limit: 1_000_000)
        try pcap(little: false).write(to: await f.store.file(for: item))
        let destination = f.directory.appendingPathComponent("export")
        await #expect(throws: (any Error).self) { try await f.store.export([item], to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).allSatisfy { !$0.hasPrefix(".capture-export-") })
    }

    @Test @MainActor func batchReportsFailureAndKeepsSuccessfulFilesWithOriginalTarget() async throws {
        let f = try CaptureFixture(); defer { f.cleanup() }
        let library = PacketCaptureModel(store: f.store)
        let valid = try f.source(pcap(), name: "good.pcap")
        let invalid = try f.source(Data(repeating: 0, count: 40), name: "bad.pcap")
        var selection = f.session
        #expect(library.importFiles([valid, invalid], to: selection))
        selection = CaptureSession(projectKey: "lk:other", projectName: "other", sessionID: "RM_other",
                                   roomName: "another call", startedAt: nil, endedAt: nil)
        let deadline = Date().addingTimeInterval(10)
        while library.importing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!library.importing)
        #expect(library.captures(for: selection).isEmpty)
        #expect(library.captures(for: f.session).count == 1)
        #expect(library.message?.contains("bad.pcap") == true)
        let reloaded = PacketCaptureModel(store: AttachmentStore(root: await f.store.root))
        await reloaded.load()
        #expect(reloaded.captures(for: f.session).count == 1)
    }
}
