import Foundation

/// 加密前单条历史记录的业务结构（与扩展 background 里 payload 字段对齐）。
struct VaultPayload: Codable, Equatable, Sendable {
    var url: String
    var title: String
    var favIconUrl: String
    /// 访问时间：毫秒时间戳（与 JS Date 习惯一致）。
    var time: Int64
    /// 标签页 id；本 App 单 WebView，固定 0。
    var tabId: Int
    /// 预留扩展字段（扩展里可能有动作列表）。
    var actions: [VaultAction]
}

/// 单条「动作」描述（结构占位，与扩展一致）。
struct VaultAction: Codable, Equatable, Sendable {
    var type: String
    var desc: String
}

/// 磁盘上的保险库元数据：盐、公钥、密码加密后的私钥。
struct VaultMetaFile: Codable, Equatable, Sendable {
    /// PBKDF2 盐，Base64。
    var salt: String
    /// RSA 公钥 SPKI DER 的 Base64；写记录时只用公钥加密。
    var publicKeySPKI: String
    /// 用「密码派生密钥」AES-GCM 加密后的 PKCS#8 私钥。
    var encryptedPrivateKey: VaultEncryptedBlob
}

/// AES-GCM 密文块：iv + ciphertext（含 tag）均为 Base64 字符串。
struct VaultEncryptedBlob: Codable, Equatable, Sendable {
    var iv: String
    var ciphertext: String
}

/// JSON 数组里的一条加密历史行（磁盘格式）。
struct VaultRecordRow: Codable, Equatable, Identifiable {
    var id: Int64
    var time: Int64
    var iv: String
    var ciphertext: String
    var encryptedAesKey: String
}

/// 内存里解码后的密文三元组（二进制），供解密管线使用。
struct VaultRecordEncoded: Equatable, Sendable {
    var iv: Data
    var ciphertext: Data
    var encryptedAesKey: Data
}

/// 列表 UI 用：已解密的一条记录 + 行 id。
struct VaultListItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var payload: VaultPayload
}

/// 设置密码时的校验错误（文案直接给用户看）。
struct VaultSetupValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
