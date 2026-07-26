import Foundation
import ObeliskCore

/// Wire types for the state-based sync protocol. Column names match SQLite
/// and D1; timestamps are ISO-8601 strings with fractional seconds.

public enum SyncJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported sync JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct SyncPushRow: Encodable, Sendable {
    public var table: String
    public var id: String
    public var values: [String: SyncJSONValue]
    public var fieldVersions: [String: LogicalTimestamp]?

    public init(
        table: String,
        id: String,
        values: [String: SyncJSONValue],
        fieldVersions: [String: LogicalTimestamp]? = nil
    ) {
        self.table = table
        self.id = id
        self.values = values
        self.fieldVersions = fieldVersions
    }
}

public struct SyncRemoteVersionedRow: Decodable, Sendable {
    public var id: String
    public var values: [String: SyncJSONValue]
    public var fieldVersions: [String: LogicalTimestamp]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var id: String?
        var values: [String: SyncJSONValue] = [:]
        var versions: [String: LogicalTimestamp]?
        for key in container.allKeys {
            switch key.stringValue {
            case "id":
                id = try container.decode(String.self, forKey: key)
            case "fieldVersions":
                versions = try container.decode([String: LogicalTimestamp].self, forKey: key)
            case "created_at", "updated_at":
                values[key.stringValue] = try container.decode(SyncJSONValue.self, forKey: key)
            default:
                values[key.stringValue] = try container.decode(SyncJSONValue.self, forKey: key)
            }
        }
        guard let id, let versions else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Remote row is missing id or fieldVersions"
            ))
        }
        self.id = id.lowercased()
        self.values = values
        self.fieldVersions = versions
    }
}

public struct SyncRemoteUsageEvent: Decodable, Sendable {
    public var id: String
    public var bookmarkID: String
    public var deviceID: String
    public var occurredAt: String
    public var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case bookmarkID = "bookmark_id"
        case deviceID = "device_id"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
    }
}

public struct SyncRemoteBrowserHistoryEvent: Decodable, Sendable {
    public var id: String
    public var sourceDeviceID: String
    public var browser: String
    public var profileName: String
    public var title: String
    public var url: String
    public var visitedAt: String
    public var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceDeviceID = "source_device_id"
        case browser
        case profileName = "profile_name"
        case title
        case url
        case visitedAt = "visited_at"
        case createdAt = "created_at"
    }
}

public struct SyncChangesPage: Decodable, Sendable {
    public var cursor: Int64
    public var hasMore: Bool
    public var collections: [SyncRemoteVersionedRow]
    public var bookmarks: [SyncRemoteVersionedRow]
    public var usageEvents: [SyncRemoteUsageEvent]
    public var browserHistoryEvents: [SyncRemoteBrowserHistoryEvent]
    public var browserHistoryDeletions: [String]
    public var browserHistorySettings: [SyncRemoteVersionedRow]
}

public struct SyncOutboxEntry: Equatable, Sendable {
    public var tableName: String
    public var rowID: String
    public var queuedAt: String
    public var attempts: Int

    public init(tableName: String, rowID: String, queuedAt: String, attempts: Int) {
        self.tableName = tableName
        self.rowID = rowID
        self.queuedAt = queuedAt
        self.attempts = attempts
    }
}

/// Full local state of one browser-history row owned by this device, sent to
/// the device-scoped reconcile endpoint.
public struct SyncHistoryRecord: Encodable, Sendable {
    public var id: String
    public var browser: String
    public var profileName: String
    public var title: String
    public var url: String
    public var visitedAt: String
    public var createdAt: String
}
