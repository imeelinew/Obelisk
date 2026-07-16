import Foundation
import PowerSync

struct ObeliskMutationBatch: Encodable {
    var mutations: [ObeliskMutationUpload]
}

struct ObeliskMutationUpload: Encodable {
    var mutationID: UUID
    var table: String
    var rowID: UUID
    var operation: String
    var values: JsonParam

    private enum CodingKeys: String, CodingKey {
        case mutationID = "mutationId"
        case table
        case rowID = "rowId"
        case operation, values
    }
}

public final class ObeliskPowerSyncConnector: PowerSyncBackendConnectorProtocol, Sendable {
    private static let maximumMutationBatchSize = 500

    private let auth: ObeliskAuthClient

    public init(auth: ObeliskAuthClient) {
        self.auth = auth
    }

    public func fetchCredentials() async throws -> PowerSyncCredentials? {
        try await auth.powerSyncCredentials()
    }

    public func uploadData(database: any PowerSyncDatabaseProtocol) async throws {
        guard let transaction = try await database.getNextCrudTransaction() else {
            return
        }
        let mutations = try Self.mutations(from: transaction.crud)
        do {
            for offset in stride(
                from: 0,
                to: mutations.count,
                by: Self.maximumMutationBatchSize
            ) {
                let end = min(offset + Self.maximumMutationBatchSize, mutations.count)
                try await auth.upload(Array(mutations[offset..<end]))
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try await transaction.complete()
    }

    private static func mutations(from entries: [CrudEntry]) throws -> [ObeliskMutationUpload] {
        var mutations: [ObeliskMutationUpload] = []
        mutations.reserveCapacity(entries.count)
        var index = entries.startIndex

        while index < entries.endIndex {
            let entry = entries[index]
            let nextIndex = entries.index(after: index)
            if nextIndex < entries.endIndex,
               isBrowserHistoryDeletionMetadataCarrier(entry, followedBy: entries[nextIndex]) {
                mutations.append(try mutation(from: entries[nextIndex], metadata: entry.metadata))
                index = entries.index(after: nextIndex)
            } else {
                mutations.append(try mutation(from: entry, metadata: entry.metadata))
                index = nextIndex
            }
        }
        return mutations
    }

    private static func isBrowserHistoryDeletionMetadataCarrier(
        _ entry: CrudEntry,
        followedBy deletion: CrudEntry
    ) -> Bool {
        entry.table == "browser_history_events"
            && entry.op == .patch
            && entry.opDataTyped?.isEmpty == true
            && UUID(uuidString: entry.metadata ?? "") != nil
            && deletion.clientId == entry.clientId + 1
            && deletion.transactionId == entry.transactionId
            && deletion.table == entry.table
            && deletion.id == entry.id
            && deletion.op == .delete
            && deletion.metadata == nil
    }

    private static func mutation(
        from entry: CrudEntry,
        metadata: String?
    ) throws -> ObeliskMutationUpload {
        guard
            let metadata,
            let mutationID = UUID(uuidString: metadata),
            let rowID = UUID(uuidString: entry.id)
        else {
            throw ObeliskSyncError.invalidMutationMetadata
        }
        return ObeliskMutationUpload(
            mutationID: mutationID,
            table: entry.table,
            rowID: rowID,
            operation: entry.op.rawValue,
            values: entry.opDataTyped ?? [:]
        )
    }
}

public enum ObeliskSyncError: LocalizedError {
    case invalidMutationMetadata

    public var errorDescription: String? {
        "A local mutation is missing its idempotency identifier"
    }
}
