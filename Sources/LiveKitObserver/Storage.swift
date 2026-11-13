import CryptoKit
import Foundation
import Security

/// Where a project's egress recordings are stored: any S3-compatible service (AWS S3, DigitalOcean Spaces,
/// Cloudflare R2, MinIO, …). The app only lists and downloads.
struct StorageSettings: Codable, Equatable, Sendable {
    /// The service URL, such as `https://nyc3.digitaloceanspaces.com`. Blank means AWS S3 in `region`.
    var endpoint = ""
    var region = ""
    var bucket = ""
    /// The folder egress writes to (its `filepath` prefix), or blank for the whole bucket.
    var prefix = ""
    var accessKey = ""
    /// Whether this project's egress puts the user on the left channel and the agent on the right
    /// (audio routes by participant kind). Otherwise channels are labeled only left and right.
    var userLeftAgentRight = false

    var isEmpty: Bool { bucket.isEmpty && accessKey.isEmpty && endpoint.isEmpty }

    /// Reads S3 settings from an env file: the `EGRESS_S3_*` names, or the standard `AWS_*` ones.
    /// Returns the settings and the secret, which belongs in the Keychain rather than in these settings.
    static func importing(envFile: URL) throws -> (settings: StorageSettings, secret: String) {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else {
            throw StorageError.message("Cannot read \(envFile.path).")
        }
        let env = parseEnv(text)
        func first(_ keys: String...) -> String { keys.lazy.compactMap { env[$0] }.first { !$0.isEmpty } ?? "" }
        var settings = StorageSettings()
        settings.endpoint = first("EGRESS_S3_ENDPOINT", "S3_ENDPOINT", "AWS_ENDPOINT_URL_S3", "AWS_ENDPOINT_URL")
        settings.region = first("EGRESS_S3_REGION", "S3_REGION", "AWS_REGION", "AWS_DEFAULT_REGION")
        settings.bucket = first("EGRESS_S3_BUCKET", "S3_BUCKET", "AWS_S3_BUCKET", "AWS_BUCKET")
        settings.prefix = first("EGRESS_PREFIX", "EGRESS_S3_PREFIX", "S3_PREFIX")
        settings.accessKey = first("EGRESS_S3_ACCESS_KEY", "S3_ACCESS_KEY", "AWS_ACCESS_KEY_ID")
        let secret = first("EGRESS_S3_SECRET", "S3_SECRET", "S3_SECRET_KEY", "AWS_SECRET_ACCESS_KEY")
        guard !settings.bucket.isEmpty || !settings.accessKey.isEmpty else {
            throw StorageError.message("\(envFile.lastPathComponent) has no S3 bucket or access key (EGRESS_S3_* or AWS_* settings).")
        }
        return (settings, secret)
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst(7)) }
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            env[String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)] = value
        }
        return env
    }
}

/// Everything needed to sign requests, resolved from the settings and the Keychain secret.
struct StorageConfig: Sendable {
    let bucket: String
    let region: String
    let endpoint: URL
    let accessKey: String
    let secret: String
    /// The prefix to list, ending in "/", or "" for the whole bucket.
    let prefix: String
    /// `https://endpoint/bucket/key` rather than `https://bucket.endpoint/key`. AWS prefers the latter.
    let pathStyle: Bool

    init(bucket: String, region: String, endpoint: URL, accessKey: String, secret: String, prefix: String, pathStyle: Bool = true) {
        self.bucket = bucket; self.region = region; self.endpoint = endpoint
        self.accessKey = accessKey; self.secret = secret; self.prefix = prefix; self.pathStyle = pathStyle
    }

    init(settings: StorageSettings, secret: String) throws {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bucket = trim(settings.bucket), key = trim(settings.accessKey)
        guard !bucket.isEmpty else { throw StorageError.message("Enter the bucket that egress writes to.") }
        guard !key.isEmpty, !secret.isEmpty else { throw StorageError.message("Enter the storage access key and secret.") }
        var region = trim(settings.region)
        var text = trim(settings.endpoint)
        if text.isEmpty {
            guard !region.isEmpty else { throw StorageError.message("Enter the storage endpoint, or the AWS region for Amazon S3.") }
            text = "https://s3.\(region).amazonaws.com"
        }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
            throw StorageError.message("The storage endpoint is not a URL.")
        }
        // Signing needs a region; services without regions (R2, MinIO) accept "auto" or "us-east-1".
        if region.isEmpty { region = Self.region(fromHost: host) ?? "us-east-1" }
        let prefix = trim(settings.prefix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(bucket: bucket, region: region, endpoint: url, accessKey: key, secret: secret,
                  prefix: prefix.isEmpty ? "" : prefix + "/", pathStyle: !host.hasSuffix("amazonaws.com") || bucket.contains("."))
    }

    /// The region in a host such as `nyc3.digitaloceanspaces.com` or `s3.us-west-2.amazonaws.com`.
    static func region(fromHost host: String) -> String? {
        let parts = host.split(separator: ".").map(String.init)
        if host.hasSuffix("digitaloceanspaces.com"), parts.count >= 3 { return parts[parts.count - 3] }
        if host.hasSuffix("amazonaws.com"), let i = parts.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }), i + 1 < parts.count - 2 {
            return parts[i + 1]
        }
        if host.hasSuffix("r2.cloudflarestorage.com") { return "auto" }
        return nil
    }
}

