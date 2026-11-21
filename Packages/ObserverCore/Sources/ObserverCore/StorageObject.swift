import Foundation

public struct StorageObject: Hashable, Sendable {
    public let key: String
    public let size: Int64

    public init(key: String, size: Int64) { self.key = key; self.size = size }
}

