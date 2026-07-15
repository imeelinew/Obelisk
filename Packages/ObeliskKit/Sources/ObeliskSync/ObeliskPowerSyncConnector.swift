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
        let mutations = try transaction.crud.map { entry in
            guard
                let metadata = entry.metadata,
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
        do {
            try await auth.upload(mutations)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try await transaction.complete()
    }
}

public enum ObeliskSyncError: LocalizedError {
    case invalidMutationMetadata

    public var errorDescription: String? {
        "A local mutation is missing its idempotency identifier"
    }
}