enum StorageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

struct StorageObject: Hashable, Sendable {
    let key: String
    let size: Int64
}

struct StorageClient: Sendable {
    let config: StorageConfig

    func list(prefix: String) async throws -> [StorageObject] {
        var objects: [StorageObject] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: prefix)]
            if let token { query.append(URLQueryItem(name: "continuation-token", value: token)) }
            let data = try await get(path: bucketPath(""), query: query)
            let page = ListObjectsParser.parse(data)
            objects += page.objects
            token = page.nextToken
        } while token != nil
        return objects
    }

    /// Checks the credentials and bucket with a one-object listing; returns how many objects it saw.
    func probe() async throws -> Int {
        let query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "max-keys", value: "1"),
                     URLQueryItem(name: "prefix", value: config.prefix)]
        return ListObjectsParser.parse(try await get(path: bucketPath(""), query: query)).objects.count
    }

    func object(_ key: String) async throws -> Data {
        try await get(path: bucketPath(key), query: [])
    }

    /// The request path for a key: `/bucket/key` path-style, or `/key` on the bucket's own host.
    private func bucketPath(_ key: String) -> String {
        config.pathStyle ? "/\(config.bucket)/\(key)" : "/\(key)"
    }

    /// Downloads to a file, for large recordings.
    func download(_ key: String, to destination: URL) async throws {
        let request = signedRequest(path: bucketPath(key), query: [])
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try Self.check(response, data: nil)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: signedRequest(path: path, query: query))
        try Self.check(response, data: data)
        return data
    }

    private static func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw StorageError.message("The storage service did not respond.") }
        guard http.statusCode == 200 else {
            let code = data.flatMap { String(decoding: $0, as: UTF8.self).components(separatedBy: "<Code>").dropFirst().first?.components(separatedBy: "<").first } ?? ""
            throw StorageError.message("Storage returned HTTP \(http.statusCode)\(code.isEmpty ? "" : " (\(code))").")
        }
    }

    private func signedRequest(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        if !config.pathStyle, let host = components.host { components.host = "\(config.bucket).\(host)" }
        components.percentEncodedPath = SigV4.encodePath(path)
        components.percentEncodedQuery = query.isEmpty ? nil : SigV4.canonicalQuery(query)
        let url = components.url!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let headers = SigV4.sign(
            method: "GET", url: url, headers: [:], payloadHash: SigV4.emptyPayloadHash,
            accessKey: config.accessKey, secret: config.secret, region: config.region, date: Date()
        )
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

/// AWS Signature Version 4 for S3-compatible GET requests.
enum SigV4 {
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }
    static func encodePath(_ path: String) -> String { path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/") }
    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        items.map { (encode($0.name), encode($0.value ?? "")) }.sorted { $0 < $1 }.map { "\($0)=\($1)" }.joined(separator: "&")
    }

    /// Returns every header to send, lowercased, including `authorization`.
    static func sign(method: String, url: URL, headers: [String: String], payloadHash: String,
                     accessKey: String, secret: String, region: String, service: String = "s3", date: Date) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))

        var all = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var host = components.host ?? ""
        if let port = components.port { host += ":\(port)" }
        all["host"] = host
        all["x-amz-date"] = amzDate
        all["x-amz-content-sha256"] = payloadHash

        let names = all.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(all[$0]!)\n" }.joined()
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = (components.percentEncodedQueryItems ?? []).map {
            URLQueryItem(name: $0.name.removingPercentEncoding ?? $0.name, value: $0.value?.removingPercentEncoding)
        }
        let canonicalRequest = [method, path, canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, service, "aws4_request"] { key = SymmetricKey(data: hmac(key, part)) }
        let signature = hex(hmac(key, stringToSign))
        all["authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope),SignedHeaders=\(signedHeaders),Signature=\(signature)"
        return all
    }

    private static func hmac(_ key: SymmetricKey, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }
    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal ListObjectsV2 XML reader.
final class ListObjectsParser: NSObject, XMLParserDelegate {
    private(set) var objects: [StorageObject] = []
    private(set) var nextToken: String?
    private var text = ""
    private var key = ""
    private var size: Int64 = 0
    private var truncated = false

    static func parse(_ data: Data) -> (objects: [StorageObject], nextToken: String?) {
        let delegate = ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.objects, delegate.truncated ? delegate.nextToken : nil)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "Contents" { key = ""; size = 0 }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "Key": key = text
        case "Size": size = Int64(text) ?? 0
        case "Contents": objects.append(StorageObject(key: key, size: size))
        case "NextContinuationToken": nextToken = text
        case "IsTruncated": truncated = text == "true"
        default: break
        }
    }
}

/// Storage secrets live in the login Keychain, one per LiveKit project.
enum Keychain {
    private static let service = "LiveKit Observer storage secret"

    static func secret(for account: String) -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func setSecret(_ secret: String, for account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !secret.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
