import Foundation

public enum VaultEntryKind: String, Codable, Sendable {
    case json
    case binary
}

public struct VaultManifestEntry: Codable, Equatable, Sendable {
    public var blobId: UUID
    public var kind: VaultEntryKind
    public var updatedAt: Date

    public init(blobId: UUID, kind: VaultEntryKind, updatedAt: Date = Date()) {
        self.blobId = blobId
        self.kind = kind
        self.updatedAt = updatedAt
    }
}

public struct VaultManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var entries: [String: VaultManifestEntry]

    public init(version: Int = currentVersion, entries: [String: VaultManifestEntry] = [:]) {
        self.version = version
        self.entries = entries
    }

    public func entry(for logicalName: String) -> VaultManifestEntry? {
        entries[logicalName]
    }

    public mutating func setEntry(_ entry: VaultManifestEntry, for logicalName: String) {
        entries[logicalName] = entry
    }

    public mutating func removeEntry(for logicalName: String) {
        entries.removeValue(forKey: logicalName)
    }
}
