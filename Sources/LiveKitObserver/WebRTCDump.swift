import ObserverCore
import Foundation

/// A browser's WebRTC record, read from either download on chrome://webrtc-internals:
/// the WebRTC internals dump (JSON with per-property time series), or the rtcstats dump
/// (newline-delimited events with whole getStats reports). Both become the same model.
struct WebRTCDump: Sendable {
    struct LogEntry: Identifiable, Sendable {
        let id: Int
        let time: Date?
        let type: String
        let value: String
    }
    /// One property of one stats object, sampled over time.
    struct Series: Sendable {
        var times: [Date]
        var values: [JSONValue]
        var numbers: [(Date, Double)] { zip(times, values).compactMap { time, value in value.double.map { (time, $0) } } }
        var last: JSONValue? { values.last }
    }
    /// A stats object (an RTCStats id) and its properties.
    struct Report: Identifiable, Sendable {
        let id: String
        var type: String
        var properties: [String: Series] = [:]
        func text(_ name: String) -> String? { properties[name]?.last?.string }
        func number(_ name: String) -> Double? { properties[name]?.last?.double }
    }
    struct Connection: Identifiable, Sendable {
        let id: String
        var url = ""
        var configuration = ""
        var log: [LogEntry] = []
        var reports: [String: Report] = [:]
        func reports(_ type: String) -> [Report] { reports.values.filter { $0.type == type }.sorted { $0.id < $1.id } }
    }
    struct MediaRequest: Identifiable, Sendable {
        let id: Int
        let time: Date?
        let origin: String
        let kind: String
        let audio: String, video: String
        let error: String?
    }
    enum Format: String, Sendable { case internals = "WebRTC internals dump", rtcstats = "rtcstats dump" }

    var format = Format.internals
    var connections: [Connection] = []
    var mediaRequests: [MediaRequest] = []
    var userAgent = ""
    var exportedAt: Date?

    enum ParseError: LocalizedError {
        case unrecognized, damagedCompression
        var errorDescription: String? {
            switch self {
            case .unrecognized: "This isn't a WebRTC internals dump or rtcstats dump. In Chrome or Edge, open chrome://webrtc-internals during the call, then use “Create a WebRTC-Internals dump” and choose Download."
            case .damagedCompression: "The file looks gzip-compressed but couldn't be decompressed."
            }
        }
    }

