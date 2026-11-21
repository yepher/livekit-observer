import Foundation

public struct InferenceModelInfo: Codable, Sendable {
    public let id: String, name: String
    public let eu: Bool, retired: Bool, deprecated: Bool
    public let detail: String
    public func isRetired(at date: Date = .now) -> Bool {
        if retired { return true }
        guard deprecated, let range = detail.range(of: #"retires ([A-Za-z]+ \d{1,2}, \d{4})"#, options: .regularExpression) else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "MMMM d, yyyy"
        return formatter.date(from: String(detail[range]).replacingOccurrences(of: "retires ", with: "")).map { date >= $0 } ?? false
    }

    public init(id: String, name: String, eu: Bool, retired: Bool, deprecated: Bool, detail: String) { self.id = id; self.name = name; self.eu = eu; self.retired = retired; self.deprecated = deprecated; self.detail = detail }
}

public enum InferenceModels {
    public struct Snapshot: Codable { public let source: String, fetched: String, models: [InferenceModelInfo] 
    public init(source: String, fetched: String, models: [InferenceModelInfo]) { self.source = source; self.fetched = fetched; self.models = models }
}
    public static let source = URL(string: "https://docs.livekit.io/agents/models/inference.md")!
    public static func bundled() -> [String: InferenceModelInfo] {
        guard let url = Bundle.module.url(forResource: "inference-models", withExtension: "json"), let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [:] }
        return Dictionary(snapshot.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    public static func parse(_ markdown: String) -> [String: InferenceModelInfo] {
        var values: [String: InferenceModelInfo] = [:]
        for line in markdown.split(separator: "\n") where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4, cells[1].hasPrefix("`"), cells[1].hasSuffix("`"), cells[1].contains("/") else { continue }
            let id = String(cells[1].dropFirst().dropLast())
            guard !id.contains(" "), id.count < 200 else { continue }
            values[id] = InferenceModelInfo(id: id, name: cells[0], eu: cells[3].contains("✓"), retired: cells[2].contains("RETIRED"),
                                           deprecated: cells[2].contains("DEPRECATED"), detail: cells[2].replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: ""))
        }
        return values
    }
    public static func refresh(cache: URL) async -> [String: InferenceModelInfo]? {
        let decoder = JSONDecoder()
        if let date = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < 86400, let data = try? Data(contentsOf: cache), let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            return Dictionary(snapshot.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: source, timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var data = Data()
            for try await byte in bytes { guard data.count < 1_048_576 else { return nil }; data.append(byte) }
            let values = parse(String(decoding: data, as: UTF8.self))
            guard values.count >= 10 else { return nil }
            let snapshot = Snapshot(source: source.absoluteString, fetched: String(Date().ISO8601Format().prefix(10)), models: values.values.sorted { $0.id < $1.id })
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
            return values
        } catch { return nil }
    }
}
