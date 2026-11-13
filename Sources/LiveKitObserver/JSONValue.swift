import Foundation

/// Loosely typed JSON. `lk analytics --json` is in beta, so models read fields
/// defensively from this instead of failing on an unexpected shape.
enum JSONValue: Hashable, Sendable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any: Any) {
        switch any {
        case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): self = .bool(v.boolValue)
        case let v as NSNumber: self = .number(v.doubleValue)
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map(JSONValue.init(any:)))
        case let v as [String: Any]: self = .object(v.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    /// Numbers, including the int64 values the API encodes as strings ("12").
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var date: Date? { string.flatMap(ISODate.parse) }

    /// The list in a response: a bare array, `items`, or the first array of objects found.
    var items: [JSONValue] {
        if let a = array { return a }
        if let a = self["items"]?.array { return a }
        guard let o = object else { return [] }
        for key in o.keys.sorted() {
            if let a = o[key]?.array, a.contains(where: { $0.object != nil }) { return a }
        }
        return []
    }

    var description: String {
        switch self {
        case .string(let s): return s
        case .number, .bool: return string ?? ""
        case .null: return "null"
        case .array, .object:
            let data = (try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    var foundation: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }
}

enum ISODate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func parse(_ text: String) -> Date? {
        if let d = try? fractional.parse(text) { return d }
        if let d = try? whole.parse(text) { return d }
        // Nanosecond precision ("…:58.212345678Z") is more than the format style accepts.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let trimmed = String(text[..<dot]) + String(text[dot..<zone].prefix(4)) + String(text[zone...])
            return try? fractional.parse(trimmed)
        }
        return nil
    }
}
