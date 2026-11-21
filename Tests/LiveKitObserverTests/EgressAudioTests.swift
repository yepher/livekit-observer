import AVFoundation
import Foundation
import Testing
@testable import LiveKitObserver

@Suite @MainActor struct EgressAudioTests {
    private func fixture() throws -> (URL, String, StorageSettings, SessionStore, AppModel, EgressRecording) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ObserverEgress-" + UUID().uuidString)
        let project = "local:egress-" + UUID().uuidString
        let settings = StorageSettings(endpoint: "https://example.invalid", region: "test", bucket: "test-bucket", prefix: "calls")
        let store = SessionStore(url: root.appendingPathComponent("index.sqlite"))
        let model = AppModel(project: project, sessionStore: store, mediaCacheDirectory: root)
        let recording = try JSONDecoder().decode(EgressRecording.self, from: JSONSerialization.data(withJSONObject: [
            "egressId": "EG_test", "roomId": "RM_test", "roomName": "test", "startedAt": 100.0,
            "endedAt": 101.0, "audioKey": "tone.caf", "size": 0
        ]))
        AppSettings.setStorage(settings, secret: nil, for: project)
        return (root, project, settings, store, model, recording)
    }

    private func source(_ project: String, _ settings: StorageSettings) -> String {
        [project, settings.endpoint, settings.bucket, settings.prefix].joined(separator: "|")
    }

    private func writeAudio(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<16_000 { samples[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 16_000) }
        let output = try AVAudioFile(forWriting: file, settings: format.settings)
        try output.write(from: buffer)
    }

    private func cleanup(_ root: URL, _ project: String, _ model: AppModel) {
        model.player.unload()
        UserDefaults.standard.removeObject(forKey: "storage." + project)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func summaryWithoutRecordingResolvesIndexedAudioAndBuildsMelSpectrogram() async throws {
        let (root, project, settings, store, model, recording) = try fixture()
        defer { cleanup(root, project, model) }
        try writeAudio(model.egressFile(recording))
        // Workspace summaries omit recordings; the manifest may also precede its size listing.
        try await store.saveRecordingPage(source: source(project, settings), project: project, objects: [],
                                          manifests: [("call.json", recording)], scan: RecordingScan())
        let detail = SessionDetail(row: SessionRow(id: recording.roomId))
        model.detail = detail
        await model.loadAudio(detail)
        #expect(detail.sources.map(\.kind) == [.egress])
        #expect(detail.egressError == nil)
        #expect(model.player.isLoaded)
        await model.analyze(detail)
        let mel = try #require(detail.spectrograms[.egress])
        #expect(mel.channels.count == 1)
        #expect(mel.frameCount > 90)
        #expect(mel.image(channel: 0, from: 0, to: 1, columns: 100) != nil)
    }

    @Test func lateManifestReloadsTheOpenSessionWithoutReselectingIt() async throws {
        let (root, project, _, _, model, recording) = try fixture()
        defer { cleanup(root, project, model) }
        let detail = SessionDetail(row: SessionRow(id: recording.roomId))
        model.detail = detail
        await model.loadAudio(detail)
        #expect(detail.sources.isEmpty)
        try writeAudio(model.egressFile(recording))
        var updated = detail.row; updated.recording = recording
        await model.updateOpenRow(updated)?.value
        #expect(model.detail === detail)
        #expect(detail.sources.map(\.kind) == [.egress])
        #expect(detail.audioError == nil)
        await model.analyze(detail)
        #expect(detail.spectrograms[.egress]?.frameCount ?? 0 > 90)
        #expect(model.updateOpenRow(updated) == nil)
        #expect(model.updateOpenRow(SessionRow(id: "another-session", recording: recording)) == nil)
    }

    @Test func recordingLookupIsScopedAndUsesSizesDiscoveredOnLaterPages() async throws {
        let (root, project, settings, store, model, recording) = try fixture()
        defer { cleanup(root, project, model) }
        let key = source(project, settings)
        try await store.saveRecordingPage(source: key, project: project, objects: [], manifests: [("call.json", recording)], scan: RecordingScan())
        try await store.saveRecordingPage(source: key, project: project, objects: [StorageObject(key: recording.audioKey, size: 2048)], manifests: [], scan: RecordingScan(complete: true))
        #expect(try await store.recording(project: project, id: recording.roomId, source: key)?.size == 2048)
        #expect(try await store.recording(project: "other-project", id: recording.roomId, source: key) == nil)
        #expect(try await store.recording(project: project, id: recording.roomId, source: "other-bucket") == nil)
    }

    @Test func migratedProjectReusesLegacyCacheOnlyForTheSameStorage() throws {
        let (root, project, settings, _, model, recording) = try fixture()
        let legacy = "legacy-" + UUID().uuidString
        let defaults = UserDefaults.standard
        defer {
            cleanup(root, project, model)
            for key in ["storage." + legacy, "projectIdentity." + legacy, "storageSecretAlias." + project] { defaults.removeObject(forKey: key) }
        }
        defaults.set(try JSONEncoder().encode(settings), forKey: "storage." + legacy)
        defaults.set(project, forKey: "projectIdentity." + legacy)
        defaults.set(legacy, forKey: "storageSecretAlias." + project)
        let oldFile = root.appendingPathComponent("recordings").appendingPathComponent(legacy).appendingPathComponent(recording.audioKey)
        try writeAudio(oldFile)
        #expect(model.egressFile(recording) == oldFile)
        var changed = settings; changed.bucket = "different-bucket"
        AppSettings.setStorage(changed, secret: nil, for: project)
        #expect(model.egressFile(recording) != oldFile)
    }
}
