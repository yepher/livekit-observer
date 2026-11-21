import AVFoundation
import CryptoKit

public struct TranscriptionComparison: Codable, Identifiable {
    public var id = UUID()
    public let date: Date, duration: Double, original: String, alternative: String
    public var model: String?
    public var words: [AlignedWord]?
    public var confidence: Double?
    public var timing: String?
    public var decision: String?
    public var differs: Bool { !original.isEmpty && Self.normalized(original) != Self.normalized(alternative) }
    public static func normalized(_ text: String) -> String { text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") }

    public init(id: UUID = UUID(), date: Date, duration: Double, original: String, alternative: String, model: String? = nil, words: [AlignedWord]? = nil, confidence: Double? = nil, timing: String? = nil, decision: String? = nil) { self.id = id; self.date = date; self.duration = duration; self.original = original; self.alternative = alternative; self.model = model; self.words = words; self.confidence = confidence; self.timing = timing; self.decision = decision }
}

public actor AudioAIStore {
    public static let shared = AudioAIStore()
    private let root: URL
    private let allowedNames: Set<String> = ["transcription-comparison.json", "tts-a.wav", "tts-b.wav", "tts-a.json", "tts-b.json", "scenario-draft.json"]
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveKit Observer/AI/Audio")) { self.root = root }
    private func directory(project: String, session: String) -> URL {
        let key = SHA256.hash(data: Data((project + ":" + session).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key)
    }
    public func save(project: String, session: String, data: Data, name: String) throws {
        guard allowedNames.contains(name), data.count <= 6_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let directory = directory(project: project, session: session)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    public func load(project: String, session: String, name: String) throws -> Data? {
        guard allowedNames.contains(name) else { return nil }
        let url = directory(project: project, session: session).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 6_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        return try Data(contentsOf: url)
    }
    public func export(project: String, session: String, to directory: URL) throws {
        for name in allowedNames {
            guard let data = try load(project: project, session: session, name: name) else { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}

public struct TTSSampleRecord: Codable {
    public let model: String, voice: String, text: String, language: String
    public let created: Date, estimatedCost: Double
    public var possibleStatic: Bool?

    public init(model: String, voice: String, text: String, language: String, created: Date, estimatedCost: Double, possibleStatic: Bool? = nil) { self.model = model; self.voice = voice; self.text = text; self.language = language; self.created = created; self.estimatedCost = estimatedCost; self.possibleStatic = possibleStatic }
}

