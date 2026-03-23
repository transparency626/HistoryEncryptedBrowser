import Foundation

/// 与 `background.js` 加密前 `payload` 字段一致。
struct VaultPayload: Codable, Equatable, Sendable {
    var url: String
    var title: String
    var favIconUrl: String
    var time: Int64
    var tabId: Int
    var actions: [VaultAction]
}

struct VaultAction: Codable, Equatable, Sendable {
    var type: String
    var desc: String
}

/// 磁盘上的保险库元数据（对应扩展 `setVaultMeta`；私钥为密码加密后的 PKCS#8 DER）。
struct VaultMetaFile: Codable, Equatable, Sendable {
    var salt: String
    /// RSA 公钥 SPKI DER 的 Base64（扩展用 JWK；本机自洽即可）。
    var publicKeySPKI: String
    var encryptedPrivateKey: VaultEncryptedBlob
}

struct VaultEncryptedBlob: Codable, Equatable, Sendable {
    var iv: String
    var ciphertext: String
}

/// 单条保险库记录（对应 `addVaultRecord`）。
struct VaultRecordRow: Codable, Equatable, Identifiable {
    var id: Int64
    var time: Int64
    var iv: String
    var ciphertext: String
    var encryptedAesKey: String
}

struct VaultRecordEncoded: Equatable, Sendable {
    var iv: Data
    var ciphertext: Data
    var encryptedAesKey: Data
}

struct VaultListItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var payload: VaultPayload
}

struct VaultSetupValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
