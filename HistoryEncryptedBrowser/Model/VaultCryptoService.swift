// CryptoKit：AES-GCM、SymmetricKey 等。
import CryptoKit
import Foundation
// Security：SecKey、SecRandomCopyBytes、RSA-OAEP 等。
import Security

/// 保险库密码学工具集：无实例，全是 static 方法。
/// 设计对齐扩展 `vault-crypto.js`：记录 = 随机 AES-256-GCM 加密 JSON，AES 密钥再用 RSA-OAEP(SHA-256) 封装；私钥再用密码派生密钥做 AES-GCM。
/// 密码派生：扩展用 Argon2id；iOS 用 PBKDF2-HMAC-SHA256 高迭代代替（数据与扩展不互通）。
enum VaultCryptoService {
    /// PBKDF2 迭代次数：越大越慢越抗暴力，主线程上会卡，故创建/解锁在 Task.detached 里做。
    static let pbkdf2Iterations: UInt32 = 250_000
    /// 盐字节长度。
    static let saltLength = 16
    /// AES-GCM 标准 nonce 长度 12 字节。
    static let aesIVLength = 12
    /// RSA 模数位长。
    static let rsaBits = 2048

    enum VaultCryptoError: Error {
        case invalidInput
        case keyDerivationFailed
        case keyGenerationFailed
        case encryptFailed
        case decryptFailed
        case rsaFailed
        case randomGenerationFailed
    }

    // MARK: - 密码 → 对称密钥（PBKDF2，经 Bridging Header 调 CommonCrypto）

