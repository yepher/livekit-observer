import Foundation

public struct LiveKitCLIError: LocalizedError, Sendable {
    public enum Kind: Sendable { case signedOut, notReady, observabilityOff, missingCLI, projectNotFound, forbidden, tooOld, busy, timeout, failed }
    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }

    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
}

