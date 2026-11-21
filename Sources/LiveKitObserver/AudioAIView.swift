import ObserverCore
import AVFoundation
import SwiftUI

struct AudioAIView: View {
    let detail: SessionDetail, project: ProjectRef
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "Check transcription"
    @State private var selectedChannel = ""
    @State private var sttModel = "cartesia/ink-whisper"
    @State private var start = 0.0
    @State private var duration = 30.0
    @State private var language = "en"
    @State private var text = ""
    @State private var modelA = "cartesia/sonic-3"
    @State private var modelB = "deepgram/aura-2"
    @State private var voiceA = ""
    @State private var voiceB = ""
    @State private var selectedLine: Date?
    @State private var provenance = TTSProvenance()
    @State private var comparisons: [TranscriptionComparison] = []
    @State private var sampleA: Data?
    @State private var sampleB: Data?
    @State private var recordA: TTSSampleRecord?
    @State private var recordB: TTSSampleRecord?
    @State private var player: AVAudioPlayer?
    @State private var message: String?
    @State private var working = false
    @State private var request: Task<Void, Never>?
    private struct Channel: Identifiable { let id: String, name: String; let url: URL; let origin: Date? }
    private var channels: [Channel] {
        detail.sources.flatMap { source in
            (detail.channelFiles[source.kind] ?? []).enumerated().map { index, url in
                Channel(id: source.kind.rawValue + String(index), name: source.title + " · " + source.channelName(index, of: detail.channelFiles[source.kind]?.count ?? 1, identical: detail.spectrograms[source.kind]?.identicalChannels ?? false), url: url, origin: detail.origin(of: source))
            }
        }
    }
    private var settings: AISettings { AISettings.load(project: project.id) }
    private var pricingFresh: Bool { app.pricing.map { Date().timeIntervalSince($0.fetched) <= PricingCatalog.maximumAge } ?? false }
    private var ttsModels: [String] { Array(Set(app.availableModels(unit: .characters) + [modelA, modelB])).sorted() }
    private var sttCost: Double? { app.plan.rate(model: sttModel, unit: .audioHour).map { max(0, duration) / 3600 * $0 * 1.1 } }
    private func ttsCost(_ model: String) -> Double? { app.plan.rate(model: model, unit: .characters).map { Double(text.utf8.count) / 1e6 * $0 * 1.1 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Audio AI review").font(.title2.bold()); Spacer(); Button("Close") { request?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(project.name) · AI-generated comparisons").foregroundStyle(.secondary)
            Picker("Action", selection: $mode) { Text("Check transcription").tag("Check transcription"); Text("Compare TTS").tag("Compare TTS") }.pickerStyle(.segmented)
            if !settings.enabled { Text("Enable AI for this project in Settings → AI first.").foregroundStyle(.orange) }
            if mode == "Check transcription" { transcription } else { synthesis }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if working { HStack { ProgressView().controlSize(.small); Text("Processing…"); Button("Cancel") { request?.cancel() } } }
        }.padding(24).frame(width: 780)
        .task {
            do {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let data = try await AudioAIStore.shared.load(project: project.id, session: detail.row.id, name: "transcription-comparison.json") { comparisons = try decoder.decode([TranscriptionComparison].self, from: data); detail.transcriptionComparisons = comparisons }
                sampleA = try await AudioAIStore.shared.load(project: project.id, session: detail.row.id, name: "tts-a.wav")
                sampleB = try await AudioAIStore.shared.load(project: project.id, session: detail.row.id, name: "tts-b.wav")
                if let data = try await AudioAIStore.shared.load(project: project.id, session: detail.row.id, name: "tts-a.json") { recordA = try decoder.decode(TTSSampleRecord.self, from: data) }
                if let data = try await AudioAIStore.shared.load(project: project.id, session: detail.row.id, name: "tts-b.json") { recordB = try decoder.decode(TTSSampleRecord.self, from: data) }
            } catch { message = "Saved audio review could not be loaded: \(error.localizedDescription)" }
        }
        .onDisappear { request?.cancel(); player?.stop() }
        .onChange(of: app.projectIdentity) { _, value in if value != project.id { request?.cancel(); dismiss() } }
        .onChange(of: selectedLine) { _, date in
            if let line = detail.ttsStaticFound.first(where: { $0.start == date }) {
                text = line.text; provenance = TTSProvenance.find(at: line.start, spans: detail.spans)
                modelA = provenance.model ?? ""; voiceA = provenance.voice ?? ""
            }
        }
    }
    private var transcription: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the caller's isolated channel. Mixed audio may include the agent and cannot reliably identify who was misheard.").font(.caption).foregroundStyle(.secondary)
            Picker("Recording / channel", selection: $selectedChannel) { Text("Choose a channel").tag(""); ForEach(channels) { Text($0.name).tag($0.id) } }
            Picker("Comparison STT", selection: $sttModel) { Text("Cartesia Ink Whisper").tag("cartesia/ink-whisper"); Text("Deepgram Nova-3").tag("deepgram/nova-3") }
            HStack {
                VStack(alignment: .leading) { Text("Start (seconds)").font(.caption); TextField("Start", value: $start, format: .number) }
                VStack(alignment: .leading) { Text("Length (1–120 seconds)").font(.caption); TextField("Length", value: $duration, format: .number) }
                VStack(alignment: .leading) { Text("Language").font(.caption); TextField("Language", text: $language) }.frame(width: 90)
            }
            Text("Sends the selected audio clip to \(sttModel) through LiveKit Inference. Choose a model different from the original STT. Your original transcript is retained. Differences are suggestions, not proof of an STT error.").font(.caption)
            HStack {
                Text(sttCost.map { String(format: "Estimated charge: $%.4f", $0) } ?? "Price unavailable").font(.caption)
                Spacer(); Button("Send clip and compare") { transcribe() }.disabled(app.inferenceModels[sttModel]?.isRetired() == true || !settings.enabled || !pricingFresh || sttCost == nil || selectedChannel.isEmpty || duration < 1 || duration > 120 || start < 0 || working)
            }
            if !comparisons.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(comparisons) { comparison in
                            GroupBox(comparison.differs ? "Different wording" : comparison.original.isEmpty ? "No comparable original turn" : "Matches") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Original").font(.caption).foregroundStyle(.secondary)
                                    ComparisonWords(comparison: comparison, alternative: false)
                                    Text(comparison.model ?? "Comparison").font(.caption).foregroundStyle(.secondary)
                                    ComparisonWords(comparison: comparison, alternative: true)
                                    Text((comparison.timing ?? "Segment timing") + (comparison.confidence.map { String(format: " · Confidence %.0f%%", $0 * 100) } ?? " · Confidence unknown")).font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Listen") { app.player.play(at: comparison.date) }
                                        if comparison.differs, comparison.decision == nil {
                                            Button("Accept flag") { decide(comparison, accepted: true) }
                                            Button("Dismiss") { decide(comparison, accepted: false) }
                                        } else if let decision = comparison.decision { Text(decision.capitalized).font(.caption) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxHeight: 300)
            }
        }
    }
    private var synthesis: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !detail.ttsStaticFound.isEmpty {
                Picker("Possible static", selection: $selectedLine) { Text("Choose a detected stretch").tag(Date?.none); ForEach(detail.ttsStaticFound) { line in Text(String(line.text.prefix(80))).tag(Optional(line.start)) } }
            }
            TextEditor(text: $text).frame(height: 90).border(.quaternary)
            Text(provenance.evidenceID.map { "Original settings read from span \($0). Missing voice or model fields must be supplied manually." } ?? "Enter the original model and voice for A, and another model/voice for B. Voice identity is not assumed from the recording.").font(.caption).foregroundStyle(.secondary)
            HStack { Picker("A", selection: $modelA) { ForEach(ttsModels, id: \.self) { Text(app.modelLabel($0)).tag($0) } }; TextField("Voice ID", text: $voiceA); Button("Generate A") { synthesize(a: true) }.disabled(disabled(modelA, voiceA)) }
            Text(ttsCost(modelA).map { String(format: "A estimate: $%.4f", $0) } ?? "A price unavailable").font(.caption)
            HStack { Picker("B", selection: $modelB) { ForEach(ttsModels, id: \.self) { Text(app.modelLabel($0)).tag($0) } }; TextField("Voice ID", text: $voiceB); Button("Generate B") { synthesize(a: false) }.disabled(disabled(modelB, voiceB)) }
            Text(ttsCost(modelB).map { String(format: "B estimate: $%.4f", $0) } ?? "B price unavailable").font(.caption)
            Text("Each Generate button sends this text to that model's provider through LiveKit Inference and charges the project. Listen to the original and both versions; a successful regeneration alone does not prove what caused the original static.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Play original") { player?.stop(); app.player.play(at: selectedLine) }.disabled(selectedLine == nil)
                Button("Play A") { play(sampleA) }.disabled(sampleA == nil)
                Button("Play B") { play(sampleB) }.disabled(sampleB == nil)
                Button("Stop") { player?.stop(); app.player.pause() }
            }
            if let recordA { Text("Saved A: \(recordA.model) · voice \(recordA.voice) · \(staticResult(recordA))").font(.caption).foregroundStyle(.secondary) }
            if let recordB { Text("Saved B: \(recordB.model) · voice \(recordB.voice) · \(staticResult(recordB))").font(.caption).foregroundStyle(.secondary) }
            if recordA != nil || recordB != nil { Button("Copy comparison report") {
                let report = "TTS comparison (local heuristic, not a provider fault diagnosis)\n" + [recordA, recordB].enumerated().compactMap { index, record in record.map { "\(index == 0 ? "A" : "B"): \($0.model), voice \($0.voice), \(staticResult($0))\nText: \($0.text)" } }.joined(separator: "\n")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string)
            } }
        }
    }
    private func staticResult(_ record: TTSSampleRecord) -> String { record.possibleStatic.map { $0 ? "Possible static reproduced" : "Static not detected" } ?? "Static analysis unavailable" }
    private func disabled(_ model: String, _ voice: String) -> Bool { app.inferenceModels[model]?.isRetired() == true || !settings.enabled || !pricingFresh || ttsCost(model) == nil || voice.isEmpty || text.isEmpty || text.count > 3000 || working }
    private func play(_ data: Data?) {
        guard let data else { return }; app.player.pause(); player?.stop()
        do { player = try AVAudioPlayer(data: data); player?.play() } catch { message = error.localizedDescription }
    }
    private func transcribe() {
        guard app.projectIdentity == project.id, let cli = app.cli, let channel = channels.first(where: { $0.id == selectedChannel }), let origin = channel.origin, let cost = sttCost, settings.enabled else { message = "Choose a channel with a known start time in the current project."; return }
        working = true; message = nil
        let start = start, duration = duration, settings = settings, language = language, sttModel = sttModel
        request = Task {
            defer { working = false }
            do {
                let pcm = try await AudioClip.pcm(url: channel.url, start: start, duration: duration)
                try Task.checkCancellation()
                let charge = try await AIReviewStore.shared.reserve(project: project.id, amount: cost, limit: settings.monthlyLimit, session: detail.row.id, feature: mode == "Check transcription" ? "Transcription comparison" : "TTS comparison")
                let segments = try await InferenceAudio.transcribe(cli: cli, projectURL: project.url, model: sttModel, language: language, pcm: pcm, lowPriority: settings.lowPriority)
                try await AIReviewStore.shared.settle(charge, cost: cost, estimated: true)
                detail.aiChargeRevision += 1
                comparisons = TranscriptionComparison.aligned(segments: segments, transcript: detail.transcript, origin: origin, clipStart: start, clipDuration: duration, model: sttModel)
                detail.transcriptionComparisons = comparisons
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
                try await AudioAIStore.shared.save(project: project.id, session: detail.row.id, data: encoder.encode(comparisons), name: "transcription-comparison.json")
                if comparisons.isEmpty { message = "The provider returned no final speech in this clip." }
            } catch { message = Task.isCancelled ? "Cancelled. Unreported usage remains reserved." : error.localizedDescription }
        }
    }
    private func decide(_ comparison: TranscriptionComparison, accepted: Bool) {
        guard let index = comparisons.firstIndex(where: { $0.id == comparison.id }), comparisons[index].decision == nil else { return }
        if accepted {
            var flag = Flag(id: comparison.id, start: comparison.date, end: comparison.date.addingTimeInterval(max(1, comparison.duration)),
                            note: "STT comparison: original ‘\(comparison.original)’; \(comparison.model ?? "comparison") ‘\(comparison.alternative)’")
            flag.aiModel = comparison.model
            if !detail.flags.contains(where: { $0.id == flag.id }) { detail.flags.append(flag); detail.saveFlags() }
        }
        comparisons[index].decision = accepted ? "accepted" : "dismissed"
        detail.transcriptionComparisons = comparisons
        let values = comparisons
        Task {
            do {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try await AudioAIStore.shared.save(project: project.id, session: detail.row.id, data: encoder.encode(values), name: "transcription-comparison.json")
            } catch { message = error.localizedDescription }
        }
    }
    private func synthesize(a: Bool) {
        let model = a ? modelA : modelB, voice = a ? voiceA : voiceB
        guard app.projectIdentity == project.id, let cli = app.cli, let cost = ttsCost(model), !disabled(model, voice) else { return }
        working = true; message = nil
        let settings = settings, text = text, language = language
        request = Task {
            defer { working = false }
            do {
                let charge = try await AIReviewStore.shared.reserve(project: project.id, amount: cost, limit: settings.monthlyLimit, session: detail.row.id, feature: mode == "Check transcription" ? "Transcription comparison" : "TTS comparison")
                let wav = try await InferenceAudio.synthesize(cli: cli, projectURL: project.url, model: model, voice: voice, language: language, text: text, lowPriority: settings.lowPriority)
                try await AIReviewStore.shared.settle(charge, cost: cost, estimated: true)
                detail.aiChargeRevision += 1
                if a { sampleA = wav } else { sampleB = wav }
                try await AudioAIStore.shared.save(project: project.id, session: detail.row.id, data: wav, name: a ? "tts-a.wav" : "tts-b.wav")
                var record = TTSSampleRecord(model: model, voice: voice, text: text, language: language, created: .now, estimatedCost: cost)
                record.possibleStatic = try await MediaResources.compute(project: project.id) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                    defer { try? FileManager.default.removeItem(at: file) }
                    try wav.write(to: file)
                    let spectrum = try Spectrogram.compute(file: file)
                    guard let noise = spectrum.noise.first else { return false }
                    let origin = Date(timeIntervalSince1970: 0)
                    let line = TTSLine(start: origin, end: origin.addingTimeInterval(Double(spectrum.frameCount) * spectrum.hop), text: text)
                    return !StaticDetector.find(in: noise, hop: spectrum.hop, origin: origin, lines: [line]).isEmpty
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
                try await AudioAIStore.shared.save(project: project.id, session: detail.row.id, data: encoder.encode(record), name: a ? "tts-a.json" : "tts-b.json")
                if a { recordA = record } else { recordB = record }
            } catch { message = Task.isCancelled ? "Cancelled. Unreported usage remains reserved." : error.localizedDescription }
        }
    }
}

struct ComparisonWords: View {
    let comparison: TranscriptionComparison
    let alternative: Bool
    var body: some View {
        if let words = comparison.words {
            words.reduce(Text("")) { text, word in
                guard let value = alternative ? word.alternative : word.original else { return text }
                return text + Text(value + " ").foregroundColor(word.differs ? .purple : .primary).underline(word.differs)
            }.textSelection(.enabled)
        } else { Text(alternative ? comparison.alternative : comparison.original).textSelection(.enabled) }
    }
}
