import CryptoKit
import Foundation

public enum VaultBlobCodecError: LocalizedError {
    case invalidEnvelope
    case decryptFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "本地加密文件格式无效"
        case .decryptFailed:
            return "无法解密本地 Vault 数据"
        }
    }
}

public struct VaultBlobCodec {
    public static let format = "obelisk.vault-blob.v2"
    public static let algorithm = "AES.GCM"

    private struct Envelope: Codable {
        let format: String
        let algorithm: String
        let blobId: String
        let payload: String
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func seal(
        _ plaintext: Data,
        logicalName: String,
        blobId: UUID,
        using key: SymmetricKey
    ) throws -> Data {
        let aad = authenticatorData(logicalName: logicalName, blobId: blobId)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealedBox.combined else {
            throw VaultBlobCodecError.invalidEnvelope
        }
        let envelope = Envelope(
            format: Self.format,
            algorithm: Self.algorithm,
            blobId: blobId.uuidString.lowercased(),
            payload: combined.base64EncodedString()
        )
        return try encoder.encode(envelope)
    }

    public func open(
        _ data: Data,
        logicalName: String,
        blobId: UUID,
        using key: SymmetricKey
    ) throws -> Data {
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.format == Self.format,
              envelope.algorithm == Self.algorithm,
              envelope.blobId == blobId.uuidString.lowercased(),
              let combined = Data(base64Encoded: envelope.payload) else {
            throw VaultBlobCodecError.invalidEnvelope
        }
        let aad = authenticatorData(logicalName: logicalName, blobId: blobId)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw VaultBlobCodecError.decryptFailed
        }
    }

    public func canOpen(
        _ data: Data,
        logicalName: String,
        blobId: UUID,
        using keyData: Data
    ) -> Bool {
        guard keyData.count == 32 else { return false }
        let key = SymmetricKey(data: keyData)
        return (try? open(data, logicalName: logicalName, blobId: blobId, using: key)) != nil
    }

    public func isEncryptedBlob(_ data: Data) -> Bool {
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return false }
        return envelope.format == Self.format && envelope.algorithm == Self.algorithm
    }

    private func authenticatorData(logicalName: String, blobId: UUID) -> Data {
        Data("\(Self.format)|\(logicalName)|\(blobId.uuidString.lowercased())".utf8)
    }
}
