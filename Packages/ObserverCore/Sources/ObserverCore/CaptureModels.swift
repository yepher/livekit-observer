import CryptoKit
import Foundation

public struct CaptureSession: Codable, Hashable, Sendable {
    // Phase 1 settings use the configured CLI name. Keep this stable until ProjectRef migration.
    public let projectKey: String
    public let projectName: String
    public let sessionID: String
    public let roomName: String
    public let startedAt: Date?
    public let endedAt: Date?

    public init(projectKey: String, projectName: String, sessionID: String, roomName: String, startedAt: Date? = nil, endedAt: Date? = nil) { self.projectKey = projectKey; self.projectName = projectName; self.sessionID = sessionID; self.roomName = roomName; self.startedAt = startedAt; self.endedAt = endedAt }
}

public struct PacketCapture: Codable, Identifiable, Hashable, Sendable {
    public enum Format: String, Codable, Sendable { case pcap, pcapng }
    public let id: UUID
    public let session: CaptureSession
    public let originalName: String
    public let format: Format
    public let byteCount: Int64
    public let sha256: String
    public let importedAt: Date
    public let source: String
    public var filename: String { "capture." + format.rawValue }

    public init(id: UUID, session: CaptureSession, originalName: String, format: Format, byteCount: Int64, sha256: String, importedAt: Date, source: String) { self.id = id; self.session = session; self.originalName = originalName; self.format = format; self.byteCount = byteCount; self.sha256 = sha256; self.importedAt = importedAt; self.source = source }
}

