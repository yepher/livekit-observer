import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class PacketCaptureModel {
    private(set) var items: [PacketCapture] = []
    private(set) var importing = false
    private(set) var exporting = false
    private(set) var importTarget: CaptureSession?
    private(set) var currentFile = ""
    private(set) var transferred: Int64 = 0
    private(set) var total: Int64 = 0
    private(set) var revision = 0
    var message: String?
    var openedCapture: PacketCapture?
    private var importTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var progressID = UUID()
    let store: AttachmentStore

    init(store: AttachmentStore = .shared) { self.store = store }

    var usedBytes: Int64 { items.reduce(0) { min(Int64.max / 2, $0 + $1.byteCount) } }
    func captures(for session: CaptureSession?) -> [PacketCapture] {
        guard let session else { return [] }
        return items.filter { $0.session.projectKey == session.projectKey && $0.session.sessionID == session.sessionID }
    }

    func load() async {
        do { items = try await store.all(); revision += 1 }
        catch { message = error.localizedDescription }
    }

    func chooseFiles(for target: CaptureSession?) {
        guard let target else { message = "Choose a named project in the toolbar before attaching a capture."; return }
        let panel = NSOpenPanel()
        panel.title = "Add Packet Capture"
        panel.message = "Attach to \(target.projectName) / \(target.roomName.isEmpty ? target.sessionID : target.roomName). Observer keeps a copy; your original stays in place."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Content is validated, including valid captures that have an unusual filename extension.
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, to: target)
    }

    @discardableResult
    func importFiles(_ urls: [URL], to target: CaptureSession?) -> Bool {
        guard let target, !urls.isEmpty else { message = "Choose a named project and session before attaching a capture."; return false }
        guard !importing else { message = "An import is already running. Wait for it to finish or cancel it first."; return false }
        guard urls.count <= 100 else { message = "Import up to 100 captures at a time."; return false }
        importing = true
        importTarget = target
        transferred = 0
        total = 0
        let configured = UserDefaults.standard.object(forKey: "captureStorageLimitGB") as? Int ?? 20
        let limit = Int64(min(10_000, max(1, configured))) * 1_000_000_000
        importTask = Task { [self] in
            defer { importing = false; importTask = nil; importTarget = nil; progressID = UUID() }
            var failures: [String] = []
            for url in urls {
                if Task.isCancelled { break }
                currentFile = url.lastPathComponent
                let fileProgressID = UUID()
                progressID = fileProgressID
                transferred = 0
                total = 0
                do {
                    let capture = try await store.importFile(url, session: target, limit: limit) { [weak self] count, size in
                        Task { @MainActor in
                            guard let self, self.progressID == fileProgressID else { return }
                            self.transferred = count
                            self.total = size
                        }
                    }
                    if !items.contains(where: { $0.id == capture.id }) { items.append(capture) }
                    revision += 1
                } catch is CancellationError { break }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { message = "Some captures could not be imported:\n" + failures.joined(separator: "\n") }
        }
        return true
    }

    func cancelImport() { importTask?.cancel() }
    func cancelExport() { exportTask?.cancel() }

    func remove(_ capture: PacketCapture) {
        Task {
            do {
                try await store.remove(capture)
                items.removeAll { $0.id == capture.id }
                revision += 1
            } catch { message = error.localizedDescription }
        }
    }

    func reveal(_ capture: PacketCapture) {
        Task { NSWorkspace.shared.activateFileViewerSelecting([await store.file(for: capture)]) }
    }

    func open(_ capture: PacketCapture) {
        openedCapture = capture
    }

    func openWith(_ capture: PacketCapture) {
        let panel = NSOpenPanel()
        panel.title = "Open Capture With"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let application = panel.url else { return }
        Task { [self] in
            let file = await store.file(for: capture)
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.message = error.localizedDescription } }
            }
        }
    }

    func export(_ captures: [PacketCapture]) {
        guard !captures.isEmpty, !exporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Packet Captures"
        panel.message = "Choose a new folder for the captures and their manifest."
        panel.nameFieldStringValue = "Packet captures " + captures[0].session.sessionID
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        exportTask = Task {
            defer { exporting = false; exportTask = nil }
            do {
                try await store.export(captures, to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
}

struct PacketCapturesView: View {
    let detail: SessionDetail
    @Environment(AppModel.self) private var model
    @State private var removing: PacketCapture?
    @State private var targeted = false
    @AppStorage("captureStorageLimitGB") private var storageLimitGB = 20

    var body: some View {
        let library = model.captures
        let target = model.captureSession(for: detail.row)
        let captures = library.captures(for: target)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Packet captures").font(.title2)
                    Text(target.map { "\($0.projectName) · \($0.sessionID)" } ?? "Choose a named project in the toolbar to attach files.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Add Packet Capture…", systemImage: "plus") { library.chooseFiles(for: target) }
                    .disabled(target == nil || library.importing)
                Button("Export All…", systemImage: "square.and.arrow.up") { library.export(captures) }
                    .disabled(captures.isEmpty || library.exporting)
            }
            Text("Drop PCAP or PCAPNG files here. Open a capture to inspect its packets in Observer. Imported copies stay on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            if captures.isEmpty {
                ContentUnavailableView("No packet captures", systemImage: "doc.badge.plus",
                                       description: Text("Attach a local capture to keep it with this session."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(captures) { capture in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capture.originalName).font(.headline).textSelection(.enabled)
                            Text("\(capture.format.rawValue.uppercased()) · \(Format.bytes(capture.byteCount)) · Imported locally \(capture.importedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { library.open(capture) }
                            .help("Inspect packets in Observer")
                        Menu {
                            Button("Open With…") { library.openWith(capture) }
                            Button("Reveal in Finder") { library.reveal(capture) }
                            Button("Export…") { library.export([capture]) }.disabled(library.exporting)
                            Divider()
                            Button("Remove Attachment…", role: .destructive) { removing = capture }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Text("Capture storage: \(Format.bytes(library.usedBytes)) across all projects").foregroundStyle(.secondary)
                Spacer()
                Text("Limit (GB)")
                TextField("Limit (GB)", value: $storageLimitGB, format: .number).frame(width: 70)
                    .onChange(of: storageLimitGB) { _, value in storageLimitGB = min(10_000, max(1, value)) }
            }.font(.caption)
            Text("Imported attachments are kept until you remove them. Header recognition does not inspect or validate every packet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in library.importFiles(urls, to: target) } isTargeted: { targeted = $0 }
        .confirmationDialog("Remove attachment?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Attachment", role: .destructive) { if let removing { library.remove(removing) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            if let removing { Text("Remove \(removing.originalName) from \(removing.session.projectName) / \(removing.session.sessionID)? The original file and previous exports are kept.") }
        }
    }
}

struct CaptureTransferView: View {
    let library: PacketCaptureModel
    var body: some View {
        if library.importing || library.exporting {
            HStack {
                if library.importing {
                    ProgressView(value: Double(library.transferred), total: Double(max(1, library.total))).frame(width: 110)
                    VStack(alignment: .leading) {
                        Text("Importing \(library.currentFile)").lineLimit(1)
                        Text("\(library.importTarget?.projectName ?? "") · \(library.importTarget?.sessionID ?? "") · \(Format.bytes(library.transferred)) / \(Format.bytes(library.total))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel Import") { library.cancelImport() }
                }
                if library.exporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting captures…")
                    Button("Cancel Export") { library.cancelExport() }
                }
                Spacer()
            }.padding(8).background(.bar)
        }
    }
}