    /// 用密码 + 盐派生 32 字节 AES 密钥（封装为 SymmetricKey）。
    static func derivePasswordSymmetricKey(password: String, salt: Data) throws -> SymmetricKey {
        guard let pwdData = password.data(using: .utf8), !pwdData.isEmpty else { throw VaultCryptoError.invalidInput }
        var derived = Data(count: 32)
        let status: Int32 = derived.withUnsafeMutableBytes { dbuf in
            guard let dptr = dbuf.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
            return salt.withUnsafeBytes { sbuf in
                guard let sptr = sbuf.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
                return pwdData.withUnsafeBytes { pbuf in
                    guard let pptr = pbuf.bindMemory(to: Int8.self).baseAddress else { return Int32(kCCParamError) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pptr,
                        pwdData.count,
                        sptr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        dptr,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultCryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    /// 密码学安全随机字节；失败抛错而不是 precondition，避免线上直接崩。
    static func randomBytes(_ count: Int) throws -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { buf -> Int32 in
            guard let p = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, p)
        }
        guard status == errSecSuccess else { throw VaultCryptoError.randomGenerationFailed }
        return d
    }

    // MARK: - RSA 2048（SecKey）

    /// 生成临时 RSA 密钥对（不写钥匙串）。
    static func generateRSAKeyPair() throws -> (publicKey: SecKey, privateKey: SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: rsaBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.keyGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw VaultCryptoError.keyGenerationFailed }
        return (publicKey, privateKey)
    }

    /// 公钥导出为 SPKI DER（与 importPublicKeySPKI 成对）。
    static func exportPublicKeySPKI(_ publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return data
    }

    /// SPKI DER → SecKey 公钥。
    static func importPublicKeySPKI(_ data: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: rsaBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return key
    }

    /// 私钥导出 PKCS#1 DER（再交给 AES 加密存盘）。
    static func exportPrivateKeyDER(_ privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return data
    }

    /// DER → SecKey 私钥（解锁后用于解密记录）。
    static func importPrivateKeyDER(_ data: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: rsaBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return key
    }

    // MARK: - AES-GCM（CryptoKit）

    /// 加密：返回 12 字节 IV + 密文与 16 字节 tag 拼接。
    static func aesGcmEncrypt(plain: Data, key: SymmetricKey) throws -> (iv: Data, ciphertextWithTag: Data) {
        let iv = try randomBytes(aesIVLength)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
        var out = Data()
        out.append(contentsOf: sealed.ciphertext)
        out.append(contentsOf: sealed.tag)
        return (iv, out)
    }

    /// 解密：从 ciphertextWithTag 尾部取 tag，前面是密文。
    static func aesGcmDecrypt(iv: Data, ciphertextWithTag: Data, key: SymmetricKey) throws -> Data {
        guard ciphertextWithTag.count >= 16 else { throw VaultCryptoError.decryptFailed }
        let tag = ciphertextWithTag.suffix(16)
        let ct = ciphertextWithTag.dropLast(16)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    /// 用「密码派生密钥」加密 PKCS#8/PKCS#1 私钥 DER，得到可 JSON 存储的 blob。
    static func encryptPrivateKeyWithPassword(privateKey: SecKey, passwordKey: SymmetricKey) throws -> VaultEncryptedBlob {
        let pk = try exportPrivateKeyDER(privateKey)
        let (iv, ct) = try aesGcmEncrypt(plain: pk, key: passwordKey)
        return VaultEncryptedBlob(iv: iv.base64EncodedString(), ciphertext: ct.base64EncodedString())
    }

    /// 解密私钥 blob → SecKey。
    static func decryptPrivateKeyWithPassword(blob: VaultEncryptedBlob, passwordKey: SymmetricKey) throws -> SecKey {
        guard let iv = Data(base64Encoded: blob.iv), let ct = Data(base64Encoded: blob.ciphertext) else {
            throw VaultCryptoError.invalidInput
        }
        let der = try aesGcmDecrypt(iv: iv, ciphertextWithTag: ct, key: passwordKey)
        return try importPrivateKeyDER(der)
    }

    // MARK: - 单条历史记录（混合加密）

    /// 后台加密入口：入参只用 SPKI 的 Data，避免 Sendable/隔离问题。
    static func encryptRecord(spkiDER: Data, payload: VaultPayload) throws -> VaultRecordEncoded {
        let pub = try importPublicKeySPKI(spkiDER)
        return try encryptRecord(payload: payload, publicKey: pub)
    }

    /// 随机 AES 密钥加密 payload JSON；再用 RSA-OAEP-SHA256 加密该 AES 密钥。
    static func encryptRecord(payload: VaultPayload, publicKey: SecKey) throws -> VaultRecordEncoded {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let plain = try encoder.encode(payload)
        let aesKeyData = try randomBytes(32)
        let sym = SymmetricKey(data: aesKeyData)
        let (iv, ciphertextWithTag) = try aesGcmEncrypt(plain: plain, key: sym)
        var err: Unmanaged<CFError>?
        guard let encKey = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, aesKeyData as CFData, &err) as Data? else {
            throw err?.takeRetainedValue() ?? VaultCryptoError.rsaFailed
        }
        return VaultRecordEncoded(iv: iv, ciphertext: ciphertextWithTag, encryptedAesKey: encKey)
    }

    /// RSA 解出 AES 密钥 → AES-GCM 解 payload。
    static func decryptRecord(encoded: VaultRecordEncoded, privateKey: SecKey) throws -> VaultPayload {
        var err: Unmanaged<CFError>?
        guard let aesRaw = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, encoded.encryptedAesKey as CFData, &err) as Data? else {
            throw err?.takeRetainedValue() ?? VaultCryptoError.rsaFailed
        }
        let sym = SymmetricKey(data: aesRaw)
        let json = try aesGcmDecrypt(iv: encoded.iv, ciphertextWithTag: encoded.ciphertext, key: sym)
        return try JSONDecoder().decode(VaultPayload.self, from: json)
    }

    /// 用户首次设置密码：生成盐、RSA 对、加密私钥，得到可保存的 VaultMetaFile。
    static func createVaultMeta(password: String) throws -> VaultMetaFile {
        guard password.count >= 8, password.count <= 16 else { throw VaultCryptoError.invalidInput }
        let salt = try randomBytes(saltLength)
        let passwordKey = try derivePasswordSymmetricKey(password: password, salt: salt)
        let (pub, priv) = try generateRSAKeyPair()
        let spki = try exportPublicKeySPKI(pub)
        let encPriv = try encryptPrivateKeyWithPassword(privateKey: priv, passwordKey: passwordKey)
        return VaultMetaFile(
            salt: salt.base64EncodedString(),
            publicKeySPKI: spki.base64EncodedString(),
            encryptedPrivateKey: encPriv
        )
    }

    /// 从 meta 解析公钥（写加密记录时用）。
    static func loadPublicKey(from meta: VaultMetaFile) throws -> SecKey {
        guard let d = Data(base64Encoded: meta.publicKeySPKI) else { throw VaultCryptoError.invalidInput }
        return try importPublicKeySPKI(d)
    }

    /// 用户输入密码 → 派生密钥 → 解密私钥。
    static func unlockPrivateKey(meta: VaultMetaFile, password: String) throws -> SecKey {
        guard let salt = Data(base64Encoded: meta.salt) else { throw VaultCryptoError.invalidInput }
        let passwordKey = try derivePasswordSymmetricKey(password: password, salt: salt)
        return try decryptPrivateKeyWithPassword(blob: meta.encryptedPrivateKey, passwordKey: passwordKey)
    }
}