    static func load(_ url: URL) throws -> WebRTCDump {
        try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func parse(_ raw: Data) throws -> WebRTCDump {
        let data = try Gzip.isCompressed(raw) ? Gzip.decompress(raw) : raw
        if data.starts(with: Data("RTCStatsDump".utf8)) { return try rtcstats(data) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = root["PeerConnections"] as? [String: Any] else { throw ParseError.unrecognized }
        var dump = WebRTCDump()
        dump.userAgent = root["UserAgent"] as? String ?? ""
        dump.exportedAt = (root["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        dump.mediaRequests = (root["getUserMedia"] as? [[String: Any]] ?? []).enumerated().map { index, request in
            MediaRequest(id: index, time: time(request["timestamp"] ?? request["time"]), origin: request["origin"] as? String ?? request["url"] as? String ?? "",
                         kind: request["request_type"] as? String ?? "getUserMedia", audio: describe(request["audio"]), video: describe(request["video"]),
                         error: (request["error"] as? String).map { error in [error, request["error_message"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ") })
        }
        dump.connections = connections.keys.sorted().compactMap { id in
            guard let record = connections[id] as? [String: Any] else { return nil }
            var connection = Connection(id: id)
            connection.url = record["url"] as? String ?? ""
            connection.configuration = describe(record["rtcConfiguration"])
            connection.log = (record["updateLog"] as? [[String: Any]] ?? []).enumerated().map { index, entry in
                LogEntry(id: index, time: time(entry["timestamp"] ?? entry["time"]), type: entry["type"] as? String ?? "", value: describe(entry["value"]))
            }
            connection.reports = reports(record["stats"] as? [String: Any] ?? [:])
            return connection
        }
        return dump
    }

    /// Classic dumps key each series "<stats id>-<property>". A "<stats id>-timestamp" series, when present,
    /// gives each sample's exact time; otherwise samples are spread evenly between start and end.
    private static func reports(_ stats: [String: Any]) -> [String: Report] {
        struct Raw { let type: String; let start: Date?; let end: Date?; let values: [Any] }
        var raw: [String: [String: Raw]] = [:]
        for (key, value) in stats {
            guard let series = value as? [String: Any], let dash = key.lastIndex(of: "-") else { continue }
            let id = String(key[..<dash]), property = String(key[key.index(after: dash)...])
            guard !id.isEmpty, !property.isEmpty else { continue }
            let values: [Any]
            if let text = series["values"] as? String { values = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]) ?? [] }
            else { values = series["values"] as? [Any] ?? [] }
            raw[id, default: [:]][property] = Raw(type: series["statsType"] as? String ?? "", start: time(series["startTime"]), end: time(series["endTime"]), values: values)
        }
        var reports: [String: Report] = [:]
        for (id, properties) in raw {
            let stamps = properties["timestamp"].map { $0.values.compactMap { ($0 as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } } }
            var report = Report(id: id, type: properties.values.first { !$0.type.isEmpty }?.type ?? "")
            for (property, series) in properties where property != "timestamp" {
                let count = series.values.count
                guard count > 0 else { continue }
                let times: [Date]
                if let stamps, stamps.count >= count { times = Array(stamps.suffix(count)) }
                else if let start = series.start, let end = series.end, count > 1 {
                    let step = end.timeIntervalSince(start) / Double(count - 1)
                    times = (0..<count).map { start.addingTimeInterval(Double($0) * step) }
                } else { times = Array(repeating: series.end ?? series.start ?? .distantPast, count: count) }
                report.properties[property] = Series(times: times, values: series.values.map(JSONValue.init(any:)))
            }
            reports[id] = report
        }
        return reports
    }

    /// rtcstats dumps: "RTCStatsDump", a format line, then one JSON array per line:
    /// [event, connection id, value, ..., milliseconds since the previous event].
    private static func rtcstats(_ data: Data) throws -> WebRTCDump {
        var dump = WebRTCDump(format: .rtcstats)
        var connections: [String: Connection] = [:]
        var order: [String] = []
        var clock = 0.0
        var lines = 0
        for line in data.split(separator: UInt8(ascii: "\n")).dropFirst() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [Any], event.count >= 3,
                  let name = event[0] as? String else { continue }
            if let delta = event.last as? Double, event.count >= 4 { clock += delta }
            let date = clock > 0 ? Date(timeIntervalSince1970: clock / 1000) : nil
            let id = event[1] as? String ?? ""
            let value = event[2]
            lines += 1
            // Device requests carry their own "<rid>-0" id; they aren't peer connections.
            if name.hasPrefix("navigator.mediaDevices.") {
                let kind = String(name.dropFirst("navigator.mediaDevices.".count))
                if kind.hasSuffix("OnFailure") {
                    let details = value as? [String: Any] ?? [:]
                    let error = [details["error"] as? String, details["error_message"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                    dump.mediaRequests.append(MediaRequest(id: dump.mediaRequests.count, time: date, origin: "", kind: String(kind.dropLast("OnFailure".count)),
                                                           audio: "", video: "", error: error.isEmpty ? describe(value) : error))
                } else if !kind.hasSuffix("OnSuccess") {
                    let constraints = value as? [String: Any] ?? [:]
                    dump.mediaRequests.append(MediaRequest(id: dump.mediaRequests.count, time: date, origin: event.count >= 6 ? describe(event[4]) : "", kind: kind,
                                                           audio: describe(constraints["audio"]), video: describe(constraints["video"]), error: nil))
                }
                continue
            }
            if id.isEmpty {
                if name == "create", let details = value as? [String: Any], let agent = details["userAgent"] as? String { dump.userAgent = agent }
                else if name == "userAgent", let agent = value as? String { dump.userAgent = agent }
                continue
            }
            if connections[id] == nil { connections[id] = Connection(id: id); order.append(id) }
            switch name {
            case "getStats", "getstats":
                guard let report = value as? [String: Any] else { continue }
                for (statsID, entry) in report {
                    guard let stats = entry as? [String: Any] else { continue }
                    let time = (stats["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? date ?? .distantPast
                    var current = connections[id]!.reports[statsID] ?? Report(id: statsID, type: stats["type"] as? String ?? "")
                    for (property, sample) in stats where property != "timestamp" && property != "id" && property != "type" {
                        current.properties[property, default: Series(times: [], values: [])].times.append(time)
                        current.properties[property]!.values.append(JSONValue(any: sample))
                    }
                    connections[id]!.reports[statsID] = current
                }
            case "create":
                // ["create", id, configuration, page URL, delta]
                connections[id]!.configuration = describe(value)
                if event.count >= 5 { connections[id]!.url = describe(event[3]) }
            case "constraints":
                continue
            case "url", "location":
                connections[id]!.url = describe(value)
            default:
                let log = connections[id]!.log
                connections[id]!.log.append(LogEntry(id: log.count, time: date, type: name, value: describe(value)))
            }
        }
        guard lines > 0 else { throw ParseError.unrecognized }
        dump.connections = order.compactMap { connections[$0] }
        return dump
    }

    /// Times appear as epoch milliseconds, ISO 8601 strings, or (older dumps) locale strings.
    static func time(_ value: Any?) -> Date? {
        switch value {
        case let number as Double where number > 1e11: return Date(timeIntervalSince1970: number / 1000)
        case let number as Double where number > 1e8: return Date(timeIntervalSince1970: number)
        case let text as String:
            if let number = Double(text) { return time(number) }
            if let date = ISO8601DateFormatter.fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            for format in ["M/d/yyyy, h:mm:ss a", "M/d/yyyy, H:mm:ss", "d/M/yyyy, HH:mm:ss"] {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        default: return nil
        }
    }

    static func describe(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default:
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return String(describing: value ?? "") }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Chrome compresses downloads with gzip when "Compress result" is checked.
enum Gzip {
    static func isCompressed(_ data: Data) -> Bool { data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b }

    /// Skips the gzip header (RFC 1952) and inflates the raw DEFLATE stream with Foundation's zlib codec.
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[2] == 8 else { throw WebRTCDump.ParseError.damagedCompression }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { guard offset + 2 <= bytes.count else { throw WebRTCDump.ParseError.damagedCompression }; offset += 2 + Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        if flags & 0x08 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x10 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw WebRTCDump.ParseError.damagedCompression }
        let body = Data(bytes[offset..<(bytes.count - 8)])
        do { return try (body as NSData).decompressed(using: .zlib) as Data }
        catch { throw WebRTCDump.ParseError.damagedCompression }
    }
}
