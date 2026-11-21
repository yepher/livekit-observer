import AVFoundation
import Foundation

public struct STTSegment: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let text: String, start: Double, duration: Double
    public let confidence: Double?
    public let words: [Word]?
    public struct Word: Codable, Sendable {
        public let text: String, start: Double, end: Double
        public let confidence: Double?
        public init?(json: JSONValue) {
            guard let text = json["word"]?.string, let start = json["start"]?.double, let end = json["end"]?.double,
                  !text.isEmpty, start.isFinite, end.isFinite, start >= 0, end >= start, end <= 120.25 else { return nil }
            self.text = text; self.start = start; self.end = end
            confidence = json["confidence"]?.double.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        }
    }
    public init?(json: JSONValue) {
        guard let text = json["transcript"]?.string, !text.isEmpty,
              let start = json["start"]?.double, let duration = json["duration"]?.double,
              start.isFinite, duration.isFinite, start >= 0, duration >= 0 else { return nil }
        self.text = text; self.start = start; self.duration = duration
        confidence = json["confidence"]?.double.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        words = json["words"]?.array?.prefix(2048).compactMap { Word(json: $0) }
    }
}

public enum InferenceAudio {
    public static let budget = WorkScheduler(limit: 1, backgroundLimit: 1, queueLimit: 4)
    public static func send(_ object: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public static func receive(_ socket: URLSessionWebSocketTask) async throws -> JSONValue {
        let message = try await socket.receive()
        let data: Data
        switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: throw URLError(.cannotParseResponse) }
        let json = try JSONValue.parse(data)
        if json.text("type") == "error" { throw InferenceClient.Failure(message: "The audio inference provider rejected the request. Check the selected model, language and voice.") }
        return json
    }

    public static func transcribe(cli: any InferenceTokenSource, projectURL: String, model: String, language: String, pcm: Data, lowPriority: Bool) async throws -> [STTSegment] {
        // Restrict this 16 kHz path to verified models. Other families can require
        // different rates or client endpointing, so they must not silently use this path.
        guard ["deepgram/nova-3", "cartesia/ink-whisper"].contains(model), !pcm.isEmpty, pcm.count <= 16000 * 2 * 120 else { throw InferenceClient.Failure(message: "Choose a supported STT model and a nonempty clip of at most two minutes.") }
        return try await budget.perform(project: cli.project ?? "", priority: .interactive) {
            let socket = try await InferenceClient.shared.audioSocket(cli: cli, projectURL: projectURL, kind: "stt", model: model, lowPriority: lowPriority)
            let deadline = Task { try? await Task.sleep(for: .seconds(180)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
            defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
            return try await withTaskCancellationHandler {
                try await send(["type": "session.create", "model": model, "settings": ["sample_rate": "16000", "encoding": "pcm_s16le", "language": language]], to: socket)
                var ready = false
                for _ in 0..<20 { let event = try await receive(socket); if event.text("type") == "session.created" { ready = true; break } }
                guard ready else { throw InferenceClient.Failure(message: "The STT session did not become ready.") }
                let sender = Task {
                    do {
                    for offset in stride(from: 0, to: pcm.count, by: 3200) {
                        try Task.checkCancellation()
                        try await send(["type": "input_audio", "audio": pcm.subdata(in: offset..<min(offset + 3200, pcm.count)).base64EncodedString()], to: socket)
                    }
                    try await send(["type": "session.finalize"], to: socket)
                    } catch {
                        socket.cancel(with: .goingAway, reason: nil)
                        throw error
                    }
                }
                defer { sender.cancel() }
                var segments: [STTSegment] = []
                for _ in 0..<10000 {
                    let event = try await receive(socket)
                    if event.text("type") == "final_transcript", let segment = STTSegment(json: event) {
                        guard segment.start + segment.duration <= Double(pcm.count) / 32000 + 0.25 else { throw InferenceClient.Failure(message: "The provider returned timing outside the selected audio clip.") }
                        segments.append(segment)
                    }
                    if ["session.finalized", "session.closed"].contains(event.text("type")) {
                        try await sender.value
                        return segments
                    }
                }
                throw InferenceClient.Failure(message: "The STT response exceeded its event limit.")
            } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    public static func synthesize(cli: any InferenceTokenSource, projectURL: String, model: String, voice: String, language: String, text: String, lowPriority: Bool) async throws -> Data {
        guard !voice.isEmpty, !text.isEmpty, text.count <= 3000 else { throw InferenceClient.Failure(message: "Choose a voice and at most 3,000 characters of text.") }
        return try await budget.perform(project: cli.project ?? "", priority: .interactive) {
            let socket = try await InferenceClient.shared.audioSocket(cli: cli, projectURL: projectURL, kind: "tts", model: model, lowPriority: lowPriority)
            let deadline = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
            defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
            return try await withTaskCancellationHandler {
                try await send(["type": "session.create", "model": model, "voice": voice, "language": language, "sample_rate": "24000", "encoding": "pcm_s16le", "extra": [String: String](), "fallback": ["models": [String](), "disable_system_default_fallback": true]], to: socket)
                var ready = false
                for _ in 0..<20 { if try await receive(socket).text("type") == "session.created" { ready = true; break } }
                guard ready else { throw InferenceClient.Failure(message: "The TTS session did not become ready.") }
                try await send(["type": "input_transcript", "transcript": text, "generation_config": ["model": model, "voice": voice, "language": language], "extra": [String: String]()], to: socket)
                try await send(["type": "session.flush"], to: socket)
                var pcm = Data()
                for _ in 0..<10000 {
                    let event = try await receive(socket)
                    if event.text("type") == "output_audio", let encoded = event["audio"]?.string, let bytes = Data(base64Encoded: encoded) {
                        guard pcm.count + bytes.count <= 24_000 * 2 * 120 else { throw InferenceClient.Failure(message: "Generated audio exceeded two minutes.") }
                        pcm.append(bytes)
                    }
                    if event.text("type") == "done" { guard !pcm.isEmpty else { throw InferenceClient.Failure(message: "The provider returned no audio.") }; return AudioClip.wav(pcm, sampleRate: 24000) }
                }
                throw InferenceClient.Failure(message: "The TTS response exceeded its event limit.")
            } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
        }
    }
}

public enum AudioClip {
    public static func pcm(url: URL, start: Double, duration: Double) async throws -> Data {
        return try await MediaResources.compute(project: "audio-review") {
            guard start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 120 else { throw InferenceClient.Failure(message: "Choose a clip between 0 and 120 seconds.") }
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.channelCount == 1 else { throw InferenceClient.Failure(message: "Select one isolated channel first.") }
            guard start < Double(file.length) / file.processingFormat.sampleRate else { throw InferenceClient.Failure(message: "The selected clip starts after the recording ends.") }
            let frame = AVAudioFramePosition(start * file.processingFormat.sampleRate)
            guard frame < file.length else { throw InferenceClient.Failure(message: "The selected clip starts after the recording ends.") }
            file.framePosition = frame
            var remaining = min(file.length - frame, AVAudioFramePosition(duration * file.processingFormat.sampleRate))
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw URLError(.cannotDecodeContentData) }
            var data = Data(), readError: Error?
            while true {
                try Task.checkCancellation()
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    do {
                        try file.read(into: input, frameCount: AVAudioFrameCount(min(4096, remaining)))
                        remaining -= AVAudioFramePosition(input.frameLength)
                        state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                        return input.frameLength > 0 ? input : nil
                    } catch { readError = error; state.pointee = .endOfStream; return nil }
                }
                if let readError { throw readError }; if let error { throw error }
                if let samples = output.int16ChannelData?[0], output.frameLength > 0 { data.append(Data(bytes: samples, count: Int(output.frameLength) * 2)) }
                guard data.count <= 16000 * 2 * 120 else { throw InferenceClient.Failure(message: "Converted audio exceeded its size limit.") }
                if status == .endOfStream || (remaining == 0 && output.frameLength == 0) { break }
                if status == .error { throw URLError(.cannotDecodeContentData) }
            }
            return data
        }
    }
    public static func wav(_ pcm: Data, sampleRate: UInt32) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        append(UInt32(pcm.count + 36)); result.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16)); result.append(Data("data".utf8)); append(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
